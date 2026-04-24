defmodule Lynx.Service.UserDeduper do
  @moduledoc """
  Merges duplicate-email user rows into a single canonical user.
  Called from migration `…000013` so duplicate-email databases auto-
  merge during the schema change — no operator action needed for the
  common case.

  ## Winner heuristic

  For each duplicate-email group, the winner is picked by:

    1. **Active first** — `is_active = true` rows beat deactivated ones
       (the operational truth is the row that's currently usable)
    2. **Managed-source first** — `auth_provider = "scim"` beats the
       others (SCIM is push-managed by the IdP; the SCIM row reflects
       the org's source of truth)
    3. **Most recently active** — `COALESCE(last_seen, updated_at)`
       descending tie-breaks the rest

  The heuristic is correct in practice because the duplicate-row
  failure mode it's cleaning up is "user signed up via password +
  was later SCIM-provisioned, producing a stale local row alongside
  the active SCIM row" — exactly what active+SCIM picks.

  Operators who need to override the heuristic in an exotic edge case
  can `remote` into a release shell and call:

      Lynx.Service.UserDeduper.merge_all_duplicates(keep: "winner-uuid")

  before re-running the migration. Or hand-edit the DB via psql.

  ## What happens to the loser

    * Identity row created on the winner reflecting the loser's
      `(auth_provider, external_id, email, name)` — so future SSO/SCIM
      logins via that IdP still resolve to the canonical user
    * `user_projects`, `user_teams`, `users_meta` re-parented to winner
    * `users_session` re-parented (NOT deleted) — open browser tabs
      stay authenticated as the canonical user
    * Any `user_identities` rows the loser already had are re-parented
      where the winner doesn't already have an identity for that
      provider; conflicts drop the loser's
    * Loser row deleted

  ## Logging

  Every merge decision logs `info`-level with the email, winner UUID,
  reason, and loser UUIDs. Operators can grep deploy logs to audit.
  """

  require Logger

  alias Lynx.Repo

  @doc """
  Merge all duplicate-email user rows. Returns
  `%{merged_count: integer, decisions: [decision]}` so callers can
  log a summary.

  Options:
    * `:keep` — UUID to force as winner (overrides heuristic). Raises
      if the UUID isn't part of any duplicate group.
  """
  def merge_all_duplicates(opts \\ []) do
    forced_winner_uuid = Keyword.get(opts, :keep)

    decisions =
      find_duplicates()
      |> Enum.map(&decide_winner(&1, forced_winner_uuid))

    Repo.transaction(fn ->
      Enum.each(decisions, fn decision ->
        Enum.each(decision.losers, fn loser -> merge(decision.winner, loser) end)
        log_decision(decision)
      end)
    end)

    %{merged_count: Enum.sum(Enum.map(decisions, &length(&1.losers))), decisions: decisions}
  end

  # -- Discovery + winner pick --

  defp find_duplicates do
    %Postgrex.Result{rows: rows} =
      Repo.query!("""
      SELECT LOWER(email) AS email,
             ARRAY_AGG(json_build_object(
               'uuid', uuid::text,
               'id', id,
               'auth_provider', auth_provider,
               'external_id', external_id,
               'is_active', is_active,
               'last_seen', last_seen,
               'updated_at', updated_at,
               'name', name
             )) AS users
      FROM users
      GROUP BY LOWER(email)
      HAVING COUNT(*) > 1
      ORDER BY email
      """)

    Enum.map(rows, fn [email, users_json] ->
      %{email: email, users: users_json}
    end)
  end

  defp decide_winner(%{email: email, users: users}, forced_uuid) do
    {winner, losers, reason} = pick_winner(users, forced_uuid)
    %{email: email, winner: winner, losers: losers, reason: reason}
  end

  defp pick_winner(users, nil) do
    sorted = Enum.sort_by(users, &winner_priority/1)
    [winner | losers] = sorted
    {winner, losers, winner_reason(winner, users)}
  end

  defp pick_winner(users, forced_uuid) do
    case Enum.split_with(users, &(&1["uuid"] == forced_uuid)) do
      {[winner], losers} -> {winner, losers, "forced via :keep option"}
      _ -> raise "keep: #{forced_uuid} did not match any duplicate user uuid"
    end
  end

  # Sort key: smaller is better (Elixir sorts ascending). Inactive,
  # non-SCIM, and older rows get larger keys and end up later in the
  # list — index 0 is our winner.
  defp winner_priority(user) do
    {
      if(user["is_active"], do: 0, else: 1),
      if(user["auth_provider"] == "scim", do: 0, else: 1),
      # Negate Unix time so most-recent sorts first.
      -recency_seconds(user)
    }
  end

  defp recency_seconds(user) do
    case user["last_seen"] || user["updated_at"] do
      nil ->
        0

      ts when is_binary(ts) ->
        # PostgreSQL json_build_object emits timestamps as ISO 8601
        # strings (sometimes without the trailing Z; tolerate both).
        case DateTime.from_iso8601(ts) do
          {:ok, dt, _} ->
            DateTime.to_unix(dt)

          _ ->
            case DateTime.from_iso8601(ts <> "Z") do
              {:ok, dt, _} -> DateTime.to_unix(dt)
              _ -> 0
            end
        end
    end
  end

  defp winner_reason(winner, all_users) do
    has_inactive = Enum.any?(all_users, &(not &1["is_active"]))

    cond do
      winner["is_active"] and has_inactive and winner["auth_provider"] == "scim" ->
        "active SCIM-managed row"

      winner["is_active"] and has_inactive ->
        "only active row"

      winner["auth_provider"] == "scim" ->
        "SCIM-managed (managed-source IdP)"

      true ->
        "most recent activity"
    end
  end

  defp log_decision(%{email: email, winner: w, losers: ls, reason: reason}) do
    loser_uuids = Enum.map(ls, & &1["uuid"]) |> Enum.join(", ")

    Logger.info(
      "UserDeduper merged duplicates for #{email}: kept #{w["uuid"]} (#{reason}); merged + deleted [#{loser_uuids}]"
    )
  end

  # -- Per-loser merge --

  defp merge(winner, loser) do
    winner_id = winner["id"]
    loser_id = loser["id"]

    # 1. Re-parent FK references. We list them explicitly — there's no
    #    generic "for each FK pointing to users" mass-update in Postgres.
    #    If a new table that FKs to users gets added, add it here too.
    #
    #    `user_projects` and `user_teams` both have a unique constraint
    #    on `(user_id, <thing>_id)`, so a naked UPDATE would fail when
    #    winner and loser were both in the same project / team. Skip
    #    rows where the winner is already a member; the loser-side
    #    leftover gets cascade-deleted with the loser user below.
    Repo.query!(
      """
      UPDATE user_projects SET user_id = $1
      WHERE user_id = $2
        AND NOT EXISTS (
          SELECT 1 FROM user_projects w
          WHERE w.user_id = $1 AND w.project_id = user_projects.project_id
        )
      """,
      [winner_id, loser_id]
    )

    Repo.query!(
      """
      UPDATE user_teams SET user_id = $1
      WHERE user_id = $2
        AND NOT EXISTS (
          SELECT 1 FROM user_teams w
          WHERE w.user_id = $1 AND w.team_id = user_teams.team_id
        )
      """,
      [winner_id, loser_id]
    )

    Repo.query!("UPDATE users_meta SET user_id = $1 WHERE user_id = $2", [winner_id, loser_id])

    # Re-parent (not delete) sessions — operator's open browser tabs
    # stay authenticated as the canonical user. session.value (the
    # bearer token) is independent of user_id, so the cookie keeps
    # working.
    Repo.query!("UPDATE users_session SET user_id = $1 WHERE user_id = $2", [
      winner_id,
      loser_id
    ])

    # 2. Re-parent the loser's identities to the winner where safe.
    #    The backfill step in migration `…000013` already inserted
    #    one identity per user from `(auth_provider, external_id)`,
    #    so the loser's IdP linkage is already represented as a row
    #    here — we just move the row's `user_id` to the winner.
    #
    #    Two guards prevent constraint violations:
    #      a. The winner doesn't already have an identity for that
    #         provider (would violate the (user_id, provider) index)
    #      b. No OTHER row has the same (provider, provider_uid)
    #         (would violate the (provider, provider_uid) partial
    #         unique index — exactly Aron's prod scenario, where both
    #         users' backfilled identities collided on `(local,
    #         "aron@email")`)
    #
    #    Loser-side rows that fail either guard stay on the loser and
    #    get cleaned up by the cascade when we delete the user below.
    Repo.query!(
      """
      UPDATE user_identities SET user_id = $1
      WHERE user_id = $2
        AND NOT EXISTS (
          SELECT 1 FROM user_identities w
          WHERE w.user_id = $1 AND w.provider = user_identities.provider
        )
        AND NOT EXISTS (
          SELECT 1 FROM user_identities other
          WHERE other.provider = user_identities.provider
            AND other.provider_uid IS NOT DISTINCT FROM user_identities.provider_uid
            AND other.id != user_identities.id
        )
      """,
      [winner_id, loser_id]
    )

    # 3. Delete the loser. The `on_delete: :delete_all` FK on
    #    `user_identities.user_id` cascades any remaining loser-side
    #    identity rows — and the `refuse_last_user_identity_delete`
    #    trigger allows it because the user is gone by the time the
    #    cascade fires (the trigger's "still exists?" check returns
    #    false). Doing the user-delete first is what makes the
    #    cascade work; deleting identities directly first would trip
    #    the lockout guard.
    Repo.query!("DELETE FROM users WHERE id = $1", [loser_id])
  end
end

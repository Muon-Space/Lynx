defmodule Mix.Tasks.Lynx.DedupeUsers do
  @moduledoc """
  Merge duplicate-email user rows that block migration `…000013`.

  The user-identities migration adds a unique index on `users.email` and
  drops `users.{auth_provider, external_id}`. Both fail if more than one
  user row shares an email — common for Lynx instances that started on
  password auth and later added SAML / SCIM, since the legacy code
  created a fresh user row when an SSO login presented an external_id
  that didn't yet exist (instead of merging by email).

  This task does the merge cleanly:

    * Picks a "winner" per duplicate group (most recently `last_seen`,
      then most recently `updated_at` — operator can override per group)
    * Re-parents `user_projects` and `user_metas` from losers to winner
    * **Re-parents** (not deletes) `user_sessions` so already-logged-in
      browsers stay logged in as the canonical user
    * Links any loser-side identities to the winner so future logins
      via that IdP resolve to the same canonical account

  ## Usage

      mix lynx.dedupe_users --check        # report duplicates, do nothing
      mix lynx.dedupe_users --dry-run      # show planned merges, do nothing
      mix lynx.dedupe_users                 # apply with default winners
      mix lynx.dedupe_users --keep <uuid>   # force this UUID as winner across all groups it appears in

  Snapshot the DB before applying. The merge is irreversible.
  """

  use Mix.Task

  alias Lynx.Repo

  @shortdoc "Merge duplicate-email user rows (run before user-identities migration)"

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [check: :boolean, dry_run: :boolean, keep: :string]
      )

    Mix.Task.run("app.start")

    duplicates = find_duplicates()

    cond do
      duplicates == [] ->
        Mix.shell().info("No duplicate-email user rows found. Migration is safe to apply.")

      opts[:check] ->
        report(duplicates)

      true ->
        plan = build_merge_plan(duplicates, opts)
        report_plan(plan)

        cond do
          opts[:dry_run] ->
            Mix.shell().info("\n--dry-run — no changes applied.")

          true ->
            apply_plan(plan)
            Mix.shell().info("\nMerge complete. You can now apply the migration.")
        end
    end
  end

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
             ) ORDER BY COALESCE(last_seen, updated_at) DESC) AS users
      FROM users
      GROUP BY LOWER(email)
      HAVING COUNT(*) > 1
      ORDER BY email
      """)

    Enum.map(rows, fn [email, users_json] ->
      %{email: email, users: users_json}
    end)
  end

  defp report(duplicates) do
    Mix.shell().info("\nDuplicate-email user rows found:\n")

    Enum.each(duplicates, fn %{email: email, users: users} ->
      Mix.shell().info("  #{email} (#{length(users)} rows)")

      Enum.each(users, fn u ->
        Mix.shell().info(
          "    - #{u["uuid"]}  active=#{u["is_active"]}  provider=#{u["auth_provider"]}  external_id=#{inspect(u["external_id"])}  last_seen=#{u["last_seen"]}"
        )
      end)
    end)

    Mix.shell().info("\nRun without --check to merge.")
  end

  defp build_merge_plan(duplicates, opts) do
    forced_winner_uuid = opts[:keep]

    Enum.map(duplicates, fn %{email: email, users: users} ->
      {winner, losers} = pick_winner(users, forced_winner_uuid)
      %{email: email, winner: winner, losers: losers}
    end)
  end

  defp pick_winner(users, nil) do
    # Default: the first user (most recent activity) wins.
    [winner | losers] = users
    {winner, losers}
  end

  defp pick_winner(users, forced_uuid) do
    case Enum.split_with(users, &(&1["uuid"] == forced_uuid)) do
      {[winner], losers} -> {winner, losers}
      _ -> raise "--keep #{forced_uuid} did not match any duplicate user uuid"
    end
  end

  defp report_plan(plan) do
    Mix.shell().info("\nMerge plan:\n")

    Enum.each(plan, fn %{email: email, winner: w, losers: ls} ->
      Mix.shell().info("  #{email}")

      Mix.shell().info(
        "    KEEP    #{w["uuid"]}  active=#{w["is_active"]}  provider=#{w["auth_provider"]}"
      )

      Enum.each(ls, fn l ->
        Mix.shell().info(
          "    MERGE   #{l["uuid"]}  active=#{l["is_active"]}  provider=#{l["auth_provider"]}  →  #{w["uuid"]}"
        )
      end)
    end)
  end

  defp apply_plan(plan) do
    Repo.transaction(fn ->
      Enum.each(plan, fn %{winner: w, losers: ls} ->
        Enum.each(ls, fn loser ->
          merge(w, loser)
        end)
      end)
    end)
  end

  defp merge(winner, loser) do
    winner_id = winner["id"]
    loser_id = loser["id"]

    # 1. Link the loser's identity to the winner (if the loser had one).
    #    Conflict on (user_id, provider) means the winner already has
    #    an identity for this provider — we keep theirs and skip.
    if loser["auth_provider"] do
      Repo.query!(
        """
        INSERT INTO user_identities (uuid, user_id, provider, provider_uid, email, inserted_at, updated_at)
        VALUES ($1, $2, $3, $4, $5, NOW(), NOW())
        ON CONFLICT (user_id, provider) DO NOTHING
        """,
        [
          Ecto.UUID.bingenerate(),
          winner_id,
          loser["auth_provider"],
          loser["external_id"],
          loser["uuid"]
        ]
      )
    end

    # 2. Re-parent FK references. We list them explicitly — there's no
    #    generic "for each FK pointing to users" mass-update in Postgres.
    #    If a new table that FKs to users gets added, add it here too.
    Repo.query!("UPDATE user_projects SET user_id = $1 WHERE user_id = $2", [
      winner_id,
      loser_id
    ])

    Repo.query!("UPDATE user_teams SET user_id = $1 WHERE user_id = $2", [winner_id, loser_id])
    Repo.query!("UPDATE users_meta SET user_id = $1 WHERE user_id = $2", [winner_id, loser_id])

    # Re-parent (not delete) sessions — operator's open browser tabs
    # stay authenticated as the canonical user. session.value (the
    # bearer token) is independent of user_id, so the cookie keeps
    # working.
    Repo.query!("UPDATE users_session SET user_id = $1 WHERE user_id = $2", [
      winner_id,
      loser_id
    ])

    # 3. Re-parent any user_identities the loser already had (from a
    #    previous run of this task or a manual link).
    Repo.query!(
      """
      UPDATE user_identities SET user_id = $1
      WHERE user_id = $2
        AND NOT EXISTS (
          SELECT 1 FROM user_identities w
          WHERE w.user_id = $1 AND w.provider = user_identities.provider
        )
      """,
      [winner_id, loser_id]
    )

    # Anything that conflicts (winner already has an identity for that
    # provider) gets dropped — the winner's identity is canonical.
    Repo.query!("DELETE FROM user_identities WHERE user_id = $1", [loser_id])

    # 4. Delete the loser. The on_delete: :delete_all FK cascades any
    #    leftover refs that we haven't explicitly re-parented above
    #    (none expected after the steps above).
    Repo.query!("DELETE FROM users WHERE id = $1", [loser_id])
  end
end

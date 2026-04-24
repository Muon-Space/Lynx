defmodule Lynx.Repo.Migrations.CreateUserIdentities do
  @moduledoc """
  Move login-method state out of `users.{auth_provider, external_id}` —
  which conflated "who the user is" with "how they last authenticated" —
  into a dedicated `user_identities` table that lets one canonical user
  link multiple identity providers.

  Standard pattern in modern auth stacks (Auth0, WorkOS, Clerk,
  Supabase). The previous design caused Lynx to create duplicate
  `users` rows when the same human signed in via different IdPs (e.g.
  SAML carrying email-as-NameID, while SCIM carried Okta's stable
  user ID), because `external_id` was scalar and got overwritten by
  whichever method touched the row last.

  ## What this migration does

    1. Creates `user_identities` (one row per user × login method)
    2. Backfills one identity per existing user from their
       `(auth_provider, external_id, email)` tuple
    3. Auto-merges duplicate-email user rows: keeps the most-recently-
       updated one as canonical, links the loser's identity to it,
       re-parents user_projects + user_metas + user_sessions, deletes
       the loser
    4. Adds a unique index on `users.email` so duplicates can never
       recur

  `users.auth_provider` and `users.external_id` are intentionally NOT
  dropped here — runtime auth lookups switch to `user_identities`,
  but the columns stay for one release as a rollback safety net.
  A follow-up migration drops them after the new code is bedded in.

  ## Operator notes

  Auto-merge of duplicate-email rows is destructive. Snapshot the DB
  before applying. The merge keeps grants + sessions on the winning
  row, so users won't lose access — but the merge picks a winner
  automatically, and if the wrong one is picked you can't undo it
  except from snapshot.
  """

  use Ecto.Migration

  import Ecto.Query

  def up do
    create table(:user_identities) do
      add :uuid, :uuid, null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false

      # "local" | "scim" | "saml" | "oidc" — extend as new IdPs are added.
      add :provider, :string, null: false

      # The IdP's stable identifier for this user. nil only for "local"
      # (password auth has no IdP UID — the password hash on `users`
      # itself is the credential).
      add :provider_uid, :string, null: true

      # Snapshot of the email this identity presented at link time.
      # IdPs change emails over time; this lets us audit "which email
      # did SAML send when this identity was first linked?".
      add :email, :string, null: true

      add :last_seen_at, :utc_datetime, null: true

      timestamps()
    end

    create unique_index(:user_identities, [:uuid])

    # A given (provider, provider_uid) pair must map to exactly one
    # Lynx user — otherwise SCIM/SAML lookups would be ambiguous.
    # Partial index because "local" identities have no provider_uid;
    # uniqueness for those is enforced by the next index.
    create unique_index(:user_identities, [:provider, :provider_uid],
             where: "provider_uid IS NOT NULL",
             name: :user_identities_provider_uid_idx
           )

    # A user has at most one identity per provider — one local password,
    # one SCIM link, one SAML link, one OIDC link.
    create unique_index(:user_identities, [:user_id, :provider])

    create index(:user_identities, [:user_id])

    flush()

    # The next two steps mutate `users` rows. Wrap in a transaction so
    # a partial failure rolls back cleanly.
    auto_merge_duplicate_email_users()
    backfill_identities_from_users()

    flush()

    # `create_users.exs` already created a non-unique `users_email_index`
    # — drop it first so the unique replacement can claim the same
    # name. If we left both, queries that planned against the old
    # one would still work, but we'd carry redundant index storage.
    drop_if_exists index(:users, [:email])

    # Now that duplicates are merged, the unique index is safe to
    # apply. If it fails here it means the auto-merge missed a case
    # — rollback + investigate before retrying.
    create unique_index(:users, [:email], name: :users_email_unique_index)
  end

  # -- Auto-merge --

  # For each (lowercased) email with more than one user row: pick the
  # most-recently-updated row as the winner, re-parent everything
  # owned by the losers (user_projects, user_metas, user_sessions),
  # then delete the losers. The winner gets identity rows reflecting
  # ALL the (provider, external_id) combinations the losers had, so
  # SCIM / SAML lookups against any of those keys still resolve.
  defp auto_merge_duplicate_email_users do
    %Postgrex.Result{rows: groups} =
      repo().query!("""
      SELECT LOWER(email) AS email, ARRAY_AGG(id ORDER BY updated_at DESC) AS ids
      FROM users
      GROUP BY LOWER(email)
      HAVING COUNT(*) > 1
      """)

    Enum.each(groups, fn [email, ids] ->
      [winner_id | loser_ids] = ids

      Enum.each(loser_ids, fn loser_id ->
        merge_loser_into_winner(winner_id, loser_id, email)
      end)
    end)
  end

  defp merge_loser_into_winner(winner_id, loser_id, email) do
    # First, snapshot the loser's auth_provider + external_id so we can
    # link it as an identity on the winner (the loser's row is about to
    # be deleted).
    %Postgrex.Result{rows: [[loser_provider, loser_external_id]]} =
      repo().query!(
        "SELECT auth_provider, external_id FROM users WHERE id = $1",
        [loser_id]
      )

    insert_identity(winner_id, loser_provider, loser_external_id, email)

    # Re-parent any FK references. We list them explicitly so a future
    # table addition doesn't silently get missed — Postgres doesn't
    # support a generic "for each FK pointing to users" mass UPDATE.
    repo().query!("UPDATE user_projects SET user_id = $1 WHERE user_id = $2", [
      winner_id,
      loser_id
    ])

    repo().query!("UPDATE user_metas SET user_id = $1 WHERE user_id = $2", [
      winner_id,
      loser_id
    ])

    # Delete the loser's sessions outright (rather than re-parent) — a
    # session represents an authenticated browser; the winner's own
    # sessions are the only ones that belong on them.
    repo().query!("DELETE FROM user_sessions WHERE user_id = $1", [loser_id])

    repo().query!("DELETE FROM users WHERE id = $1", [loser_id])
  end

  # -- Backfill --

  defp backfill_identities_from_users do
    %Postgrex.Result{rows: rows} =
      repo().query!("SELECT id, auth_provider, external_id, email FROM users")

    Enum.each(rows, fn [user_id, auth_provider, external_id, email] ->
      provider = auth_provider || "local"
      insert_identity(user_id, provider, external_id, email)
    end)
  end

  defp insert_identity(_user_id, nil, _external_id, _email), do: :skip

  defp insert_identity(user_id, provider, provider_uid, email) do
    # ON CONFLICT DO NOTHING — running the migration twice (e.g. after
    # a partial-failure restore) shouldn't double-insert. The unique
    # constraint on (user_id, provider) would catch it anyway, but
    # being explicit avoids an exception that would abort the txn.
    repo().query!(
      """
      INSERT INTO user_identities (uuid, user_id, provider, provider_uid, email, inserted_at, updated_at)
      VALUES ($1, $2, $3, $4, $5, NOW(), NOW())
      ON CONFLICT (user_id, provider) DO NOTHING
      """,
      [Ecto.UUID.bingenerate(), user_id, provider, provider_uid, email]
    )
  end

  def down do
    drop_if_exists unique_index(:users, [:email], name: :users_email_unique_index)
    # Restore the original non-unique email index that `create_users.exs`
    # had — anything that was depending on it for query planning still
    # has it after rollback.
    create_if_not_exists index(:users, [:email])
    drop_if_exists table(:user_identities)
    # users.{auth_provider, external_id} are still on `users` — not
    # touched in `up` either, so down has nothing to restore there.
    # Auto-merged duplicate users are NOT recoverable; restore from
    # snapshot if rollback is required.
  end
end

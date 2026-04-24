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
       `(auth_provider, external_id, email, name)` tuple
    3. Adds a DB trigger that refuses to delete a user's last identity
       (defence in depth — the application layer also enforces this)
    4. Auto-merges duplicate-email user rows via
       `Lynx.Service.UserDeduper.merge_all_duplicates/0` so operators
       don't need a separate manual step. Heuristic picks active +
       SCIM-managed rows as winners (the right answer for the common
       case: stale local row alongside an active SCIM-provisioned one)
    5. Re-checks for duplicates after the auto-merge; raises with the
       remaining conflicts only if the auto-merge didn't resolve them
       (rare — operators can override via
       `Lynx.Service.UserDeduper.merge_all_duplicates(keep: "uuid")`
       from a release `remote` shell)
    6. Drops `users.auth_provider` + `users.external_id` (no longer
       read at runtime — `user_identities` is the source of truth)
    7. Adds a unique index on `users.email` so duplicates can never
       recur

  ## Operator notes

  Snapshot the DB before applying — the auto-merge is destructive
  and the schema change is irreversible. The merge re-parents
  `user_projects`, `user_teams`, `users_meta`, and `users_session` so
  no data is silently dropped, but the loser user UUIDs are gone.
  Every merge decision logs `info`-level so deploy logs carry an
  audit trail of which row won each duplicate group.
  """

  use Ecto.Migration

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

      # Same per-identity snapshot for the display name. Lets us
      # preserve per-IdP truth without flickering the canonical
      # `users.name` every time a different IdP signs the same user
      # in. Only SCIM (the managed-source IdP) updates `users.name`;
      # drive-by SAML/OIDC logins update only this snapshot.
      add :name, :string, null: true

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

    # Backfill happens BEFORE the duplicate check + column drops so we
    # don't lose the (auth_provider, external_id) data if the operator
    # has to interrupt and run the dedupe task.
    backfill_identities_from_users()

    flush()

    # Defence-in-depth: the application layer's `delete_identity/1`
    # refuses to remove the user's last identity, but a SQL DELETE
    # would bypass it. Trigger enforces the same rule at the DB level.
    install_last_identity_guard_trigger()

    flush()

    # Auto-merge duplicate-email user rows so the unique index can
    # apply. The heuristic prefers active + SCIM-managed rows — the
    # correct winner in the common "stale local row alongside an
    # active SCIM-provisioned one" failure mode this PR fixes.
    %{merged_count: merged_count} = Lynx.Service.UserDeduper.merge_all_duplicates()

    if merged_count > 0 do
      IO.puts("UserDeduper merged #{merged_count} duplicate user row(s) — see info-level log lines above for per-group decisions.")
    end

    flush()

    # If anything still slipped through (operator passed `keep:` for a
    # non-existent UUID, or a brand-new duplicate appeared between the
    # merge and now), refuse with a clear remediation.
    refuse_if_duplicate_emails()

    # Replace the existing non-unique `users_email_index` with a
    # unique one. We use a different name to avoid the "relation
    # already exists" collision Postgres throws when reusing the
    # default index name.
    drop_if_exists index(:users, [:email])
    create unique_index(:users, [:email], name: :users_email_unique_index)

    # Drop the deprecated columns. `user_identities` is the source of
    # truth from this point forward.
    alter table(:users) do
      remove :auth_provider
      remove :external_id
    end
  end

  defp backfill_identities_from_users do
    %Postgrex.Result{rows: rows} =
      repo().query!("SELECT id, auth_provider, external_id, email, name FROM users")

    Enum.each(rows, fn [user_id, auth_provider, external_id, email, name] ->
      provider = auth_provider || "local"

      # ON CONFLICT — running the migration after a partial-failure
      # restore shouldn't double-insert. The unique constraint on
      # (user_id, provider) would catch it anyway, but being explicit
      # avoids the exception that would abort the txn.
      repo().query!(
        """
        INSERT INTO user_identities (uuid, user_id, provider, provider_uid, email, name, inserted_at, updated_at)
        VALUES ($1, $2, $3, $4, $5, $6, NOW(), NOW())
        ON CONFLICT (user_id, provider) DO NOTHING
        """,
        [Ecto.UUID.bingenerate(), user_id, provider, external_id, email, name]
      )
    end)
  end

  defp install_last_identity_guard_trigger do
    repo().query!("""
    CREATE OR REPLACE FUNCTION refuse_last_user_identity_delete()
    RETURNS TRIGGER AS $$
    BEGIN
      IF (SELECT COUNT(*) FROM user_identities WHERE user_id = OLD.user_id) <= 1 THEN
        -- Allow the cascade from `users` deletion (whole user is going away).
        IF EXISTS (SELECT 1 FROM users WHERE id = OLD.user_id) THEN
          RAISE EXCEPTION 'cannot delete the last identity for user % — would lock them out', OLD.user_id
            USING ERRCODE = 'check_violation';
        END IF;
      END IF;
      RETURN OLD;
    END;
    $$ LANGUAGE plpgsql;
    """)

    repo().query!("""
    CREATE TRIGGER user_identities_refuse_last_delete
    BEFORE DELETE ON user_identities
    FOR EACH ROW
    EXECUTE FUNCTION refuse_last_user_identity_delete();
    """)
  end

  defp refuse_if_duplicate_emails do
    %Postgrex.Result{rows: rows} =
      repo().query!("""
      SELECT LOWER(email) AS email,
             COUNT(*) AS dup_count,
             ARRAY_AGG(uuid::text ORDER BY updated_at DESC) AS uuids_recent_first
      FROM users
      GROUP BY LOWER(email)
      HAVING COUNT(*) > 1
      ORDER BY email
      """)

    case rows do
      [] ->
        :ok

      duplicates ->
        formatted =
          Enum.map(duplicates, fn [email, count, uuids] ->
            "  • #{email} (#{count} rows): #{Enum.join(uuids, ", ")}"
          end)
          |> Enum.join("\n")

        raise """
        Auto-merge did not resolve all duplicate-email user rows:

        #{formatted}

        This is unusual — `Lynx.Service.UserDeduper.merge_all_duplicates/0`
        normally collapses every group. If you got here it likely means
        a brand-new duplicate appeared between the merge and the unique-
        index apply. Resolve via a release `remote` shell:

          Lynx.Service.UserDeduper.merge_all_duplicates(keep: "winner-uuid")

        then re-run the migration. Snapshot the DB first.
        """
    end
  end

  def down do
    # Rollback adds the dropped columns back as nullable, then deletes
    # the trigger + function and the user_identities table. Pre-existing
    # `auth_provider` / `external_id` values are NOT recovered — restore
    # from snapshot if you need them.
    alter table(:users) do
      add_if_not_exists :auth_provider, :string, default: "local"
      add_if_not_exists :external_id, :string
    end

    drop_if_exists unique_index(:users, [:email], name: :users_email_unique_index)
    create_if_not_exists index(:users, [:email])

    repo().query!("DROP TRIGGER IF EXISTS user_identities_refuse_last_delete ON user_identities;")
    repo().query!("DROP FUNCTION IF EXISTS refuse_last_user_identity_delete();")

    drop_if_exists table(:user_identities)
  end
end

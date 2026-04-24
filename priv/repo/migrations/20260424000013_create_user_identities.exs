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
    3. Adds a DB trigger that refuses to delete a user's last identity
       (defence in depth — the application layer also enforces this)
    4. Pre-flights for duplicate-email user rows; raises with a clear
       remediation guide if any exist (operators must dedupe via
       `mix lynx.dedupe_users` before the schema change can complete)
    5. Drops `users.auth_provider` + `users.external_id` (no longer
       read at runtime — `user_identities` is the source of truth)
    6. Adds a unique index on `users.email` so duplicates can never
       recur

  ## Operator notes

  Run `mix lynx.dedupe_users --check` first to confirm no merge is
  required. If duplicates exist, run `mix lynx.dedupe_users` (with
  `--keep <uuid>` for each duplicate group) to merge them properly:
  the task re-parents grants + sessions and links identities so no
  data is silently dropped. Then apply this migration.

  Snapshot the DB before either step.
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

    # Refuse to proceed if duplicate-email users exist. The drop of
    # `auth_provider` + `external_id` is irreversible and the unique
    # index would fail anyway — better to halt with a clear message
    # than to do half the migration and roll back.
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
      repo().query!("SELECT id, auth_provider, external_id, email FROM users")

    Enum.each(rows, fn [user_id, auth_provider, external_id, email] ->
      provider = auth_provider || "local"

      # ON CONFLICT — running the migration after a partial-failure
      # restore shouldn't double-insert. The unique constraint on
      # (user_id, provider) would catch it anyway, but being explicit
      # avoids the exception that would abort the txn.
      repo().query!(
        """
        INSERT INTO user_identities (uuid, user_id, provider, provider_uid, email, inserted_at, updated_at)
        VALUES ($1, $2, $3, $4, $5, NOW(), NOW())
        ON CONFLICT (user_id, provider) DO NOTHING
        """,
        [Ecto.UUID.bingenerate(), user_id, provider, external_id, email]
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
        Cannot apply unique index on users.email — duplicate-email user rows exist:

        #{formatted}

        Resolve before re-running this migration:

          mix lynx.dedupe_users               # interactive: pick a winner per group
          mix lynx.dedupe_users --keep <uuid> # non-interactive: keep the named winner

        The task re-parents grants + sessions, links the loser's identity
        to the winner, then deletes the loser. Snapshot the DB first.
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

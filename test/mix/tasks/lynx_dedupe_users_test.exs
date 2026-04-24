defmodule Mix.Tasks.Lynx.DedupeUsersTest do
  @moduledoc """
  Pinning the operator's pre-deploy escape hatch. The user-identities
  migration refuses to apply if duplicate-email user rows exist; this
  task is what operators run to merge them into a single canonical
  row. The contract:

    * Picks a winner per duplicate group (most recently active by default)
    * Re-parents `user_projects` + `user_metas` from losers to winner
    * Re-parents (does not delete) `user_sessions` so logged-in browsers
      stay authenticated as the canonical user
    * Links the loser's identity to the winner so future SSO/SCIM
      logins resolve to the same row
    * Deletes the loser

  Since the task pre-dates the migration that drops `users.{auth_provider,
  external_id}`, these tests insert duplicate rows via raw SQL — the
  Ecto schema in this branch already lost those fields, but the columns
  are still expected to exist in operator DBs at the moment of dedupe.
  """
  use LynxWeb.LiveCase, async: false

  alias Lynx.Repo
  alias Mix.Tasks.Lynx.DedupeUsers

  setup do
    mark_installed()

    # The User schema in this branch no longer has auth_provider /
    # external_id, but the dedupe task runs against operator DBs that
    # still do. Re-add the columns just for these tests so we can
    # set up the duplicate-row scenario.
    Repo.query!(
      "ALTER TABLE users ADD COLUMN IF NOT EXISTS auth_provider VARCHAR DEFAULT 'local'"
    )

    Repo.query!("ALTER TABLE users ADD COLUMN IF NOT EXISTS external_id VARCHAR")

    # Drop the unique-email index for the same reason — the operator
    # runs this task BEFORE applying the migration that adds the index.
    Repo.query!("DROP INDEX IF EXISTS users_email_unique_index")

    on_exit(fn ->
      Repo.query!("ALTER TABLE users DROP COLUMN IF EXISTS auth_provider")
      Repo.query!("ALTER TABLE users DROP COLUMN IF EXISTS external_id")
    end)

    :ok
  end

  defp insert_duplicate_user(email, attrs) do
    attrs = Map.new(attrs)

    Repo.query!(
      """
      INSERT INTO users (uuid, email, name, password_hash, verified, last_seen, role, api_key_hash, is_active, auth_provider, external_id, inserted_at, updated_at)
      VALUES ($1, $2, $3, $4, true, $5, 'regular', $6, $7, $8, $9, NOW(), NOW())
      RETURNING id, uuid::text
      """,
      [
        Ecto.UUID.bingenerate(),
        email,
        attrs[:name] || email,
        "__placeholder__",
        attrs[:last_seen] || DateTime.utc_now() |> DateTime.truncate(:second),
        Lynx.Service.TokenHash.hash(Ecto.UUID.generate()),
        Map.get(attrs, :is_active, true),
        attrs[:auth_provider] || "local",
        attrs[:external_id]
      ]
    )
    |> Map.fetch!(:rows)
    |> hd()
  end

  describe "run/1" do
    test "no-op when no duplicate emails exist" do
      output = ExUnit.CaptureIO.capture_io(fn -> DedupeUsers.run(["--check"]) end)
      assert output =~ "No duplicate-email user rows found"
    end

    test "merges two rows with the same email; winner = most recent" do
      [_loser_id, loser_uuid] =
        insert_duplicate_user("merge-me@example.com",
          name: "Old Local",
          auth_provider: "local",
          external_id: "merge-me@example.com",
          is_active: false,
          last_seen: ~U[2026-01-01 00:00:00Z]
        )

      [winner_id, winner_uuid] =
        insert_duplicate_user("merge-me@example.com",
          name: "Aron Gates",
          auth_provider: "scim",
          external_id: "okta-uid-merge",
          is_active: true,
          last_seen: DateTime.utc_now() |> DateTime.truncate(:second)
        )

      ExUnit.CaptureIO.capture_io(fn -> DedupeUsers.run([]) end)

      # Loser deleted, winner kept.
      assert Repo.query!("SELECT COUNT(*) FROM users WHERE email = 'merge-me@example.com'")
             |> Map.fetch!(:rows) == [[1]]

      assert Repo.query!("SELECT uuid::text FROM users WHERE id = $1", [winner_id])
             |> Map.fetch!(:rows) == [[winner_uuid]]

      # Loser's identity (the legacy local-with-external_id=email)
      # was linked to the winner.
      [loser_identity_count] =
        Repo.query!(
          "SELECT COUNT(*) FROM user_identities WHERE user_id = $1 AND provider_uid = $2",
          [winner_id, "merge-me@example.com"]
        )
        |> Map.fetch!(:rows)
        |> hd()

      assert loser_identity_count == 1

      refute_uuid_exists(loser_uuid)
    end

    test "--keep <uuid> overrides the default winner pick" do
      [_winner_id, winner_uuid] =
        insert_duplicate_user("override@example.com",
          auth_provider: "local",
          external_id: nil,
          last_seen: ~U[2026-01-01 00:00:00Z]
        )

      [_loser_id, loser_uuid] =
        insert_duplicate_user("override@example.com",
          auth_provider: "scim",
          external_id: "okta-uid-override",
          last_seen: DateTime.utc_now() |> DateTime.truncate(:second)
        )

      # Default would pick the SCIM row (more recent). --keep flips it.
      ExUnit.CaptureIO.capture_io(fn -> DedupeUsers.run(["--keep", winner_uuid]) end)

      assert Repo.query!("SELECT uuid::text FROM users WHERE email = 'override@example.com'")
             |> Map.fetch!(:rows) == [[winner_uuid]]

      refute_uuid_exists(loser_uuid)
    end

    test "re-parents user_sessions onto the winner so logged-in browsers stay authenticated" do
      [loser_id, _loser_uuid] =
        insert_duplicate_user("session@example.com",
          last_seen: ~U[2026-01-01 00:00:00Z]
        )

      [winner_id, _winner_uuid] =
        insert_duplicate_user("session@example.com",
          last_seen: DateTime.utc_now() |> DateTime.truncate(:second)
        )

      # Plant a session on the loser.
      Repo.query!(
        """
        INSERT INTO users_session (value, expire_at, user_id, auth_method, inserted_at, updated_at)
        VALUES ('test-session-token', NOW() + INTERVAL '1 hour', $1, 'password', NOW(), NOW())
        """,
        [loser_id]
      )

      ExUnit.CaptureIO.capture_io(fn -> DedupeUsers.run([]) end)

      [session_count] =
        Repo.query!("SELECT COUNT(*) FROM users_session WHERE user_id = $1", [winner_id])
        |> Map.fetch!(:rows)
        |> hd()

      assert session_count == 1
    end

    test "--dry-run reports the plan but does not apply" do
      [loser_id, _] =
        insert_duplicate_user("dryrun@example.com", last_seen: ~U[2026-01-01 00:00:00Z])

      [_winner_id, _] = insert_duplicate_user("dryrun@example.com", [])

      ExUnit.CaptureIO.capture_io(fn -> DedupeUsers.run(["--dry-run"]) end)

      # Both rows still exist.
      [count] =
        Repo.query!("SELECT COUNT(*) FROM users WHERE email = 'dryrun@example.com'")
        |> Map.fetch!(:rows)
        |> hd()

      assert count == 2

      assert Repo.query!("SELECT id FROM users WHERE id = $1", [loser_id]) |> Map.fetch!(:rows) !=
               []
    end
  end

  defp refute_uuid_exists(uuid) do
    [count] =
      Repo.query!("SELECT COUNT(*) FROM users WHERE uuid = $1", [Ecto.UUID.dump!(uuid)])
      |> Map.fetch!(:rows)
      |> hd()

    assert count == 0, "expected uuid #{uuid} to be deleted"
  end
end

defmodule Lynx.Service.UserDeduperTest do
  @moduledoc """
  Pinning the auto-merge that runs from migration `…000013`. Without
  this, the unique-index step would fail on any DB that has
  duplicate-email user rows (legacy local user + later SCIM-
  provisioned user with the same email — very common).

  Since this code runs against operator DBs that still have
  `users.{auth_provider, external_id}` columns at merge time, these
  tests recreate those columns for the duration of each test (the
  Ecto User schema in this branch already lost them).
  """
  use LynxWeb.LiveCase, async: false

  alias Lynx.Repo
  alias Lynx.Service.UserDeduper

  setup do
    mark_installed()

    Repo.query!(
      "ALTER TABLE users ADD COLUMN IF NOT EXISTS auth_provider VARCHAR DEFAULT 'local'"
    )

    Repo.query!("ALTER TABLE users ADD COLUMN IF NOT EXISTS external_id VARCHAR")
    Repo.query!("DROP INDEX IF EXISTS users_email_unique_index")

    on_exit(fn ->
      Repo.query!("ALTER TABLE users DROP COLUMN IF EXISTS auth_provider")
      Repo.query!("ALTER TABLE users DROP COLUMN IF EXISTS external_id")
    end)

    :ok
  end

  defp insert_dup(email, attrs) do
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

  describe "merge_all_duplicates/1 — winner heuristic" do
    test "active SCIM beats inactive local (Aron's actual prod scenario)" do
      [_loser_id, loser_uuid] =
        insert_dup("aron@example.com",
          name: "Old Local",
          auth_provider: "local",
          external_id: "aron@example.com",
          is_active: false,
          last_seen: ~U[2026-01-01 00:00:00Z]
        )

      [winner_id, winner_uuid] =
        insert_dup("aron@example.com",
          name: "Aron Gates",
          auth_provider: "scim",
          external_id: "okta-uid-aron",
          is_active: true,
          last_seen: ~U[2026-01-15 00:00:00Z]
        )

      assert %{merged_count: 1, decisions: [decision]} = UserDeduper.merge_all_duplicates()

      assert decision.winner["uuid"] == winner_uuid
      assert decision.reason == "active SCIM-managed row"

      # Only the winner row remains.
      [count] =
        Repo.query!("SELECT COUNT(*) FROM users WHERE email = 'aron@example.com'")
        |> Map.fetch!(:rows)
        |> hd()

      assert count == 1

      # Loser's identity (the legacy local-with-external_id=email) was
      # linked to the winner — future SAML logins via NameID=email
      # still resolve to the canonical user.
      [identity_count] =
        Repo.query!(
          "SELECT COUNT(*) FROM user_identities WHERE user_id = $1 AND provider = 'local'",
          [winner_id]
        )
        |> Map.fetch!(:rows)
        |> hd()

      assert identity_count == 1

      refute_uuid_exists(loser_uuid)
    end

    test "active local beats inactive local (no SCIM in either)" do
      [_loser_id, loser_uuid] =
        insert_dup("local@example.com",
          auth_provider: "local",
          is_active: false,
          last_seen: ~U[2026-01-15 00:00:00Z]
        )

      [_winner_id, winner_uuid] =
        insert_dup("local@example.com",
          auth_provider: "local",
          is_active: true,
          last_seen: ~U[2026-01-01 00:00:00Z]
        )

      %{decisions: [decision]} = UserDeduper.merge_all_duplicates()

      # Active wins despite being older.
      assert decision.winner["uuid"] == winner_uuid
      assert decision.reason == "only active row"
      refute_uuid_exists(loser_uuid)
    end

    test "active SCIM beats active local (managed source wins)" do
      [_loser_id, loser_uuid] =
        insert_dup("both-active@example.com",
          auth_provider: "local",
          is_active: true,
          last_seen: ~U[2026-01-15 00:00:00Z]
        )

      [_winner_id, winner_uuid] =
        insert_dup("both-active@example.com",
          auth_provider: "scim",
          external_id: "okta-uid-both",
          is_active: true,
          last_seen: ~U[2026-01-01 00:00:00Z]
        )

      %{decisions: [decision]} = UserDeduper.merge_all_duplicates()

      assert decision.winner["uuid"] == winner_uuid
      assert decision.reason == "SCIM-managed (managed-source IdP)"
      refute_uuid_exists(loser_uuid)
    end

    test "all-deactivated, no SCIM → most recent wins" do
      [_old_id, old_uuid] =
        insert_dup("inactive@example.com",
          is_active: false,
          last_seen: ~U[2026-01-01 00:00:00Z]
        )

      [_new_id, new_uuid] =
        insert_dup("inactive@example.com",
          is_active: false,
          last_seen: ~U[2026-01-15 00:00:00Z]
        )

      %{decisions: [decision]} = UserDeduper.merge_all_duplicates()

      assert decision.winner["uuid"] == new_uuid
      assert decision.reason == "most recent activity"
      refute_uuid_exists(old_uuid)
    end
  end

  describe "merge_all_duplicates/1 — data preservation" do
    test "re-parents user_sessions onto the winner so logged-in browsers stay authenticated" do
      [loser_id, _] =
        insert_dup("session@example.com",
          is_active: false,
          last_seen: ~U[2026-01-01 00:00:00Z]
        )

      [winner_id, _] =
        insert_dup("session@example.com",
          auth_provider: "scim",
          external_id: "okta-uid-session",
          is_active: true,
          last_seen: ~U[2026-01-15 00:00:00Z]
        )

      Repo.query!(
        """
        INSERT INTO users_session (value, expire_at, user_id, auth_method, inserted_at, updated_at)
        VALUES ('test-session-token', NOW() + INTERVAL '1 hour', $1, 'password', NOW(), NOW())
        """,
        [loser_id]
      )

      UserDeduper.merge_all_duplicates()

      [session_count] =
        Repo.query!("SELECT COUNT(*) FROM users_session WHERE user_id = $1", [winner_id])
        |> Map.fetch!(:rows)
        |> hd()

      assert session_count == 1
    end
  end

  describe "merge_all_duplicates/1 — keep override" do
    test ":keep <uuid> overrides the heuristic" do
      [_default_winner_id, default_winner_uuid] =
        insert_dup("override@example.com",
          auth_provider: "scim",
          external_id: "okta-default",
          is_active: true,
          last_seen: ~U[2026-01-15 00:00:00Z]
        )

      [_local_id, local_uuid] =
        insert_dup("override@example.com",
          auth_provider: "local",
          is_active: true,
          last_seen: ~U[2026-01-01 00:00:00Z]
        )

      # Heuristic would pick the SCIM row; force the local one instead.
      %{decisions: [decision]} = UserDeduper.merge_all_duplicates(keep: local_uuid)

      assert decision.winner["uuid"] == local_uuid
      assert decision.reason == "forced via :keep option"

      refute_uuid_exists(default_winner_uuid)
    end

    test ":keep <unknown_uuid> raises" do
      insert_dup("raises@example.com", last_seen: ~U[2026-01-01 00:00:00Z])
      insert_dup("raises@example.com", last_seen: ~U[2026-01-15 00:00:00Z])

      bogus_uuid = Ecto.UUID.generate()

      assert_raise RuntimeError, ~r/keep: #{bogus_uuid} did not match/, fn ->
        UserDeduper.merge_all_duplicates(keep: bogus_uuid)
      end
    end
  end

  describe "merge_all_duplicates/1 — no-op cases" do
    test "no-op when no duplicates exist" do
      assert %{merged_count: 0, decisions: []} = UserDeduper.merge_all_duplicates()
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

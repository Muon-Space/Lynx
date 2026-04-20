defmodule Lynx.Service.AuthServiceTest do
  use Lynx.DataCase

  alias Lynx.Context.{ConfigContext, UserContext}
  alias Lynx.Service.AuthService

  defp create_user(attrs \\ %{}) do
    salt = AuthService.get_random_salt()
    password = Map.get(attrs, :password, "password123")

    defaults = %{
      email: "user-#{System.unique_integer([:positive])}@example.com",
      name: "Test User",
      password_hash: AuthService.hash_password(password, salt),
      verified: true,
      last_seen: DateTime.utc_now() |> DateTime.truncate(:second),
      role: "user",
      api_key: "test-api-key-#{System.unique_integer([:positive])}",
      uuid: Ecto.UUID.generate(),
      is_active: Map.get(attrs, :is_active, true)
    }

    {:ok, user} =
      defaults
      |> Map.merge(Map.delete(attrs, :password))
      |> UserContext.new_user()
      |> UserContext.create_user()

    user
  end

  describe "hash_password/2 + verify_password/2" do
    test "round-trip succeeds with the same salt and password" do
      salt = AuthService.get_random_salt()
      hash = AuthService.hash_password("hunter2", salt)
      assert AuthService.verify_password("hunter2", hash) == true
    end

    test "round-trip fails with a wrong password" do
      salt = AuthService.get_random_salt()
      hash = AuthService.hash_password("hunter2", salt)
      assert AuthService.verify_password("wrong", hash) == false
    end
  end

  describe "get_random_salt/2" do
    test "default returns a Bcrypt salt of 29 bytes" do
      assert byte_size(AuthService.get_random_salt()) == 29
    end

    test "successive calls return different salts" do
      refute AuthService.get_random_salt() == AuthService.get_random_salt()
    end
  end

  describe "get_uuid/0" do
    test "returns a valid UUID string" do
      uuid = AuthService.get_uuid()
      assert {:ok, _} = Ecto.UUID.cast(uuid)
    end
  end

  describe "login/2" do
    setup do
      # Seed app_key so login can hash; without it, password_hash on the
      # seeded user already encodes a known salt. We're not relying on
      # app_key for verify, only for create paths in other tests.
      :ok
    end

    test "returns {:success, session} for valid credentials" do
      user = create_user(%{password: "secret-pw-1"})
      assert {:success, session} = AuthService.login(user.email, "secret-pw-1")
      assert session.user_id == user.id
      assert is_binary(session.value)
    end

    test "rejects unknown email" do
      assert AuthService.login("nope@example.com", "any") ==
               {:error, "Invalid email or password"}
    end

    test "rejects wrong password for known user" do
      user = create_user(%{password: "right-pw"})

      assert AuthService.login(user.email, "wrong-pw") ==
               {:error, "Invalid email or password"}
    end

    test "rejects deactivated account" do
      user = create_user(%{password: "pw1", is_active: false})

      assert AuthService.login(user.email, "pw1") == {:error, "Account is deactivated"}
    end

    test "returns error when password auth is disabled via config" do
      user = create_user(%{password: "pw"})

      {:ok, _} =
        ConfigContext.create_config(
          ConfigContext.new_config(%{name: "auth_password_enabled", value: "false"})
        )

      assert AuthService.login(user.email, "pw") ==
               {:error, "Password authentication is disabled"}
    end

    test "rejects nil email or password" do
      assert AuthService.login(nil, "x") == {:error, "Invalid email or password"}
      assert AuthService.login("a@b.c", nil) == {:error, "Invalid email or password"}
      assert AuthService.login(nil, nil) == {:error, "Invalid email or password"}
    end
  end

  describe "login_sso/2" do
    test "creates a session for the user" do
      user = create_user()
      assert {:success, session} = AuthService.login_sso(user, "saml")
      assert session.user_id == user.id
      assert session.auth_method == "saml"
    end

    test "defaults auth_method to 'oidc'" do
      user = create_user()
      assert {:success, session} = AuthService.login_sso(user)
      assert session.auth_method == "oidc"
    end
  end

  describe "is_authenticated/2" do
    test "returns false when uid or token is nil" do
      assert AuthService.is_authenticated(nil, "tok") == false
      assert AuthService.is_authenticated(1, nil) == false
      assert AuthService.is_authenticated(nil, nil) == false
    end

    test "returns false for unknown session" do
      user = create_user()
      assert AuthService.is_authenticated(user.id, "no-such-token") == false
    end

    test "returns {true, session} for valid (user_id, session value) pair" do
      user = create_user()
      {:success, session} = AuthService.authenticate(user.id)

      assert {true, returned} = AuthService.is_authenticated(user.id, session.value)
      assert returned.user_id == user.id
    end
  end

  describe "authenticate/1" do
    test "returns {:error, _} for nil user_id" do
      assert AuthService.authenticate(nil) == {:error, "Invalid User ID"}
    end

    test "creates a session and clears any prior sessions for the user" do
      user = create_user()

      {:success, first} = AuthService.authenticate(user.id)
      assert {true, _} = AuthService.is_authenticated(user.id, first.value)

      {:success, second} = AuthService.authenticate(user.id)
      assert second.value != first.value

      # Old session is gone
      assert AuthService.is_authenticated(user.id, first.value) == false
      # New session works
      assert {true, _} = AuthService.is_authenticated(user.id, second.value)
    end
  end

  describe "authenticate_sso/2" do
    test "returns {:error, _} for nil user_id" do
      assert AuthService.authenticate_sso(nil, "oidc") == {:error, "Invalid User ID"}
    end

    test "stores the auth_method on the session" do
      user = create_user()
      {:success, session} = AuthService.authenticate_sso(user.id, "saml")
      assert session.auth_method == "saml"
    end
  end

  describe "logout/1" do
    test "is a no-op when user_id is nil" do
      assert AuthService.logout(nil) == nil
    end

    test "deletes all sessions for the user" do
      user = create_user()
      {:success, session} = AuthService.authenticate(user.id)
      assert {true, _} = AuthService.is_authenticated(user.id, session.value)

      AuthService.logout(user.id)
      assert AuthService.is_authenticated(user.id, session.value) == false
    end
  end

  describe "get_user_by_api/1" do
    test "returns {:not_found, _} for nil api_key" do
      assert {:not_found, _} = AuthService.get_user_by_api(nil)
    end

    test "returns {:not_found, _} for unknown api_key" do
      assert {:not_found, _} = AuthService.get_user_by_api("does-not-exist")
    end

    test "returns {:ok, user} for a valid api_key" do
      user = create_user(%{api_key: "known-api-key-#{System.unique_integer([:positive])}"})
      assert {:ok, returned} = AuthService.get_user_by_api(user.api_key)
      assert returned.id == user.id
    end
  end

  describe "password_auth_enabled?/0" do
    test "is true by default (no config row)" do
      assert AuthService.password_auth_enabled?() == true
    end

    test "is false when config is set to 'false'" do
      {:ok, _} =
        ConfigContext.create_config(
          ConfigContext.new_config(%{name: "auth_password_enabled", value: "false"})
        )

      assert AuthService.password_auth_enabled?() == false
    end
  end
end

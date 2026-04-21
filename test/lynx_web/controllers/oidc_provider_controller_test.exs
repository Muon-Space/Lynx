defmodule LynxWeb.OIDCProviderControllerTest do
  use LynxWeb.ConnCase

  alias Lynx.Service.OIDCBackend
  alias Lynx.Context.{EnvironmentContext, ProjectContext, UserContext, WorkspaceContext}

  setup %{conn: conn} do
    api_key = install_admin_and_get_api_key(conn)
    {:ok, conn: conn, api_key: api_key}
  end

  defp create_test_env do
    {:ok, ws} =
      WorkspaceContext.create_workspace(
        WorkspaceContext.new_workspace(%{
          name: "WS#{System.unique_integer([:positive])}",
          slug: "ws-#{System.unique_integer([:positive])}",
          description: "test"
        })
      )

    {:ok, project} =
      ProjectContext.create_project(
        ProjectContext.new_project(%{
          name: "P#{System.unique_integer([:positive])}",
          slug: "p-#{System.unique_integer([:positive])}",
          description: "test",
          workspace_id: ws.id
        })
      )

    {:ok, env} =
      EnvironmentContext.create_env(
        EnvironmentContext.new_env(%{
          name: "Env",
          slug: "env-#{System.unique_integer([:positive])}",
          username: "u",
          secret: "s",
          project_id: project.id
        })
      )

    env
  end

  defp create_test_provider do
    {:ok, provider} =
      OIDCBackend.create_provider(%{
        name: "test-provider-#{System.unique_integer([:positive])}",
        discovery_url: "https://example.com/.well-known/openid-configuration",
        audience: "test-audience"
      })

    provider
  end

  defp regular_user_api_key do
    {:ok, user} =
      UserContext.create_user(
        UserContext.new_user(%{
          email: "regular-#{System.unique_integer([:positive])}@example.com",
          name: "Regular User",
          password_hash: "$2b$12$" <> String.duplicate("a", 53),
          verified: true,
          last_seen: DateTime.utc_now() |> DateTime.truncate(:second),
          role: "user",
          api_key: "regular-key-#{System.unique_integer([:positive])}",
          uuid: Ecto.UUID.generate()
        })
      )

    user.api_key
  end

  describe "auth" do
    test "GET /api/v1/oidc_provider without API key returns 403", %{conn: conn} do
      conn = get(conn, "/api/v1/oidc_provider")
      assert response(conn, 403)
    end

    test "non-super user gets 403", %{conn: conn} do
      conn = conn |> with_api_key(regular_user_api_key()) |> get("/api/v1/oidc_provider")
      assert response(conn, 403)
    end
  end

  describe "list_providers" do
    test "returns empty list initially", %{conn: conn, api_key: api_key} do
      conn = conn |> with_api_key(api_key) |> get("/api/v1/oidc_provider")
      body = json_response(conn, 200)
      assert body["providers"] == []
    end

    test "returns providers in JSON shape", %{conn: conn, api_key: api_key} do
      provider = create_test_provider()

      conn = conn |> with_api_key(api_key) |> get("/api/v1/oidc_provider")
      body = json_response(conn, 200)

      [p] = body["providers"]
      assert p["id"] == provider.uuid
      assert p["name"] == provider.name
      assert p["discoveryUrl"] == provider.discovery_url
      assert p["audience"] == provider.audience
      assert p["isActive"] == true
    end
  end

  describe "create_provider" do
    test "creates a provider with valid params", %{conn: conn, api_key: api_key} do
      conn =
        conn
        |> with_api_key(api_key)
        |> post("/api/v1/oidc_provider", %{
          name: "github-actions",
          discovery_url: "https://token.actions.githubusercontent.com",
          audience: "lynx"
        })

      body = json_response(conn, 201)
      assert body["name"] == "github-actions"
      assert body["successMessage"] =~ "created"
      assert OIDCBackend.list_providers() |> Enum.any?(&(&1.name == "github-actions"))
    end

    test "returns 400 when name is missing", %{conn: conn, api_key: api_key} do
      conn =
        conn
        |> with_api_key(api_key)
        |> post("/api/v1/oidc_provider", %{
          discovery_url: "https://example.com",
          audience: "x"
        })

      assert response(conn, 400)
    end
  end

  describe "update_provider" do
    test "updates name and discovery_url", %{conn: conn, api_key: api_key} do
      provider = create_test_provider()

      conn =
        conn
        |> with_api_key(api_key)
        |> put("/api/v1/oidc_provider/#{provider.uuid}", %{
          name: "renamed",
          discovery_url: "https://new.example.com",
          audience: provider.audience
        })

      body = json_response(conn, 200)
      assert body["name"] == "renamed"
      assert body["discoveryUrl"] == "https://new.example.com"
    end

    test "returns 404 for unknown uuid", %{conn: conn, api_key: api_key} do
      conn =
        conn
        |> with_api_key(api_key)
        |> put("/api/v1/oidc_provider/00000000-0000-0000-0000-000000000000", %{name: "x"})

      assert response(conn, 404)
    end
  end

  describe "delete_provider" do
    test "deletes existing provider", %{conn: conn, api_key: api_key} do
      provider = create_test_provider()

      conn =
        conn
        |> with_api_key(api_key)
        |> delete("/api/v1/oidc_provider/#{provider.uuid}")

      body = json_response(conn, 200)
      assert body["successMessage"] =~ "deleted"
      refute Enum.any?(OIDCBackend.list_providers(), &(&1.uuid == provider.uuid))
    end

    test "returns 404 for unknown uuid", %{conn: conn, api_key: api_key} do
      conn =
        conn
        |> with_api_key(api_key)
        |> delete("/api/v1/oidc_provider/00000000-0000-0000-0000-000000000000")

      assert response(conn, 404)
    end
  end

  describe "list_rules" do
    test "returns rules for an environment", %{conn: conn, api_key: api_key} do
      env = create_test_env()
      provider = create_test_provider()

      {:ok, rule} =
        OIDCBackend.create_rule(%{
          name: "ci-deploy",
          claim_rules: ~s([{"claim":"repo","operator":"eq","value":"org/x"}]),
          provider_id: provider.id,
          environment_id: env.id
        })

      conn = conn |> with_api_key(api_key) |> get("/api/v1/oidc_rule/#{env.uuid}")
      body = json_response(conn, 200)

      [r] = body["rules"]
      assert r["id"] == rule.uuid
      assert r["name"] == "ci-deploy"
      assert is_list(r["claimRules"])
    end

    test "returns 404 for unknown environment uuid", %{conn: conn, api_key: api_key} do
      conn =
        conn
        |> with_api_key(api_key)
        |> get("/api/v1/oidc_rule/00000000-0000-0000-0000-000000000000")

      assert response(conn, 404)
    end
  end

  describe "create_rule" do
    test "creates a rule with valid provider + env + claims", %{conn: conn, api_key: api_key} do
      env = create_test_env()
      provider = create_test_provider()

      conn =
        conn
        |> with_api_key(api_key)
        |> post("/api/v1/oidc_rule", %{
          name: "deploy-rule",
          provider_id: provider.uuid,
          environment_id: env.uuid,
          claim_rules: [%{claim: "repo", operator: "eq", value: "org/infra"}]
        })

      body = json_response(conn, 201)
      assert body["name"] == "deploy-rule"
      assert body["successMessage"] =~ "created"
    end

    test "accepts claim_rules as JSON string", %{conn: conn, api_key: api_key} do
      env = create_test_env()
      provider = create_test_provider()

      conn =
        conn
        |> with_api_key(api_key)
        |> post("/api/v1/oidc_rule", %{
          name: "string-claims",
          provider_id: provider.uuid,
          environment_id: env.uuid,
          claim_rules: ~s([{"claim":"x","operator":"eq","value":"y"}])
        })

      assert response(conn, 201)
    end

    test "returns 400 when provider_id is unknown", %{conn: conn, api_key: api_key} do
      env = create_test_env()

      conn =
        conn
        |> with_api_key(api_key)
        |> post("/api/v1/oidc_rule", %{
          name: "bad",
          provider_id: "00000000-0000-0000-0000-000000000000",
          environment_id: env.uuid,
          claim_rules: []
        })

      body = json_response(conn, 400)
      assert body["errorMessage"] =~ "Invalid"
    end

    test "returns 404 when environment_id is unknown", %{conn: conn, api_key: api_key} do
      provider = create_test_provider()

      conn =
        conn
        |> with_api_key(api_key)
        |> post("/api/v1/oidc_rule", %{
          name: "bad",
          provider_id: provider.uuid,
          environment_id: "00000000-0000-0000-0000-000000000000",
          claim_rules: []
        })

      # The RequirePerm plug runs before the controller body and rejects
      # missing-env requests at the auth layer with 404 (more accurate than
      # the previous 400 from the controller's downstream nil check).
      body = json_response(conn, 404)
      assert body["errorMessage"] =~ "Environment not found"
    end
  end

  describe "delete_rule" do
    test "deletes existing rule", %{conn: conn, api_key: api_key} do
      env = create_test_env()
      provider = create_test_provider()

      {:ok, rule} =
        OIDCBackend.create_rule(%{
          name: "to-delete",
          claim_rules: ~s([{"claim":"x","operator":"eq","value":"y"}]),
          provider_id: provider.id,
          environment_id: env.id
        })

      conn = conn |> with_api_key(api_key) |> delete("/api/v1/oidc_rule/#{rule.uuid}")
      body = json_response(conn, 200)
      assert body["successMessage"] =~ "deleted"
    end

    test "returns 404 for unknown rule uuid", %{conn: conn, api_key: api_key} do
      conn =
        conn
        |> with_api_key(api_key)
        |> delete("/api/v1/oidc_rule/00000000-0000-0000-0000-000000000000")

      assert response(conn, 404)
    end
  end
end

defmodule LynxWeb.Plug.RequirePermTest do
  @moduledoc """
  End-to-end coverage for the `LynxWeb.Plug.RequirePerm` plug via the REST
  endpoints it gates. Each test asserts both:

    * the plug returns `403 Forbidden` for an authenticated user lacking the
      named permission on the resource's project, and
    * the same request succeeds (or hits the controller body's normal error
      path) for a user with the right grant.
  """
  use LynxWeb.ConnCase

  alias Lynx.Context.{
    EnvironmentContext,
    LockContext,
    ProjectContext,
    RoleContext,
    SnapshotContext,
    TeamContext,
    UserContext,
    WorkspaceContext
  }

  alias Lynx.Service.OIDCBackend

  setup %{conn: conn} do
    install_admin_and_get_api_key(conn)
    {:ok, conn: conn}
  end

  # -- Helpers --

  # Grant a user `role_name` on `project` via a team. The team route also
  # satisfies the legacy `:access_check` plug (which only knows about team
  # membership, not direct `user_projects` grants) — without it, every test
  # would 403 at the access-check stage before reaching `RequirePerm`.
  defp grant(user, project, role_name) do
    role = RoleContext.get_role_by_name(role_name)
    n = System.unique_integer([:positive])

    {:ok, team} =
      TeamContext.create_team(
        TeamContext.new_team(%{
          name: "T-#{n}",
          slug: "t-#{n}",
          description: "x"
        })
      )

    {:ok, _} = UserContext.add_user_to_team(user.id, team.id)
    {:ok, _} = ProjectContext.add_project_to_team(project.id, team.id, role.id)
    team
  end

  defp create_workspace_for_test do
    n = System.unique_integer([:positive])

    {:ok, ws} =
      WorkspaceContext.create_workspace(
        WorkspaceContext.new_workspace(%{
          name: "WS-#{n}",
          slug: "ws-#{n}"
        })
      )

    ws
  end

  defp create_project_in(ws) do
    n = System.unique_integer([:positive])

    {:ok, project} =
      ProjectContext.create_project(
        ProjectContext.new_project(%{
          name: "Proj-#{n}",
          slug: "proj-#{n}",
          description: "p",
          workspace_id: ws.id
        })
      )

    project
  end

  defp create_env_in(project) do
    n = System.unique_integer([:positive])

    {:ok, env} =
      EnvironmentContext.create_env(
        EnvironmentContext.new_env(%{
          name: "Env-#{n}",
          slug: "env-#{n}",
          username: "u#{n}",
          secret: "s#{n}",
          project_id: project.id
        })
      )

    env
  end

  # -- project:manage on PUT/DELETE /api/v1/project --

  describe "project:manage" do
    test "PUT /api/v1/project/:uuid 403s when user lacks project:manage", %{conn: conn} do
      ws = create_workspace_for_test()
      project = create_project_in(ws)
      {user, api_key} = create_regular_user_with_api_key()
      grant(user, project, "planner")

      conn =
        conn
        |> with_api_key(api_key)
        |> put("/api/v1/project/#{project.uuid}", %{
          name: "renamed",
          description: "x",
          slug: "renamed"
        })

      assert json_response(conn, 403)["errorMessage"] =~ "project:manage"
    end

    test "DELETE /api/v1/project/:uuid 403s without project:manage", %{conn: conn} do
      ws = create_workspace_for_test()
      project = create_project_in(ws)
      {user, api_key} = create_regular_user_with_api_key()
      grant(user, project, "applier")

      conn = conn |> with_api_key(api_key) |> delete("/api/v1/project/#{project.uuid}")
      assert json_response(conn, 403)["errorMessage"] =~ "project:manage"
    end

    test "PUT succeeds with admin role", %{conn: conn} do
      ws = create_workspace_for_test()
      project = create_project_in(ws)
      {user, api_key} = create_regular_user_with_api_key()
      grant(user, project, "admin")

      conn =
        conn
        |> with_api_key(api_key)
        |> put("/api/v1/project/#{project.uuid}", %{
          name: "renamed",
          description: "new desc",
          slug: "renamed-slug"
        })

      assert json_response(conn, 200)["name"] == "renamed"
    end
  end

  # -- env:manage on POST/PUT/DELETE /api/v1/project/:p/environment --

  describe "env:manage" do
    test "POST environment 403s without env:manage", %{conn: conn} do
      ws = create_workspace_for_test()
      project = create_project_in(ws)
      {user, api_key} = create_regular_user_with_api_key()
      grant(user, project, "applier")

      conn =
        conn
        |> with_api_key(api_key)
        |> post("/api/v1/project/#{project.uuid}/environment", %{
          name: "new",
          slug: "new",
          username: "u",
          secret: "s"
        })

      assert json_response(conn, 403)["errorMessage"] =~ "env:manage"
    end

    test "DELETE environment 403s without env:manage", %{conn: conn} do
      ws = create_workspace_for_test()
      project = create_project_in(ws)
      env = create_env_in(project)
      {user, api_key} = create_regular_user_with_api_key()
      grant(user, project, "planner")

      conn =
        conn
        |> with_api_key(api_key)
        |> delete("/api/v1/project/#{project.uuid}/environment/#{env.uuid}")

      assert json_response(conn, 403)["errorMessage"] =~ "env:manage"
    end
  end

  # -- state:lock and state:force_unlock on env force_lock/force_unlock --

  describe "state:lock and state:force_unlock split" do
    test "POST /environment/:e/lock succeeds with planner role", %{conn: conn} do
      ws = create_workspace_for_test()
      project = create_project_in(ws)
      env = create_env_in(project)
      {user, api_key} = create_regular_user_with_api_key()
      grant(user, project, "planner")

      conn =
        conn
        |> with_api_key(api_key)
        |> post("/api/v1/environment/#{env.uuid}/lock", %{})

      assert response(conn, 200)
    end

    test "POST /environment/:e/unlock 403s for planner (lacks state:force_unlock)", %{conn: conn} do
      ws = create_workspace_for_test()
      project = create_project_in(ws)
      env = create_env_in(project)
      {user, api_key} = create_regular_user_with_api_key()
      grant(user, project, "planner")

      conn =
        conn
        |> with_api_key(api_key)
        |> post("/api/v1/environment/#{env.uuid}/unlock", %{})

      assert json_response(conn, 403)["errorMessage"] =~ "state:force_unlock"
    end

    test "POST /environment/:e/unlock 403s for applier (lacks state:force_unlock)", %{conn: conn} do
      ws = create_workspace_for_test()
      project = create_project_in(ws)
      env = create_env_in(project)
      {user, api_key} = create_regular_user_with_api_key()
      grant(user, project, "applier")

      conn =
        conn
        |> with_api_key(api_key)
        |> post("/api/v1/environment/#{env.uuid}/unlock", %{})

      assert json_response(conn, 403)["errorMessage"] =~ "state:force_unlock"
    end

    test "POST /environment/:e/unlock succeeds for admin", %{conn: conn} do
      ws = create_workspace_for_test()
      project = create_project_in(ws)
      env = create_env_in(project)
      _ = LockContext.force_lock(env.id, "tester")

      {user, api_key} = create_regular_user_with_api_key()
      grant(user, project, "admin")

      conn =
        conn
        |> with_api_key(api_key)
        |> post("/api/v1/environment/#{env.uuid}/unlock", %{})

      assert response(conn, 200)
    end
  end

  # -- snapshot:restore --

  describe "snapshot:restore" do
    test "POST /snapshot/restore/:uuid 403s without snapshot:restore", %{conn: conn} do
      ws = create_workspace_for_test()
      project = create_project_in(ws)
      {user, api_key} = create_regular_user_with_api_key()
      team = grant(user, project, "applier")

      # `:access_check` filters snapshots by the requesting user's team UUIDs,
      # so the snapshot must belong to a team the user is on.
      {:ok, snapshot} =
        SnapshotContext.create_snapshot_from_data(%{
          title: "Backup",
          description: "x",
          record_type: "project",
          record_uuid: project.uuid,
          status: "success",
          data: ~s({"name":"x","environments":[]}),
          team_id: team.uuid
        })

      conn =
        conn
        |> with_api_key(api_key)
        |> post("/api/v1/snapshot/restore/#{snapshot.uuid}", %{})

      assert json_response(conn, 403)["errorMessage"] =~ "snapshot:restore"
    end
  end

  # -- oidc_rule:manage --

  describe "oidc_rule:manage" do
    test "POST /oidc_rule 403s without oidc_rule:manage", %{conn: conn} do
      ws = create_workspace_for_test()
      project = create_project_in(ws)
      env = create_env_in(project)
      {user, api_key} = create_regular_user_with_api_key()
      grant(user, project, "applier")

      {:ok, provider} =
        OIDCBackend.create_provider(%{
          name: "P",
          discovery_url: "https://example.com/.well-known/openid-configuration",
          audience: "lynx"
        })

      conn =
        conn
        |> with_api_key(api_key)
        |> post("/api/v1/oidc_rule", %{
          name: "r",
          provider_id: provider.uuid,
          environment_id: env.uuid,
          claim_rules: %{}
        })

      assert json_response(conn, 403)["errorMessage"] =~ "oidc_rule:manage"
    end

    test "POST /oidc_rule succeeds for admin", %{conn: conn} do
      ws = create_workspace_for_test()
      project = create_project_in(ws)
      env = create_env_in(project)
      {user, api_key} = create_regular_user_with_api_key()
      grant(user, project, "admin")

      {:ok, provider} =
        OIDCBackend.create_provider(%{
          name: "P-#{System.unique_integer([:positive])}",
          discovery_url: "https://example.com/.well-known/openid-configuration",
          audience: "lynx"
        })

      conn =
        conn
        |> with_api_key(api_key)
        |> post("/api/v1/oidc_rule", %{
          name: "r",
          provider_id: provider.uuid,
          environment_id: env.uuid,
          claim_rules: %{}
        })

      assert json_response(conn, 201)
    end
  end
end

defmodule LynxWeb.EnvironmentLiveTest do
  use LynxWeb.LiveCase

  alias Lynx.Context.LockContext

  setup %{conn: conn} do
    # super bypasses per-project RBAC so existing happy-path tests still
    # exercise the underlying lock + env behavior. Permission-denial cases
    # live in their own describe blocks below.
    user = create_super()
    workspace = create_workspace()
    project = create_project(%{workspace_id: workspace.id})
    env = create_env(project, %{name: "Production", slug: "prod"})

    {:ok,
     conn: log_in_user(conn, user), user: user, workspace: workspace, project: project, env: env}
  end

  defp env_path(project, env),
    do: "/admin/projects/#{project.uuid}/environments/#{env.uuid}"

  # Backend config is rendered into a <pre> via HEEx interpolation, which
  # HTML-escapes quotes. Parse and decode to assert on the source as written.
  defp backend_config(view_or_html) do
    html = if is_binary(view_or_html), do: view_or_html, else: render(view_or_html)

    html
    |> Floki.parse_document!()
    |> Floki.find("#backend-config-content")
    |> Floki.text()
  end

  describe "mount" do
    test "renders env name and breadcrumb", %{conn: conn, project: project, env: env} do
      {:ok, _view, html} = live(conn, env_path(project, env))
      assert html =~ env.name
      assert html =~ project.name
    end

    test "redirects when project not found", %{conn: conn, env: env} do
      bad_path =
        "/admin/projects/00000000-0000-0000-0000-000000000000/environments/#{env.uuid}"

      assert {:error, {:redirect, %{to: "/admin/projects"}}} = live(conn, bad_path)
    end

    test "redirects when env not found", %{conn: conn, project: project} do
      bad_path =
        "/admin/projects/#{project.uuid}/environments/00000000-0000-0000-0000-000000000000"

      assert {:error, {:redirect, %{to: "/admin/projects/" <> _}}} = live(conn, bad_path)
    end

    test "shows Terraform config by default with env credentials", %{
      conn: conn,
      project: project,
      env: env
    } do
      {:ok, _view, html} = live(conn, env_path(project, env))
      assert html =~ "Terraform"
      assert html =~ "Terragrunt"

      config = backend_config(html)
      assert config =~ ~s(backend "http")
      assert config =~ env.username
      assert config =~ env.secret
    end

    test "lists units when state exists", %{conn: conn, project: project, env: env} do
      _ = create_state(env, %{sub_path: "", value: ~s({"v":1})})
      _ = create_state(env, %{sub_path: "dns", value: ~s({"v":2})})

      {:ok, _view, html} = live(conn, env_path(project, env))
      assert html =~ "(root)"
      assert html =~ "dns"
    end

    test "empty state when no units", %{conn: conn, project: project, env: env} do
      {:ok, _view, html} = live(conn, env_path(project, env))
      assert html =~ "No units yet"
    end

    test "?oidc=1 deep-link opens the OIDC rules modal on mount", %{
      conn: conn,
      project: project,
      env: env
    } do
      # The role-detail page's "Manage" link on OIDC rules sends the admin
      # straight to the env page with this query param so they land on the
      # rules editor instead of having to click OIDC themselves.
      {:ok, _view, html} = live(conn, env_path(project, env) <> "?oidc=1")

      assert html =~ ~s(id="oidc-rules")
      assert html =~ "OIDC Access Rules"
    end

    test "no ?oidc param leaves the modal closed", %{conn: conn, project: project, env: env} do
      {:ok, _view, html} = live(conn, env_path(project, env))
      refute html =~ ~s(id="oidc-rules")
    end
  end

  describe "config tab switching" do
    test "show_terragrunt_config swaps tab to Terragrunt", %{
      conn: conn,
      project: project,
      env: env
    } do
      {:ok, view, _} = live(conn, env_path(project, env))

      assert backend_config(view) =~ ~s(backend "http")
      render_click(view, "show_terragrunt_config", %{})

      config = backend_config(view)
      assert config =~ "remote_state"
      assert config =~ "path_relative_to_include"
    end

    test "show_terraform_config swaps back to Terraform", %{
      conn: conn,
      project: project,
      env: env
    } do
      {:ok, view, _} = live(conn, env_path(project, env))
      render_click(view, "show_terragrunt_config", %{})
      render_click(view, "show_terraform_config", %{})

      config = backend_config(view)
      assert config =~ ~s(backend "http")
      refute config =~ "path_relative_to_include"
    end
  end

  describe "environment lock/unlock" do
    test "env_force_lock locks environment and updates badge action", %{
      conn: conn,
      project: project,
      env: env
    } do
      {:ok, view, _} = live(conn, env_path(project, env))

      assert has_element?(view, "[phx-value-event=\"env_force_lock\"]")

      render_click(view, "env_force_lock", %{"uuid" => env.uuid})

      assert render(view) =~ "Environment locked"
      assert has_element?(view, "[phx-value-event=\"env_force_unlock\"]")
    end

    test "env_force_unlock unlocks environment", %{conn: conn, project: project, env: env} do
      create_lock(env, %{is_active: true, sub_path: ""})
      {:ok, view, _} = live(conn, env_path(project, env))

      assert has_element?(view, "[phx-value-event=\"env_force_unlock\"]")

      render_click(view, "env_force_unlock", %{"uuid" => env.uuid})

      assert render(view) =~ "Environment unlocked"
      assert has_element?(view, "[phx-value-event=\"env_force_lock\"]")
    end
  end

  describe "unit lock/unlock" do
    test "lock_unit creates lock for the unit's sub_path", %{
      conn: conn,
      project: project,
      env: env
    } do
      _ = create_state(env, %{sub_path: "api", value: "{}"})

      {:ok, view, _} = live(conn, env_path(project, env))

      render_click(view, "lock_unit", %{"uuid" => "api"})

      assert render(view) =~ "Unit locked"
      assert LockContext.get_active_lock_by_environment_and_path(env.id, "api") != nil
    end

    test "unlock_unit deactivates the lock", %{conn: conn, project: project, env: env} do
      _ = create_state(env, %{sub_path: "api", value: "{}"})
      create_lock(env, %{sub_path: "api", is_active: true})

      {:ok, view, _} = live(conn, env_path(project, env))

      render_click(view, "unlock_unit", %{"uuid" => "api"})

      assert render(view) =~ "Unit unlocked"
      assert LockContext.get_active_lock_by_environment_and_path(env.id, "api") == nil
    end
  end

  describe "permission gates" do
    alias Lynx.Context.{ProjectContext, RoleContext, TeamContext, UserContext}

    # Set up a non-super user with a single role on the project. Returns a
    # logged-in conn for that user. Lynx's permission inputs come from the
    # composable team membership + role assignment path, so we wire that up
    # rather than poking RoleContext directly.
    defp logged_in_with_role(project, role_name) do
      user = create_user()

      {:ok, team} =
        TeamContext.create_team_from_data(%{
          name: "T-#{System.unique_integer([:positive])}",
          slug: "t-#{System.unique_integer([:positive])}",
          description: "x"
        })

      {:ok, _} = UserContext.add_user_to_team(user.id, team.id)
      role = RoleContext.get_role_by_name(role_name)
      {:ok, _} = ProjectContext.add_project_to_team(project.id, team.id, role.id)

      Phoenix.ConnTest.build_conn()
      |> Plug.Test.init_test_session(%{})
      |> log_in_user(user)
    end

    test "planner cannot env_force_lock; flash shows missing permission", %{
      project: project,
      env: env
    } do
      conn = logged_in_with_role(project, "planner")
      {:ok, view, _} = live(conn, env_path(project, env))

      # planner has state:lock so env_force_lock should succeed.
      render_click(view, "env_force_lock", %{"uuid" => env.uuid})
      assert render(view) =~ "Environment locked"

      # ...but lacks state:force_unlock — the unlock should be blocked.
      render_click(view, "env_force_unlock", %{"uuid" => env.uuid})
      html = render(view)
      assert html =~ "permission for state:force_unlock"
      # Env is still locked.
      assert LockContext.is_environment_locked(env.id)
    end

    test "applier cannot force-unlock either; flash shows the gate", %{
      project: project,
      env: env
    } do
      _ = LockContext.force_lock(env.id, "tester")
      conn = logged_in_with_role(project, "applier")
      {:ok, view, _} = live(conn, env_path(project, env))

      render_click(view, "env_force_unlock", %{"uuid" => env.uuid})
      assert render(view) =~ "permission for state:force_unlock"
      assert LockContext.is_environment_locked(env.id)
    end

    test "admin can force-unlock", %{project: project, env: env} do
      _ = LockContext.force_lock(env.id, "tester")
      conn = logged_in_with_role(project, "admin")
      {:ok, view, _} = live(conn, env_path(project, env))

      render_click(view, "env_force_unlock", %{"uuid" => env.uuid})
      assert render(view) =~ "Environment unlocked"
      refute LockContext.is_environment_locked(env.id)
    end

    test "lock badge is rendered with cursor-not-allowed for planner", %{
      project: project,
      env: env
    } do
      _ = LockContext.force_lock(env.id, "tester")
      conn = logged_in_with_role(project, "planner")
      {:ok, _view, html} = live(conn, env_path(project, env))

      # Env is locked → unlock would be the action → planner lacks
      # state:force_unlock → badge gets the disabled affordance class +
      # title attribute.
      assert html =~ "cursor-not-allowed"
      assert html =~ "Requires the admin role to force-unlock"
    end
  end
end

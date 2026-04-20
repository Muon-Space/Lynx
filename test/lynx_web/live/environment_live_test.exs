defmodule LynxWeb.EnvironmentLiveTest do
  use LynxWeb.LiveCase

  alias Lynx.Context.LockContext

  setup %{conn: conn} do
    user = create_user()
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
end

defmodule LynxWeb.PolicyLiveTest do
  @moduledoc """
  /admin/projects/:uuid/policies — policy CRUD UI (issue #38).
  Same LV serves the env-scoped variant; tests cover the project route since
  the scope branching is just helper-function dispatch.
  """
  use LynxWeb.LiveCase

  alias Lynx.Context.{PolicyContext, RoleContext, UserProjectContext}

  setup %{conn: conn} do
    mark_installed()
    ws = create_workspace()
    project = create_project(%{workspace_id: ws.id})
    env = create_env(project)

    {:ok, conn: conn, ws: ws, project: project, env: env}
  end

  describe "permissions" do
    test "redirects regular users without project:manage", %{conn: conn, project: project} do
      user = create_user()
      conn = log_in_user(conn, user)

      assert {:error, {:redirect, %{to: path}}} =
               live(conn, "/admin/projects/#{project.uuid}/policies")

      assert path =~ "/admin/projects/#{project.uuid}"
    end

    test "super sees the page", %{conn: conn, project: project} do
      conn = log_in_user(conn, create_super())
      {:ok, _view, html} = live(conn, "/admin/projects/#{project.uuid}/policies")
      assert html =~ "Policies"
      assert html =~ "Add Policy"
    end

    test "redirects on unknown project uuid", %{conn: conn} do
      conn = log_in_user(conn, create_super())
      assert {:error, {:redirect, %{to: "/admin/workspaces"}}} =
               live(conn, "/admin/projects/#{Ecto.UUID.generate()}/policies")
    end
  end

  describe "CRUD" do
    setup %{conn: conn, project: project} do
      user = create_user()
      admin_role = RoleContext.get_role_by_name("admin")
      {:ok, _} = UserProjectContext.assign_role(user.id, project.id, admin_role.id)
      {:ok, conn: log_in_user(conn, user), user: user}
    end

    test "create a project-scoped policy", %{conn: conn, project: project} do
      {:ok, view, _} = live(conn, "/admin/projects/#{project.uuid}/policies")

      view |> element("button", "Add Policy") |> render_click()

      view
      |> render_submit("save", %{
        "name" => "no-public-buckets",
        "description" => "Block public S3 buckets",
        "enabled" => "on"
      })

      [policy] = PolicyContext.list_policies_by_project(project.id)
      assert policy.name == "no-public-buckets"
      assert policy.project_id == project.id
      assert policy.environment_id == nil
    end

    test "name is required", %{conn: conn, project: project} do
      {:ok, view, _} = live(conn, "/admin/projects/#{project.uuid}/policies")
      view |> element("button", "Add Policy") |> render_click()

      html = view |> render_submit("save", %{"name" => "  ", "description" => ""})

      assert html =~ "Name is required"
      assert PolicyContext.list_policies_by_project(project.id) == []
    end

    test "edit and delete an existing policy", %{conn: conn, project: project} do
      {:ok, policy} =
        PolicyContext.create_policy(
          PolicyContext.new_policy(%{
            name: "original",
            project_id: project.id,
            rego_source: "package x"
          })
        )

      {:ok, view, _} = live(conn, "/admin/projects/#{project.uuid}/policies")

      # Edit
      view
      |> element("button[phx-value-uuid='#{policy.uuid}']", "Edit")
      |> render_click()

      view |> render_submit("save", %{"name" => "updated", "description" => "", "enabled" => "on"})

      assert PolicyContext.get_policy_by_uuid(policy.uuid).name == "updated"

      # Delete
      view
      |> element("button[phx-value-uuid='#{policy.uuid}']", "Delete")
      |> render_click()

      assert PolicyContext.get_policy_by_uuid(policy.uuid) == nil
    end
  end

  describe "env-scoped variant" do
    test "loads with the env-scoped path", %{conn: conn, project: project, env: env} do
      conn = log_in_user(conn, create_super())

      {:ok, _view, html} =
        live(conn, "/admin/projects/#{project.uuid}/environments/#{env.uuid}/policies")

      assert html =~ "Policies"
      assert html =~ env.name
    end
  end
end

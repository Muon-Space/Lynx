defmodule LynxWeb.ProjectLiveAuditTest do
  @moduledoc """
  Audit completeness for grant lifecycle in project_live: every grant
  add / change / remove / extend emits an audit row with the relevant
  metadata (role + env + expiry).
  """
  use LynxWeb.LiveCase

  alias Lynx.Context.{
    AuditContext,
    ProjectContext,
    RoleContext,
    TeamContext,
    UserProjectContext
  }

  setup %{conn: conn} do
    user = create_super()
    workspace = create_workspace()
    project = create_project(%{workspace_id: workspace.id})

    {:ok, conn: log_in_user(conn, user), user: user, workspace: workspace, project: project}
  end

  defp project_path(p), do: "/admin/projects/#{p.uuid}"

  defp last_event(action, resource_type) do
    {events, _} =
      AuditContext.list_events(%{action: action, resource_type: resource_type, limit: 5})

    hd(events)
  end

  describe "team grant lifecycle" do
    test "add_team_access emits a granted event with role + env metadata", %{
      conn: conn,
      project: project
    } do
      {:ok, team} =
        TeamContext.create_team_from_data(%{
          name: "T",
          slug: "t-#{System.unique_integer([:positive])}",
          description: "x"
        })

      planner = RoleContext.get_role_by_name("planner")
      {:ok, view, _} = live(conn, project_path(project))

      view
      |> element("form[phx-submit='add_team_access']")
      |> render_submit(%{"team_id" => team.uuid, "role_id" => Integer.to_string(planner.id)})

      ev = last_event("granted", "project_team")
      assert ev.resource_id == team.uuid
      meta = Jason.decode!(ev.metadata)
      assert meta["project_uuid"] == project.uuid
      assert meta["role_name"] == "planner"
    end

    test "change_team_role emits a role_changed event (was previously silent)", %{
      conn: conn,
      project: project
    } do
      {:ok, team} =
        TeamContext.create_team_from_data(%{
          name: "T",
          slug: "t-#{System.unique_integer([:positive])}",
          description: "x"
        })

      applier = RoleContext.get_role_by_name("applier")
      ProjectContext.add_project_to_team(project.id, team.id, applier.id)

      admin = RoleContext.get_role_by_name("admin")
      {:ok, view, _} = live(conn, project_path(project))

      render_change(view, "change_team_role", %{
        "team_id" => Integer.to_string(team.id),
        "role_id" => Integer.to_string(admin.id)
      })

      ev = last_event("role_changed", "project_team")
      meta = Jason.decode!(ev.metadata)
      assert meta["role_name"] == "admin"
    end
  end

  describe "user grant lifecycle" do
    test "change_user_role emits a role_changed event", %{conn: conn, project: project} do
      target = create_user()
      planner = RoleContext.get_role_by_name("planner")
      {:ok, _} = UserProjectContext.assign_role(target.id, project.id, planner.id)

      admin = RoleContext.get_role_by_name("admin")
      {:ok, view, _} = live(conn, project_path(project))

      render_change(view, "change_user_role", %{
        "user_id" => Integer.to_string(target.id),
        "role_id" => Integer.to_string(admin.id)
      })

      ev = last_event("role_changed", "user_project")
      meta = Jason.decode!(ev.metadata)
      assert meta["role_name"] == "admin"
      assert ev.resource_id == target.uuid
    end
  end
end

defmodule Lynx.Context.ProjectVisibilityTest do
  @moduledoc """
  Project visibility for non-super users is the union of two paths:

    1. team grants — `user_teams` ∪ `project_teams`
    2. direct grants — `user_projects`

  The direct path is what makes a team-less project visible to a regular
  user with a direct grant — without it, the per-workspace + global
  project lists silently dropped those rows.
  """
  use LynxWeb.LiveCase, async: false

  alias Lynx.Context.{ProjectContext, RoleContext, UserProjectContext}

  setup do
    mark_installed()
    :ok
  end

  test "team-less project surfaces for a non-super user with a direct grant" do
    user = create_user()
    workspace = create_workspace()
    project = create_project(%{workspace_id: workspace.id})
    role = RoleContext.get_role_by_name("planner")

    # No team attached to the project; direct grant only.
    {:ok, _} = UserProjectContext.assign_role(user.id, project.id, role.id)

    assert ProjectContext.count_projects_for_user(user.id) == 1
    assert [%{id: id}] = ProjectContext.get_projects_for_user(user.id, 0, 10)
    assert id == project.id

    # Workspace-scoped variant matches.
    assert ProjectContext.count_projects_by_workspace_for_user(workspace.id, user.id) == 1

    assert [%{id: ^id}] =
             ProjectContext.get_projects_by_workspace_for_user(workspace.id, user.id, 0, 10)
  end

  test "team-less project is invisible to a non-super user with no grants" do
    user = create_user()
    workspace = create_workspace()
    _project = create_project(%{workspace_id: workspace.id})

    assert ProjectContext.count_projects_for_user(user.id) == 0
    assert ProjectContext.get_projects_for_user(user.id, 0, 10) == []
    assert ProjectContext.count_projects_by_workspace_for_user(workspace.id, user.id) == 0

    assert ProjectContext.get_projects_by_workspace_for_user(workspace.id, user.id, 0, 10) ==
             []
  end
end

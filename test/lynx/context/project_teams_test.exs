defmodule Lynx.Context.ProjectTeamsTest do
  use LynxWeb.LiveCase, async: false

  alias Lynx.Context.{ProjectContext, RoleContext, TeamContext}

  setup do
    mark_installed()
    ws = create_workspace()
    project = create_project(%{workspace_id: ws.id})
    env_prod = create_env(project, %{name: "prod", slug: "prod"})
    env_lab = create_env(project, %{name: "lab", slug: "lab"})

    {:ok, team} =
      TeamContext.create_team_from_data(%{
        name: "T-#{System.unique_integer([:positive])}",
        slug: "t-#{System.unique_integer([:positive])}",
        description: "x"
      })

    %{project: project, env_prod: env_prod, env_lab: env_lab, team: team}
  end

  test "env-scoped grants don't repeat a project-wide team", ctx do
    admin = RoleContext.get_role_by_name("admin")
    ProjectContext.add_project_to_team(ctx.project.id, ctx.team.id)

    ProjectContext.add_project_to_team(
      ctx.project.id,
      ctx.team.id,
      admin.id,
      nil,
      ctx.env_prod.id
    )

    ProjectContext.add_project_to_team(
      ctx.project.id,
      ctx.team.id,
      admin.id,
      nil,
      ctx.env_lab.id
    )

    assert ProjectContext.get_project_team_ids(ctx.project.id) == [ctx.team.id]
    assert Enum.map(ProjectContext.get_project_teams(ctx.project.id), & &1.id) == [ctx.team.id]
  end

  test "a team with only env-scoped grants isn't a project team", ctx do
    admin = RoleContext.get_role_by_name("admin")

    ProjectContext.add_project_to_team(
      ctx.project.id,
      ctx.team.id,
      admin.id,
      nil,
      ctx.env_prod.id
    )

    assert ProjectContext.get_project_team_ids(ctx.project.id) == []
    assert ProjectContext.get_project_teams(ctx.project.id) == []
  end

  test "syncing project teams keeps env-scoped grants", ctx do
    admin = RoleContext.get_role_by_name("admin")

    ProjectContext.add_project_to_team(
      ctx.project.id,
      ctx.team.id,
      admin.id,
      nil,
      ctx.env_prod.id
    )

    ProjectContext.sync_project_teams(ctx.project.id, [ctx.team.uuid])

    assert ProjectContext.get_project_team_ids(ctx.project.id) == [ctx.team.id]
    assert [_] = ProjectContext.list_project_team_assignments(ctx.project.id, ctx.env_prod.id)
  end
end

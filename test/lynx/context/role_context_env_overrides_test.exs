defmodule Lynx.Context.RoleContextEnvOverridesTest do
  @moduledoc """
  `RoleContext.effective_permissions/3` per-env override semantics:

    1. Env-specific grants for `(user, project, env)` win when present.
    2. Otherwise fall back to project-wide grants (env_id IS NULL).
    3. Within a chosen scope, union semantics across all matching grants.
  """
  use LynxWeb.LiveCase, async: false

  alias Lynx.Context.{ProjectContext, RoleContext, TeamContext, UserContext, UserProjectContext}

  setup do
    mark_installed()
    :ok
  end

  describe "effective_permissions/3" do
    test "env-specific override wins over project-wide" do
      ws = create_workspace()
      project = create_project(%{workspace_id: ws.id})
      env_prod = create_env(project, %{name: "prod", slug: "prod"})
      user = create_user()

      admin = RoleContext.get_role_by_name("admin")
      planner = RoleContext.get_role_by_name("planner")

      # Project-wide admin grant
      {:ok, _} = UserProjectContext.assign_role(user.id, project.id, admin.id, nil, nil)
      # Per-env override: planner only on prod
      {:ok, _} = UserProjectContext.assign_role(user.id, project.id, planner.id, nil, env_prod.id)

      perms_prod = RoleContext.effective_permissions(user, project, env_prod)
      assert "state:read" in perms_prod
      # Planner doesn't have state:write, even though admin (project-wide)
      # does — the env override scope wins.
      refute "state:write" in perms_prod
      refute "snapshot:restore" in perms_prod
    end

    test "falls back to project-wide when no env override exists" do
      ws = create_workspace()
      project = create_project(%{workspace_id: ws.id})
      env_dev = create_env(project, %{name: "dev", slug: "dev"})
      user = create_user()

      applier = RoleContext.get_role_by_name("applier")

      # Only a project-wide grant — no env-specific override for dev.
      {:ok, _} = UserProjectContext.assign_role(user.id, project.id, applier.id, nil, nil)

      perms_dev = RoleContext.effective_permissions(user, project, env_dev)
      assert "state:write" in perms_dev
    end

    test "env-specific team grant overrides project-wide team grant" do
      ws = create_workspace()
      project = create_project(%{workspace_id: ws.id})
      env_prod = create_env(project, %{name: "prod", slug: "prod"})
      user = create_user()

      {:ok, team} =
        TeamContext.create_team_from_data(%{
          name: "T-#{System.unique_integer([:positive])}",
          slug: "t-#{System.unique_integer([:positive])}",
          description: "x"
        })

      {:ok, _} = UserContext.add_user_to_team(user.id, team.id)
      admin = RoleContext.get_role_by_name("admin")
      planner = RoleContext.get_role_by_name("planner")

      ProjectContext.add_project_to_team(project.id, team.id, admin.id, nil, nil)
      ProjectContext.add_project_to_team(project.id, team.id, planner.id, nil, env_prod.id)

      perms_prod = RoleContext.effective_permissions(user, project, env_prod)
      refute "snapshot:restore" in perms_prod
      assert "state:read" in perms_prod
    end

    test "no scope (legacy 2-arg) returns project-wide perms only" do
      ws = create_workspace()
      project = create_project(%{workspace_id: ws.id})
      env_prod = create_env(project, %{name: "prod", slug: "prod"})
      user = create_user()

      planner = RoleContext.get_role_by_name("planner")
      admin = RoleContext.get_role_by_name("admin")

      {:ok, _} = UserProjectContext.assign_role(user.id, project.id, planner.id, nil, nil)
      # Env override that should NOT show in 2-arg call.
      {:ok, _} = UserProjectContext.assign_role(user.id, project.id, admin.id, nil, env_prod.id)

      project_wide = RoleContext.effective_permissions(user, project)
      refute "snapshot:restore" in project_wide
      assert "state:read" in project_wide
    end

    test "super bypasses overrides too" do
      ws = create_workspace()
      project = create_project(%{workspace_id: ws.id})
      env_prod = create_env(project, %{name: "prod", slug: "prod"})
      super_user = create_super()

      assert RoleContext.effective_permissions(super_user, project, env_prod)
             |> MapSet.size() > 0
    end
  end
end

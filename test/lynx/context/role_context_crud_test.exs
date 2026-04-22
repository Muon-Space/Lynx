defmodule Lynx.Context.RoleContextCrudTest do
  @moduledoc """
  Custom-role CRUD: create / update / delete / replace_permissions, plus
  the `:system_role` and "in use" guards.
  """
  use LynxWeb.LiveCase, async: false

  alias Lynx.Context.{ProjectContext, RoleContext, UserProjectContext}

  setup do
    mark_installed()
    :ok
  end

  describe "create_role/1" do
    test "inserts a custom role + its permissions" do
      assert {:ok, role} =
               RoleContext.create_role(%{
                 name: "auditor",
                 description: "Read-only audit access",
                 permissions: ["state:read"]
               })

      refute role.is_system
      assert RoleContext.permissions_for(role.id) == MapSet.new(["state:read"])
    end

    test "rejects unknown permissions" do
      assert {:error, msg} =
               RoleContext.create_role(%{
                 name: "bad",
                 permissions: ["state:read", "made:up:perm"]
               })

      assert msg =~ "Unknown"
    end

    test "rejects duplicate name" do
      {:ok, _} = RoleContext.create_role(%{name: "dup", permissions: []})

      assert {:error, msg} = RoleContext.create_role(%{name: "dup", permissions: []})
      assert msg =~ "name"
    end
  end

  describe "update_role/2" do
    test "replaces permissions atomically" do
      {:ok, role} =
        RoleContext.create_role(%{name: "tweak", permissions: ["state:read"]})

      {:ok, _} =
        RoleContext.update_role(role, %{permissions: ["state:read", "state:write"]})

      assert RoleContext.permissions_for(role.id) ==
               MapSet.new(["state:read", "state:write"])
    end

    test "refuses to edit system roles" do
      planner = RoleContext.get_role_by_name("planner")
      assert {:error, :system_role} = RoleContext.update_role(planner, %{name: "no"})
    end
  end

  describe "delete_role/1" do
    test "deletes an unused custom role" do
      {:ok, role} = RoleContext.create_role(%{name: "deleteme", permissions: []})
      assert :ok = RoleContext.delete_role(role)
      assert RoleContext.get_role_by_id(role.id) == nil
    end

    test "refuses to delete system roles" do
      admin = RoleContext.get_role_by_name("admin")
      assert {:error, :system_role} = RoleContext.delete_role(admin)
    end

    test "refuses to delete a role that's in use" do
      {:ok, role} = RoleContext.create_role(%{name: "inuse", permissions: ["state:read"]})

      ws = create_workspace()
      project = create_project(%{workspace_id: ws.id})
      user = create_user()
      {:ok, _} = UserProjectContext.assign_role(user.id, project.id, role.id)

      assert {:error, msg} = RoleContext.delete_role(role)
      assert msg =~ "in use"
      # Role should still exist after the failed delete.
      refute RoleContext.get_role_by_id(role.id) == nil
    end
  end

  describe "count_role_usage/1" do
    test "sums project_teams + user_projects + oidc_access_rules" do
      {:ok, role} = RoleContext.create_role(%{name: "counted", permissions: []})

      ws = create_workspace()
      project = create_project(%{workspace_id: ws.id})
      user = create_user()
      {:ok, _} = UserProjectContext.assign_role(user.id, project.id, role.id)

      assert RoleContext.count_role_usage(role.id) == 1

      # Add a project-team grant too — count rises.
      {:ok, team} =
        Lynx.Context.TeamContext.create_team_from_data(%{
          name: "T",
          slug: "t-#{System.unique_integer([:positive])}",
          description: "x"
        })

      ProjectContext.add_project_to_team(project.id, team.id, role.id)

      assert RoleContext.count_role_usage(role.id) == 2
    end
  end
end

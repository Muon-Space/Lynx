defmodule Lynx.Module.RoleModuleTest do
  use Lynx.DataCase

  alias Lynx.Module.RoleModule
  alias Lynx.Module.TeamModule
  alias Lynx.Context.{ProjectContext, RoleContext, UserContext, UserProjectContext}
  alias Lynx.Service.AuthService

  defp create_user(role \\ "user") do
    salt = AuthService.get_random_salt()

    {:ok, user} =
      UserContext.new_user(%{
        email: "u-#{System.unique_integer([:positive])}@example.com",
        name: "Test",
        password_hash: AuthService.hash_password("password123", salt),
        verified: true,
        last_seen: DateTime.utc_now() |> DateTime.truncate(:second),
        role: role,
        api_key: AuthService.get_random_salt(20),
        uuid: Ecto.UUID.generate(),
        is_active: true
      })
      |> UserContext.create_user()

    user
  end

  defp create_project(_attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, project} =
      ProjectContext.new_project(%{
        name: "Project #{n}",
        slug: "p-#{n}",
        description: "test",
        workspace_id: nil
      })
      |> ProjectContext.create_project()

    project
  end

  defp create_team_with_user(user) do
    n = System.unique_integer([:positive])
    {:ok, team} = TeamModule.create_team(%{name: "T-#{n}", slug: "t-#{n}", description: "x"})
    {:ok, _} = Lynx.Context.UserContext.add_user_to_team(user.id, team.id)
    team
  end

  describe "permissions/0" do
    test "returns the canonical list of permission strings" do
      perms = RoleModule.permissions()

      for required <-
            ~w(state:read state:write state:lock state:unlock snapshot:create snapshot:restore env:manage project:manage access:manage oidc_rule:manage) do
        assert required in perms
      end
    end
  end

  describe "default_roles/0" do
    test "names planner, applier, admin" do
      assert RoleModule.default_roles() == ~w(planner applier admin)
    end
  end

  describe "can?/2 (role + permission lookup)" do
    test "planner can state:read but not state:write" do
      assert RoleModule.can?("planner", "state:read")
      refute RoleModule.can?("planner", "state:write")
      refute RoleModule.can?("planner", "state:lock")
    end

    test "applier can state operations and snapshot:create but not snapshot:restore" do
      assert RoleModule.can?("applier", "state:read")
      assert RoleModule.can?("applier", "state:write")
      assert RoleModule.can?("applier", "state:lock")
      assert RoleModule.can?("applier", "state:unlock")
      assert RoleModule.can?("applier", "snapshot:create")
      refute RoleModule.can?("applier", "snapshot:restore")
      refute RoleModule.can?("applier", "access:manage")
    end

    test "admin holds every defined permission" do
      for perm <- RoleModule.permissions() do
        assert RoleModule.can?("admin", perm), "admin missing #{perm}"
      end
    end

    test "unknown role returns false" do
      refute RoleModule.can?("nonexistent", "state:read")
    end
  end

  describe "effective_permissions/2" do
    test "super user gets every permission regardless of project" do
      user = create_user("super")
      project = create_project()
      perms = RoleModule.effective_permissions(user, project)

      assert MapSet.size(perms) == length(RoleModule.permissions())
      assert MapSet.member?(perms, "snapshot:restore")
    end

    test "user with no grants has empty permission set" do
      user = create_user()
      project = create_project()
      assert MapSet.size(RoleModule.effective_permissions(user, project)) == 0
    end

    test "team membership grants the team role's permissions" do
      user = create_user()
      project = create_project()
      team = create_team_with_user(user)
      planner = RoleContext.get_role_by_name("planner")
      ProjectContext.add_project_to_team(project.id, team.id, planner.id)

      perms = RoleModule.effective_permissions(user, project)
      assert MapSet.equal?(perms, MapSet.new(["state:read"]))
    end

    test "individual user grant unions with team grants (no override semantics)" do
      user = create_user()
      project = create_project()
      team = create_team_with_user(user)

      planner = RoleContext.get_role_by_name("planner")
      applier = RoleContext.get_role_by_name("applier")

      # Team grants planner; individual grants applier. Union should be applier's set.
      ProjectContext.add_project_to_team(project.id, team.id, planner.id)
      UserProjectContext.assign_role(user.id, project.id, applier.id)

      perms = RoleModule.effective_permissions(user, project)

      assert MapSet.member?(perms, "state:read")
      assert MapSet.member?(perms, "state:write")
      assert MapSet.member?(perms, "snapshot:create")
      refute MapSet.member?(perms, "snapshot:restore")
    end

    test "membership in two teams with different roles unions both" do
      user = create_user()
      project = create_project()
      team_a = create_team_with_user(user)
      team_b = create_team_with_user(user)

      planner = RoleContext.get_role_by_name("planner")
      admin = RoleContext.get_role_by_name("admin")

      ProjectContext.add_project_to_team(project.id, team_a.id, planner.id)
      ProjectContext.add_project_to_team(project.id, team_b.id, admin.id)

      perms = RoleModule.effective_permissions(user, project)
      # admin's set is a superset, so this should include everything
      assert MapSet.size(perms) == length(RoleModule.permissions())
    end

    test "accepts a project_id integer instead of a struct" do
      user = create_user("super")
      project = create_project()
      perms = RoleModule.effective_permissions(user, project.id)
      assert MapSet.size(perms) > 0
    end
  end

  describe "can?/3 (user + project + permission)" do
    test "wraps effective_permissions" do
      user = create_user()
      project = create_project()
      team = create_team_with_user(user)
      applier = RoleContext.get_role_by_name("applier")
      ProjectContext.add_project_to_team(project.id, team.id, applier.id)

      assert RoleModule.can?(user, project, "state:write")
      refute RoleModule.can?(user, project, "snapshot:restore")
    end
  end

  describe "permissions_for_oidc_rule/1" do
    test "returns the role's permissions" do
      planner = RoleContext.get_role_by_name("planner")

      assert MapSet.equal?(
               RoleModule.permissions_for_oidc_rule(%{role_id: planner.id}),
               MapSet.new(["state:read"])
             )
    end

    test "rule without a role_id returns empty set" do
      assert MapSet.size(RoleModule.permissions_for_oidc_rule(%{role_id: nil})) == 0
    end
  end

  describe "permissions_for_env_credentials/0" do
    test "returns the full permission set (legacy auth path preserves full access)" do
      perms = RoleModule.permissions_for_env_credentials()
      assert MapSet.size(perms) == length(RoleModule.permissions())
    end
  end

  describe "has?/2" do
    test "works with both MapSet and list inputs" do
      assert RoleModule.has?(MapSet.new(["a", "b"]), "a")
      refute RoleModule.has?(MapSet.new(["a"]), "b")
      assert RoleModule.has?(["a", "b"], "b")
      refute RoleModule.has?([], "a")
      refute RoleModule.has?("not-a-collection", "a")
    end
  end
end

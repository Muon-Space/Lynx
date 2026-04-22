defmodule Lynx.Context.RoleContextExpiryTest do
  @moduledoc """
  Time-bounded grants: `expires_at` filtering in `effective_permissions/2`
  + the periodic `Lynx.Worker.GrantExpirySweeper`.
  """
  use LynxWeb.LiveCase, async: false

  alias Lynx.Context.{ProjectContext, RoleContext, TeamContext, UserContext, UserProjectContext}
  alias Lynx.Repo
  alias Lynx.Worker.GrantExpirySweeper

  setup do
    mark_installed()
    :ok
  end

  describe "effective_permissions/2 with expires_at" do
    test "ignores an expired user_project grant" do
      ws = create_workspace()
      project = create_project(%{workspace_id: ws.id})
      user = create_user()
      admin = RoleContext.get_role_by_name("admin")

      # Grant in the past — already expired.
      past = DateTime.add(DateTime.utc_now(), -60, :second)
      {:ok, _} = UserProjectContext.assign_role(user.id, project.id, admin.id, past)

      assert RoleContext.effective_permissions(user, project) == MapSet.new()
    end

    test "honors a future-dated user_project grant" do
      ws = create_workspace()
      project = create_project(%{workspace_id: ws.id})
      user = create_user()
      planner = RoleContext.get_role_by_name("planner")

      future = DateTime.add(DateTime.utc_now(), 3600, :second)
      {:ok, _} = UserProjectContext.assign_role(user.id, project.id, planner.id, future)

      assert "state:read" in RoleContext.effective_permissions(user, project)
    end

    test "ignores expired project_team grants" do
      ws = create_workspace()
      project = create_project(%{workspace_id: ws.id})
      user = create_user()

      {:ok, team} =
        TeamContext.create_team_from_data(%{
          name: "T-#{System.unique_integer([:positive])}",
          slug: "t-#{System.unique_integer([:positive])}",
          description: "x"
        })

      {:ok, _} = UserContext.add_user_to_team(user.id, team.id)
      applier = RoleContext.get_role_by_name("applier")

      past = DateTime.add(DateTime.utc_now(), -60, :second)
      {:ok, _} = ProjectContext.add_project_to_team(project.id, team.id, applier.id, past)

      assert RoleContext.effective_permissions(user, project) == MapSet.new()
    end
  end

  describe "GrantExpirySweeper" do
    setup do
      # Run with interval=0 so no auto-tick interferes — tests call sweep_now/0.
      start_supervised!({GrantExpirySweeper, interval: 0})
      :ok
    end

    test "deletes expired user_project rows" do
      ws = create_workspace()
      project = create_project(%{workspace_id: ws.id})
      user = create_user()
      admin = RoleContext.get_role_by_name("admin")

      past = DateTime.add(DateTime.utc_now(), -60, :second)
      {:ok, _} = UserProjectContext.assign_role(user.id, project.id, admin.id, past)

      # Sandbox-allow the sweeper GenServer to use this test's DB connection.
      Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), Process.whereis(GrantExpirySweeper))

      {pt_count, up_count} = GrantExpirySweeper.sweep_now()
      assert {pt_count, up_count} == {0, 1}

      assert UserProjectContext.get_by_user_and_project(user.id, project.id) == nil
    end

    test "leaves permanent + future grants alone" do
      ws = create_workspace()
      project = create_project(%{workspace_id: ws.id})
      user_perm = create_user()
      user_future = create_user()

      planner = RoleContext.get_role_by_name("planner")

      {:ok, _} = UserProjectContext.assign_role(user_perm.id, project.id, planner.id, nil)

      future = DateTime.add(DateTime.utc_now(), 3600, :second)
      {:ok, _} = UserProjectContext.assign_role(user_future.id, project.id, planner.id, future)

      Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), Process.whereis(GrantExpirySweeper))

      assert {0, 0} == GrantExpirySweeper.sweep_now()

      refute UserProjectContext.get_by_user_and_project(user_perm.id, project.id) == nil
      refute UserProjectContext.get_by_user_and_project(user_future.id, project.id) == nil
    end
  end
end

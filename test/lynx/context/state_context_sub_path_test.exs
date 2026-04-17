defmodule Lynx.Context.StateContextSubPathTest do
  use ExUnit.Case

  alias Lynx.Context.StateContext
  alias Lynx.Context.LockContext
  alias Lynx.Context.ProjectContext
  alias Lynx.Context.TeamContext
  alias Lynx.Context.EnvironmentContext

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Lynx.Repo)

    {:ok, team} =
      TeamContext.create_team(
        TeamContext.new_team(%{name: "SubPath Team", slug: "sp-team", description: "test"})
      )

    {:ok, project} =
      ProjectContext.create_project(
        ProjectContext.new_project(%{
          name: "SubPath Project",
          slug: "sp-project",
          description: "test",
          team_id: team.id
        })
      )

    {:ok, env} =
      EnvironmentContext.create_env(
        EnvironmentContext.new_env(%{
          name: "prod",
          slug: "prod",
          username: "u",
          secret: "s",
          project_id: project.id
        })
      )

    {:ok, env: env}
  end

  describe "sub_path state storage" do
    test "states with different sub_paths are independent", %{env: env} do
      StateContext.create_state(
        StateContext.new_state(%{
          environment_id: env.id,
          name: "_tf_state_",
          value: ~s({"unit":"dns"}),
          sub_path: "dns"
        })
      )

      StateContext.create_state(
        StateContext.new_state(%{
          environment_id: env.id,
          name: "_tf_state_",
          value: ~s({"unit":"vpc"}),
          sub_path: "vpc"
        })
      )

      dns = StateContext.get_latest_state_by_environment_and_path(env.id, "dns")
      vpc = StateContext.get_latest_state_by_environment_and_path(env.id, "vpc")
      root = StateContext.get_latest_state_by_environment_and_path(env.id, "")

      assert dns.value == ~s({"unit":"dns"})
      assert vpc.value == ~s({"unit":"vpc"})
      assert root == nil
    end

    test "list_sub_paths returns all paths with counts", %{env: env} do
      for i <- 1..3 do
        StateContext.create_state(
          StateContext.new_state(%{
            environment_id: env.id,
            name: "_tf_state_",
            value: ~s({"serial":#{i}}),
            sub_path: "dns"
          })
        )
      end

      StateContext.create_state(
        StateContext.new_state(%{
          environment_id: env.id,
          name: "_tf_state_",
          value: ~s({"serial":1}),
          sub_path: "vpc"
        })
      )

      paths = StateContext.list_sub_paths(env.id)
      assert length(paths) == 2

      dns = Enum.find(paths, &(&1.sub_path == "dns"))
      vpc = Enum.find(paths, &(&1.sub_path == "vpc"))

      assert dns.count == 3
      assert vpc.count == 1
    end

    test "count_states_by_path returns correct count", %{env: env} do
      StateContext.create_state(
        StateContext.new_state(%{
          environment_id: env.id,
          name: "_tf_state_",
          value: "{}",
          sub_path: "dns"
        })
      )

      StateContext.create_state(
        StateContext.new_state(%{
          environment_id: env.id,
          name: "_tf_state_",
          value: "{}",
          sub_path: "dns"
        })
      )

      assert StateContext.count_states_by_path(env.id, "dns") == 2
      assert StateContext.count_states_by_path(env.id, "vpc") == 0
      assert StateContext.count_states_by_path(env.id, "") == 0
    end

    test "root state (empty sub_path) works", %{env: env} do
      StateContext.create_state(
        StateContext.new_state(%{
          environment_id: env.id,
          name: "_tf_state_",
          value: ~s({"root":true}),
          sub_path: ""
        })
      )

      root = StateContext.get_latest_state_by_environment_and_path(env.id, "")
      assert root.value == ~s({"root":true})

      paths = StateContext.list_sub_paths(env.id)
      assert length(paths) == 1
      assert hd(paths).sub_path == ""
    end
  end

  describe "sub_path lock isolation" do
    test "locks on different sub_paths are independent", %{env: env} do
      LockContext.create_lock(
        LockContext.new_lock(%{
          environment_id: env.id,
          operation: "apply",
          info: "",
          who: "test",
          version: "1.9",
          path: "",
          sub_path: "dns",
          is_active: true
        })
      )

      dns_lock = LockContext.get_active_lock_by_environment_and_path(env.id, "dns")
      vpc_lock = LockContext.get_active_lock_by_environment_and_path(env.id, "vpc")
      root_lock = LockContext.get_active_lock_by_environment_and_path(env.id, "")

      assert dns_lock != nil
      assert vpc_lock == nil
      assert root_lock == nil
    end

    test "unlocking one sub_path doesn't affect others", %{env: env} do
      {:ok, dns_lock} =
        LockContext.create_lock(
          LockContext.new_lock(%{
            environment_id: env.id,
            operation: "apply",
            info: "",
            who: "test",
            version: "1.9",
            path: "",
            sub_path: "dns",
            is_active: true
          })
        )

      {:ok, _vpc_lock} =
        LockContext.create_lock(
          LockContext.new_lock(%{
            environment_id: env.id,
            operation: "apply",
            info: "",
            who: "test",
            version: "1.9",
            path: "",
            sub_path: "vpc",
            is_active: true
          })
        )

      LockContext.update_lock(dns_lock, %{is_active: false})

      assert LockContext.get_active_lock_by_environment_and_path(env.id, "dns") == nil
      assert LockContext.get_active_lock_by_environment_and_path(env.id, "vpc") != nil
    end
  end

  describe "snapshot sub_path preservation" do
    test "snapshot data includes sub_path", %{env: env} do
      StateContext.create_state(
        StateContext.new_state(%{
          environment_id: env.id,
          name: "_tf_state_",
          value: ~s({"unit":"dns"}),
          sub_path: "dns"
        })
      )

      StateContext.create_state(
        StateContext.new_state(%{
          environment_id: env.id,
          name: "_tf_state_",
          value: ~s({"unit":"vpc"}),
          sub_path: "vpc"
        })
      )

      states = StateContext.get_states_by_environment_id(env.id)
      sub_paths = Enum.map(states, & &1.sub_path) |> Enum.sort()
      assert sub_paths == ["dns", "vpc"]
    end
  end

  describe "state retention trimming" do
    test "trim_old_states keeps only the latest N versions", %{env: env} do
      for i <- 1..10 do
        StateContext.create_state(
          StateContext.new_state(%{
            environment_id: env.id,
            name: "_tf_state_",
            value: ~s({"serial":#{i}}),
            sub_path: "dns"
          })
        )
      end

      assert StateContext.count_states_by_path(env.id, "dns") == 10

      deleted = StateContext.trim_old_states(env.id, "dns", 3)
      assert deleted == 7
      assert StateContext.count_states_by_path(env.id, "dns") == 3

      latest = StateContext.get_latest_state_by_environment_and_path(env.id, "dns")
      assert Jason.decode!(latest.value)["serial"] == 10
    end

    test "trim_old_states only affects the specified sub_path", %{env: env} do
      for i <- 1..5 do
        StateContext.create_state(
          StateContext.new_state(%{
            environment_id: env.id,
            name: "_tf_state_",
            value: ~s({"serial":#{i}}),
            sub_path: "dns"
          })
        )

        StateContext.create_state(
          StateContext.new_state(%{
            environment_id: env.id,
            name: "_tf_state_",
            value: ~s({"serial":#{i}}),
            sub_path: "vpc"
          })
        )
      end

      StateContext.trim_old_states(env.id, "dns", 2)

      assert StateContext.count_states_by_path(env.id, "dns") == 2
      assert StateContext.count_states_by_path(env.id, "vpc") == 5
    end
  end
end

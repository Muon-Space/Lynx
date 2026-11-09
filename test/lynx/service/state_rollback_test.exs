defmodule Lynx.Service.StateRollbackTest do
  use Lynx.DataCase, async: false

  import LynxWeb.LiveCase,
    only: [
      create_workspace: 0,
      create_project: 1,
      create_env: 1,
      create_state: 2,
      create_lock: 2,
      set_config: 2
    ]

  alias Lynx.Context.{EnvironmentContext, LockContext, PolicyContext, StateContext}
  alias Lynx.Service.PolicyEngine.Stub
  alias Lynx.Service.StateRollback

  @lineage "8d0a1c56-7b8e-4c51-9b51-5d6c1a2f3e40"

  setup do
    Stub.reset()
    workspace = create_workspace()
    project = create_project(%{workspace_id: workspace.id})
    env = create_env(project)

    v1 = create_state(env, %{value: tf_state(1, ["aws_s3_bucket.logs"])})
    v2 = create_state(env, %{value: tf_state(2, ["aws_s3_bucket.logs", "aws_iam_role.ci"])})
    v3 = create_state(env, %{value: tf_state(3, [])})

    {:ok, project: project, env: env, v1: v1, v2: v2, v3: v3}
  end

  defp tf_state(serial, addresses, lineage \\ @lineage) do
    resources =
      Enum.map(addresses, fn address ->
        [type, name] = String.split(address, ".")

        %{
          "mode" => "managed",
          "type" => type,
          "name" => name,
          "instances" => [%{"attributes" => %{"id" => address}}]
        }
      end)

    Jason.encode!(%{
      "version" => 4,
      "terraform_version" => "1.9.0",
      "serial" => serial,
      "lineage" => lineage,
      "outputs" => %{},
      "resources" => resources
    })
  end

  defp versions(env, sub_path \\ "") do
    StateContext.get_states_by_environment_id(env.id)
    |> Enum.filter(&(&1.sub_path == sub_path))
    |> Enum.sort_by(& &1.id)
  end

  defp body(state), do: Jason.decode!(state.value)

  describe "rollback/3" do
    test "appends a copy of the target with serial = current + 1", %{env: env, v2: v2, v3: v3} do
      assert {:ok, result} = StateRollback.rollback(env, v2.uuid, "alice")

      all = versions(env)
      assert length(all) == 4
      assert List.last(all).id == result.state.id

      new_body = body(result.state)
      assert new_body["serial"] == 4
      assert new_body["lineage"] == @lineage
      assert new_body["resources"] == body(v2)["resources"]
      assert result.serial == 4
      assert result.source.id == v2.id
      assert result.previous.id == v3.id
      assert result.source_version == 2
      assert result.version == 4
    end

    test "never modifies or deletes existing versions", %{env: env, v1: v1, v2: v2, v3: v3} do
      before = Enum.map([v1, v2, v3], &{&1.id, &1.value})

      {:ok, _} = StateRollback.rollback(env, v1.uuid, "alice")

      after_rows =
        versions(env)
        |> Enum.take(3)
        |> Enum.map(&{&1.id, &1.value})

      assert after_rows == before
    end

    test "keeps the current lineage when the target's lineage differs", %{env: env} do
      other = create_state(env, %{value: tf_state(9, [], "11111111-2222-3333-4444-555555555555")})
      _current = create_state(env, %{value: tf_state(10, ["aws_s3_bucket.logs"])})

      {:ok, result} = StateRollback.rollback(env, other.uuid, "alice")

      assert body(result.state)["lineage"] == @lineage
      assert body(result.state)["serial"] == 11
    end

    test "serial stays above the target's when the target serial is higher", %{env: env} do
      high = create_state(env, %{value: tf_state(50, [])})
      _current = create_state(env, %{value: tf_state(7, [])})

      {:ok, result} = StateRollback.rollback(env, high.uuid, "alice")
      assert body(result.state)["serial"] == 51
    end

    test "a rollback can itself be rolled back", %{env: env, v1: v1, v3: v3} do
      {:ok, first} = StateRollback.rollback(env, v1.uuid, "alice")
      {:ok, second} = StateRollback.rollback(env, v3.uuid, "alice")

      assert body(second.state)["resources"] == body(v3)["resources"]
      assert body(second.state)["serial"] == body(first.state)["serial"] + 1
      assert length(versions(env)) == 5
    end

    test "refuses to roll back to the current version", %{env: env, v3: v3} do
      assert {:error, :already_current} = StateRollback.rollback(env, v3.uuid, "alice")
      assert length(versions(env)) == 3
    end

    test "returns :not_found for unknown or malformed ids", %{env: env} do
      assert {:error, :not_found} = StateRollback.rollback(env, Ecto.UUID.generate(), "alice")
      assert {:error, :not_found} = StateRollback.rollback(env, "not-a-uuid", "alice")
    end

    test "returns :not_found for a version that belongs to another environment", %{
      project: project,
      env: env
    } do
      other_env = create_env(project)
      foreign = create_state(other_env, %{value: tf_state(1, [])})
      _ = create_state(other_env, %{value: tf_state(2, [])})

      assert {:error, :not_found} = StateRollback.rollback(env, foreign.uuid, "alice")
    end

    test "rolls back only the unit the version belongs to", %{env: env, v3: v3} do
      u1 = create_state(env, %{sub_path: "vpc", value: tf_state(1, ["aws_vpc.main"])})
      _u2 = create_state(env, %{sub_path: "vpc", value: tf_state(2, [])})

      {:ok, result} = StateRollback.rollback(env, u1.uuid, "alice")

      assert result.state.sub_path == "vpc"
      assert length(versions(env, "vpc")) == 3
      assert body(List.last(versions(env, "vpc")))["resources"] == body(u1)["resources"]
      # root untouched
      assert List.last(versions(env)).id == v3.id
    end

    test "rejects a target whose body is not a JSON object", %{env: env} do
      bad = create_state(env, %{value: "not json"})
      _ = create_state(env, %{value: tf_state(20, [])})

      assert {:error, {:invalid_state, msg}} = StateRollback.rollback(env, bad.uuid, "alice")
      assert msg =~ "target version"
    end
  end

  describe "locks" do
    test "refuses while the unit holds an exclusive lock", %{env: env, v1: v1} do
      lock = create_lock(env, %{operation: "OperationTypeApply", who: "ci@runner"})

      assert {:error, {:locked, held}} = StateRollback.rollback(env, v1.uuid, "alice")
      assert held.id == lock.id
      assert length(versions(env)) == 3
      assert StateRollback.lock_message(held) =~ "ci@runner"
    end

    test "an env-wide lock blocks a unit rollback", %{env: env} do
      u1 = create_state(env, %{sub_path: "vpc", value: tf_state(1, [])})
      _ = create_state(env, %{sub_path: "vpc", value: tf_state(2, [])})
      _lock = create_lock(env, %{sub_path: ""})

      assert {:error, {:locked, _}} = StateRollback.rollback(env, u1.uuid, "alice")
    end

    test "another unit's lock does not block", %{env: env, v1: v1} do
      _lock = create_lock(env, %{sub_path: "dns"})
      assert {:ok, _} = StateRollback.rollback(env, v1.uuid, "alice")
    end

    test "in-flight plans (shared locks) do not block", %{env: env, v1: v1} do
      _shared = create_lock(env, %{operation: "OperationTypePlan", mode: "shared"})
      assert {:ok, _} = StateRollback.rollback(env, v1.uuid, "alice")
    end

    test "releases its own write lock afterwards", %{env: env, v1: v1} do
      {:ok, _} = StateRollback.rollback(env, v1.uuid, "alice")

      assert LockContext.blocking_lock(env.id, "") == nil
      assert LockContext.is_environment_locked(env.id) == false
    end
  end

  describe "retention" do
    test "the rollback write is trimmed like any other write", %{env: env, v1: v1, v2: v2} do
      set_config("state_retention_count", "3")

      {:ok, result} = StateRollback.rollback(env, v2.uuid, "alice")

      remaining = versions(env)
      assert length(remaining) == 3
      refute Enum.any?(remaining, &(&1.id == v1.id))
      assert List.last(remaining).id == result.state.id
      assert result.version == 3
    end
  end

  describe "policies" do
    setup %{env: env, project: project} do
      {:ok, policy} =
        PolicyContext.create_policy(
          PolicyContext.new_policy(%{
            name: "no-iam-roles",
            project_id: project.id,
            rego_source: "package x"
          })
        )

      Stub.register(policy.uuid, fn input ->
        for change <- Map.get(input, "resource_changes", []),
            change["type"] == "aws_iam_role" do
          "#{change["address"]} is not allowed"
        end
      end)

      {:ok, env: env, policy: policy}
    end

    test "blocks a rollback into a violating state when block_violating_apply is on", %{
      env: env,
      v2: v2,
      policy: policy
    } do
      {:ok, env} = EnvironmentContext.update_env(env, %{block_violating_apply: true})

      assert {:error, {:policy_violation, msg, policies}} =
               StateRollback.rollback(env, v2.uuid, "alice")

      assert msg =~ "aws_iam_role.ci is not allowed"
      assert [%{"uuid" => uuid}] = policies
      assert uuid == policy.uuid
      assert length(versions(env)) == 3
    end

    test "allows a compliant target with the gate on", %{env: env, v1: v1} do
      {:ok, env} = EnvironmentContext.update_env(env, %{block_violating_apply: true})
      assert {:ok, _} = StateRollback.rollback(env, v1.uuid, "alice")
    end

    test "does not evaluate when the gate is off", %{env: env, v2: v2} do
      assert {:ok, _} = StateRollback.rollback(env, v2.uuid, "alice")
    end
  end

  describe "audit_metadata/1" do
    test "records source, previous and new versions", %{env: env, v1: v1, v3: v3} do
      {:ok, result} = StateRollback.rollback(env, v1.uuid, "alice")
      meta = StateRollback.audit_metadata(result)

      assert meta["from_state_uuid"] == v1.uuid
      assert meta["from_version"] == 1
      assert meta["previous_state_uuid"] == v3.uuid
      assert meta["new_state_uuid"] == result.state.uuid
      assert meta["new_version"] == 4
      assert meta["serial"] == 4
      assert meta["sub_path"] == ""
    end
  end
end

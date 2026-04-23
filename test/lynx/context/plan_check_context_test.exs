defmodule Lynx.Context.PlanCheckContextTest do
  @moduledoc """
  PlanCheck CRUD + apply-gate semantics. The single-use `consume/1` is the
  most load-bearing piece — two concurrent applies must NOT both spend
  the same passing check.
  """
  use LynxWeb.LiveCase, async: false

  alias Lynx.Context.PlanCheckContext

  setup do
    mark_installed()
    ws = create_workspace()
    project = create_project(%{workspace_id: ws.id})
    env = create_env(project)

    {:ok, env: env}
  end

  describe "latest_unconsumed_passing/3" do
    test "ignores failed and errored outcomes", %{env: env} do
      insert(env, %{outcome: "failed", actor_signature: "user:a"})
      insert(env, %{outcome: "errored", actor_signature: "user:a"})

      assert PlanCheckContext.latest_unconsumed_passing(env.id, "", "user:a") == nil
    end

    test "ignores already-consumed rows", %{env: env} do
      insert(env, %{
        outcome: "passed",
        actor_signature: "user:a",
        consumed_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

      assert PlanCheckContext.latest_unconsumed_passing(env.id, "", "user:a") == nil
    end

    test "returns the latest matching row", %{env: env} do
      insert(env, %{outcome: "passed", actor_signature: "user:a", plan_json: "{\"v\":1}"})

      newest =
        insert(env, %{outcome: "passed", actor_signature: "user:a", plan_json: "{\"v\":2}"})

      hit = PlanCheckContext.latest_unconsumed_passing(env.id, "", "user:a")
      assert hit.id == newest.id
    end

    test "scopes to (env, sub_path, actor_signature)", %{env: env} do
      insert(env, %{outcome: "passed", sub_path: "dns", actor_signature: "user:a"})
      insert(env, %{outcome: "passed", sub_path: "", actor_signature: "user:b"})

      assert PlanCheckContext.latest_unconsumed_passing(env.id, "vpc", "user:a") == nil
      assert PlanCheckContext.latest_unconsumed_passing(env.id, "dns", "user:b") == nil
      assert PlanCheckContext.latest_unconsumed_passing(env.id, "dns", "user:a") != nil
    end
  end

  describe "consume/1" do
    test "marks consumed and returns {:ok, _}", %{env: env} do
      check = insert(env, %{outcome: "passed", actor_signature: "user:a"})
      assert {:ok, consumed} = PlanCheckContext.consume(check)
      assert consumed.consumed_at != nil
    end

    test "second consume of the same row returns :already_consumed", %{env: env} do
      check = insert(env, %{outcome: "passed", actor_signature: "user:a"})
      {:ok, _} = PlanCheckContext.consume(check)
      assert :already_consumed = PlanCheckContext.consume(check)
    end
  end

  defp insert(env, overrides) do
    attrs =
      PlanCheckContext.new_plan_check(
        Map.merge(
          %{
            environment_id: env.id,
            sub_path: "",
            outcome: "passed",
            violations: "[]",
            plan_json: "{}",
            actor_signature: "user:a",
            actor_name: "tester",
            actor_type: "user"
          },
          overrides
        )
      )

    {:ok, record} = PlanCheckContext.create_plan_check(attrs)
    record
  end
end

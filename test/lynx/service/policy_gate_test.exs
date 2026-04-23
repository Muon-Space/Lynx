defmodule Lynx.Service.PolicyGateTest do
  @moduledoc """
  Resolves the two policy-gate toggles (`require_passing_plan` +
  `block_violating_apply`) into effective values for an env, with
  override → global-default fallback. Also synthesizes a plan-shaped
  OPA input from a Terraform JSON state body so the same policies that
  evaluate uploaded plans can also evaluate the to-be-applied state.
  """
  use LynxWeb.LiveCase, async: false

  alias Lynx.Service.PolicyGate

  setup do
    mark_installed()
    ws = create_workspace()
    project = create_project(%{workspace_id: ws.id})
    env = create_env(project)

    on_exit(fn ->
      # Reset the global defaults so a stuck row doesn't leak across tests.
      PolicyGate.set_global_default(:require_passing_plan, false)
      PolicyGate.set_global_default(:block_violating_apply, false)
    end)

    {:ok, env: env}
  end

  describe "global defaults" do
    test "round-trip via set_global_default + global_default" do
      PolicyGate.set_global_default(:require_passing_plan, true)
      assert PolicyGate.global_default(:require_passing_plan) == true

      PolicyGate.set_global_default(:require_passing_plan, false)
      assert PolicyGate.global_default(:require_passing_plan) == false
    end

    test "unset key defaults to false" do
      assert PolicyGate.global_default(:block_violating_apply) == false
    end
  end

  describe "effective/1 — resolve env override → global default" do
    test "explicit override on the env wins (true)", %{env: env} do
      PolicyGate.set_global_default(:require_passing_plan, false)
      env = %{env | require_passing_plan: true}
      eff = PolicyGate.effective(env)
      assert eff.require_passing_plan.value == true
      assert eff.require_passing_plan.source == :explicit
    end

    test "explicit override on the env wins (false)", %{env: env} do
      PolicyGate.set_global_default(:require_passing_plan, true)
      env = %{env | require_passing_plan: false}
      eff = PolicyGate.effective(env)
      assert eff.require_passing_plan.value == false
      assert eff.require_passing_plan.source == :explicit
    end

    test "nil override falls back to the global default", %{env: env} do
      PolicyGate.set_global_default(:require_passing_plan, true)
      env = %{env | require_passing_plan: nil}
      eff = PolicyGate.effective(env)
      assert eff.require_passing_plan.value == true
      assert eff.require_passing_plan.source == :inherited
    end

    test "the two toggles resolve independently", %{env: env} do
      PolicyGate.set_global_default(:require_passing_plan, false)
      PolicyGate.set_global_default(:block_violating_apply, true)
      env = %{env | require_passing_plan: nil, block_violating_apply: nil}
      eff = PolicyGate.effective(env)
      assert eff.require_passing_plan.value == false
      assert eff.block_violating_apply.value == true
    end

    test "convenience predicates match the resolved value", %{env: env} do
      PolicyGate.set_global_default(:block_violating_apply, true)
      env = %{env | block_violating_apply: nil}
      assert PolicyGate.block_violating_apply?(env) == true

      PolicyGate.set_global_default(:block_violating_apply, false)
      env = %{env | block_violating_apply: false}
      assert PolicyGate.block_violating_apply?(env) == false
    end
  end

  describe "state_to_plan_input/1 — synthesize OPA input from a state body" do
    test "happy path: each instance becomes a resource_changes entry tagged update" do
      state = ~s({
        "version": 4,
        "terraform_version": "1.8.0",
        "resources": [
          {
            "mode": "managed",
            "type": "aws_s3_bucket",
            "name": "foo",
            "instances": [
              {"attributes": {"bucket": "foo", "acl": "public-read"}}
            ]
          }
        ]
      })

      input = PolicyGate.state_to_plan_input(state)

      assert input["format_version"] == "1.2"
      assert input["terraform_version"] == "1.8.0"
      assert input["_lynx_synthetic"] == true

      assert [change] = input["resource_changes"]
      assert change["address"] == "aws_s3_bucket.foo"
      assert change["mode"] == "managed"
      assert change["type"] == "aws_s3_bucket"
      assert change["name"] == "foo"
      # All synthesized changes are "update" since we only have the after-state.
      assert change["change"]["actions"] == ["update"]
      assert change["change"]["before"] == nil
      assert change["change"]["after"] == %{"bucket" => "foo", "acl" => "public-read"}
    end

    test "indexed instance addresses include the index_key" do
      state = ~s({
        "resources": [
          {
            "mode": "managed",
            "type": "aws_instance",
            "name": "web",
            "instances": [
              {"index_key": 0, "attributes": {}},
              {"index_key": "primary", "attributes": {}}
            ]
          }
        ]
      })

      [a, b] = PolicyGate.state_to_plan_input(state)["resource_changes"]
      assert a["address"] == "aws_instance.web[0]"
      assert b["address"] == ~s(aws_instance.web["primary"])
    end

    test "empty state body yields no resource_changes — policies see nothing to fault" do
      assert %{"resource_changes" => []} = PolicyGate.state_to_plan_input(~s({}))
    end

    test "malformed JSON yields no resource_changes (no crash)" do
      assert %{"resource_changes" => []} = PolicyGate.state_to_plan_input("not json {")
    end

    test "missing terraform_version falls back to 'unknown'" do
      input = PolicyGate.state_to_plan_input(~s({"resources":[]}))
      assert input["terraform_version"] == "unknown"
    end
  end
end

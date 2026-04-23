defmodule Lynx.Context.PolicyContextTest do
  @moduledoc """
  CRUD + lookup for OPA policies (issue #38). The interesting behaviors:

    * `at_most_one_scope` — a policy is global / workspace / project / env
      (zero or one of the FK columns set, never two).
    * `list_effective_policies_for_env/1` unions ALL FOUR scopes for a
      given env (global ∪ workspace ∪ project ∪ env), enabled-only.
    * `get_link_targets_by_uuids/1` builds detail-page URLs in batched
      lookups so the env-page chip rendering doesn't N+1.
    * `recent_blocks_for_policy/2` blends plan_check + apply_blocked
      audit_event sources; backs the per-policy detail page.

  Engine is the in-memory `Stub` (set in `config/test.exs`) so any save
  paths that run rego validation just see "package present → :ok".
  """
  use LynxWeb.LiveCase, async: false

  alias Lynx.Context.{AuditContext, PlanCheckContext, PolicyContext}

  setup do
    mark_installed()
    ws = create_workspace()
    project = create_project(%{workspace_id: ws.id})
    env = create_env(project)

    {:ok, ws: ws, project: project, env: env}
  end

  describe "create_policy/1 — scope validation" do
    test "global is allowed (no scope columns set)" do
      attrs = PolicyContext.new_policy(%{name: "g", rego_source: "package g"})

      assert {:ok, %{name: "g", workspace_id: nil, project_id: nil, environment_id: nil}} =
               PolicyContext.create_policy(attrs)
    end

    test "workspace-scoped is allowed", %{ws: ws} do
      attrs =
        PolicyContext.new_policy(%{
          name: "w",
          rego_source: "package w",
          workspace_id: ws.id
        })

      assert {:ok, %{workspace_id: id}} = PolicyContext.create_policy(attrs)
      assert id == ws.id
    end

    test "project-scoped is allowed", %{project: project} do
      attrs =
        PolicyContext.new_policy(%{
          name: "p",
          rego_source: "package p",
          project_id: project.id
        })

      assert {:ok, %{project_id: id}} = PolicyContext.create_policy(attrs)
      assert id == project.id
    end

    test "env-scoped is allowed", %{env: env} do
      attrs =
        PolicyContext.new_policy(%{
          name: "e",
          rego_source: "package e",
          environment_id: env.id
        })

      assert {:ok, %{environment_id: id}} = PolicyContext.create_policy(attrs)
      assert id == env.id
    end

    test "rejects when more than one scope is set", %{project: project, env: env} do
      attrs =
        PolicyContext.new_policy(%{
          name: "x",
          rego_source: "package x",
          project_id: project.id,
          environment_id: env.id
        })

      assert {:error, changeset} = PolicyContext.create_policy(attrs)

      assert {"at most one of workspace_id / project_id / environment_id can be set", _} =
               changeset.errors[:environment_id]
    end
  end

  describe "list_effective_policies_for_env/1 — 4-way union" do
    setup %{ws: ws, project: project, env: env} do
      {:ok, _} =
        PolicyContext.create_policy(
          PolicyContext.new_policy(%{name: "global-pol", rego_source: "package g"})
        )

      {:ok, _} =
        PolicyContext.create_policy(
          PolicyContext.new_policy(%{
            name: "workspace-pol",
            rego_source: "package w",
            workspace_id: ws.id
          })
        )

      {:ok, _} =
        PolicyContext.create_policy(
          PolicyContext.new_policy(%{
            name: "project-pol",
            rego_source: "package p",
            project_id: project.id
          })
        )

      {:ok, _} =
        PolicyContext.create_policy(
          PolicyContext.new_policy(%{
            name: "env-pol",
            rego_source: "package e",
            environment_id: env.id
          })
        )

      :ok
    end

    test "unions global + workspace + project + env (alphabetical)", %{env: env} do
      names = PolicyContext.list_effective_policies_for_env(env.id) |> Enum.map(& &1.name)
      assert names == ["env-pol", "global-pol", "project-pol", "workspace-pol"]
    end

    test "skips disabled policies at every scope", %{ws: ws, env: env} do
      # Disable the workspace one specifically.
      ws_pol =
        PolicyContext.list_policies_by_workspace(ws.id)
        |> Enum.find(&(&1.name == "workspace-pol"))

      {:ok, _} = PolicyContext.update_policy(ws_pol, %{enabled: false})

      names = PolicyContext.list_effective_policies_for_env(env.id) |> Enum.map(& &1.name)
      refute "workspace-pol" in names
      assert "global-pol" in names
    end

    test "different env in different workspace doesn't see this workspace's scoped policies",
         %{} do
      other_ws = create_workspace()
      other_project = create_project(%{workspace_id: other_ws.id})
      other_env = create_env(other_project)

      names = PolicyContext.list_effective_policies_for_env(other_env.id) |> Enum.map(& &1.name)
      # Sees global only — not the original workspace's, project's, or env's.
      assert names == ["global-pol"]
    end
  end

  describe "list_policies_by_* helpers" do
    test "list_policies_global returns only global policies", %{project: project} do
      {:ok, _} =
        PolicyContext.create_policy(
          PolicyContext.new_policy(%{name: "g1", rego_source: "package g"})
        )

      {:ok, _} =
        PolicyContext.create_policy(
          PolicyContext.new_policy(%{
            name: "p1",
            rego_source: "package p",
            project_id: project.id
          })
        )

      names = PolicyContext.list_policies_global() |> Enum.map(& &1.name)
      assert names == ["g1"]
    end

    test "list_policies_by_workspace scopes correctly", %{ws: ws} do
      other_ws = create_workspace()

      {:ok, _} =
        PolicyContext.create_policy(
          PolicyContext.new_policy(%{name: "mine", rego_source: "package m", workspace_id: ws.id})
        )

      {:ok, _} =
        PolicyContext.create_policy(
          PolicyContext.new_policy(%{
            name: "other",
            rego_source: "package o",
            workspace_id: other_ws.id
          })
        )

      assert [%{name: "mine"}] = PolicyContext.list_policies_by_workspace(ws.id)
    end
  end

  describe "get_link_targets_by_uuids/1" do
    test "returns one URL per scope, all pointing at the per-policy detail page",
         %{ws: ws, project: project, env: env} do
      {:ok, g} =
        PolicyContext.create_policy(
          PolicyContext.new_policy(%{name: "g", rego_source: "package g"})
        )

      {:ok, w} =
        PolicyContext.create_policy(
          PolicyContext.new_policy(%{name: "w", rego_source: "package w", workspace_id: ws.id})
        )

      {:ok, p} =
        PolicyContext.create_policy(
          PolicyContext.new_policy(%{name: "p", rego_source: "package p", project_id: project.id})
        )

      {:ok, e} =
        PolicyContext.create_policy(
          PolicyContext.new_policy(%{name: "e", rego_source: "package e", environment_id: env.id})
        )

      links =
        PolicyContext.get_link_targets_by_uuids([g.uuid, w.uuid, p.uuid, e.uuid])

      assert links[g.uuid] == "/admin/policies/#{g.uuid}"
      assert links[w.uuid] == "/admin/policies/#{w.uuid}"
      assert links[p.uuid] == "/admin/policies/#{p.uuid}"
      assert links[e.uuid] == "/admin/policies/#{e.uuid}"
    end

    test "empty list short-circuits to empty map" do
      assert PolicyContext.get_link_targets_by_uuids([]) == %{}
    end

    test "deleted / unknown UUIDs are silently dropped" do
      assert PolicyContext.get_link_targets_by_uuids([Ecto.UUID.generate()]) == %{}
    end
  end

  describe "recent_blocks_for_policy/2" do
    test "returns plan_check rows that include this policy uuid in violations",
         %{project: project, env: env} do
      {:ok, policy} =
        PolicyContext.create_policy(
          PolicyContext.new_policy(%{
            name: "no-buckets",
            rego_source: "package x",
            project_id: project.id
          })
        )

      # Two checks: one mentions our policy, one doesn't.
      violations_with =
        Jason.encode!([
          %{"policyId" => policy.uuid, "policyName" => "no-buckets", "messages" => ["bad bucket"]}
        ])

      {:ok, _hit} =
        PlanCheckContext.create_plan_check(%{
          uuid: Ecto.UUID.generate(),
          environment_id: env.id,
          sub_path: "",
          outcome: "failed",
          violations: violations_with,
          plan_json: "{}",
          actor_signature: "user:a",
          actor_name: "alice",
          actor_type: "user"
        })

      {:ok, _miss} =
        PlanCheckContext.create_plan_check(%{
          uuid: Ecto.UUID.generate(),
          environment_id: env.id,
          sub_path: "",
          outcome: "failed",
          violations: "[]",
          plan_json: "{}",
          actor_signature: "user:a",
          actor_name: "alice",
          actor_type: "user"
        })

      [block] = PolicyContext.recent_blocks_for_policy(policy)
      assert block.kind == "plan_check"
      assert block.env.id == env.id
      assert block.actor_name == "alice"
    end

    test "returns apply_blocked audit_events that mention this policy uuid",
         %{project: project, env: env} do
      {:ok, policy} =
        PolicyContext.create_policy(
          PolicyContext.new_policy(%{
            name: "x",
            rego_source: "package x",
            project_id: project.id
          })
        )

      AuditContext.create_event(%{
        actor_id: nil,
        actor_name: "tf-user",
        actor_type: "env_secret",
        action: "apply_blocked",
        resource_type: "environment",
        resource_id: env.uuid,
        resource_name: env.name,
        metadata:
          Jason.encode!(%{
            "gate" => "policy_violation",
            "sub_path" => "",
            "reason" => "x: bad",
            "policies" => [%{"name" => "x", "uuid" => policy.uuid}]
          })
      })

      [block] = PolicyContext.recent_blocks_for_policy(policy)
      assert block.kind == "apply_blocked"
      assert block.env.id == env.id
      assert block.actor_name == "tf-user"
    end

    test "does not match plan_checks whose outcome is 'passed'", %{project: project, env: env} do
      {:ok, policy} =
        PolicyContext.create_policy(
          PolicyContext.new_policy(%{
            name: "x",
            rego_source: "package x",
            project_id: project.id
          })
        )

      # A passing check that happens to mention the uuid in its (empty)
      # violations field — the outcome filter must drop it.
      {:ok, _} =
        PlanCheckContext.create_plan_check(%{
          uuid: Ecto.UUID.generate(),
          environment_id: env.id,
          sub_path: "",
          outcome: "passed",
          violations: "[]",
          plan_json: ~s({"_": "#{policy.uuid}"}),
          actor_signature: "user:a",
          actor_name: "alice",
          actor_type: "user"
        })

      assert PolicyContext.recent_blocks_for_policy(policy) == []
    end
  end

  describe "list_enabled_policies/0 + latest_enabled_update_at/0" do
    test "ETag changes when a policy is updated", %{project: project} do
      {:ok, policy} =
        PolicyContext.create_policy(
          PolicyContext.new_policy(%{
            name: "etag-test",
            rego_source: "package x",
            project_id: project.id
          })
        )

      first = PolicyContext.latest_enabled_update_at()
      assert first != nil

      # NaiveDateTime resolution is 1s — set updated_at explicitly to
      # avoid a flaky sleep.
      bumped =
        policy
        |> Ecto.Changeset.change(%{
          name: "etag-test-2",
          updated_at: NaiveDateTime.add(policy.updated_at, 5, :second)
        })
        |> Lynx.Repo.update!()

      second = PolicyContext.latest_enabled_update_at()
      assert NaiveDateTime.compare(second, bumped.updated_at) == :eq
      assert NaiveDateTime.compare(second, first) == :gt
    end
  end
end

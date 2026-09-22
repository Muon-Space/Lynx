defmodule Lynx.Context.LockContextRwTest do
  @moduledoc """
  Context-level readers-writer lock behaviour: mode derivation, the
  exclusive-only unique index, the lost-race path in `lock_action/1`, and
  the force-unlock cascades over shared rows.
  """
  use LynxWeb.LiveCase, async: false

  alias Lynx.Context.LockContext

  setup do
    mark_installed()
    :ok
  end

  defp tf_params(workspace, project, env, attrs) do
    Map.merge(
      %{
        w_slug: workspace.slug,
        p_slug: project.slug,
        e_slug: env.slug,
        sub_path: "",
        uuid: Ecto.UUID.generate(),
        operation: "OperationTypeApply",
        info: "",
        who: "tester",
        version: "1.9",
        path: ""
      },
      attrs
    )
  end

  describe "mode_for_operation/1" do
    test "only the plan operation is shared" do
      assert LockContext.mode_for_operation("OperationTypePlan") == "shared"
      assert LockContext.mode_for_operation("OperationTypeApply") == "exclusive"
      assert LockContext.mode_for_operation("OperationTypeRefresh") == "exclusive"
      assert LockContext.mode_for_operation("manual") == "exclusive"
      assert LockContext.mode_for_operation("") == "exclusive"
      assert LockContext.mode_for_operation(nil) == "exclusive"
    end

    test "new_lock/1 derives the mode from the operation unless given" do
      base = %{environment_id: 1, info: "", who: "", version: "", path: "", is_active: true}

      assert LockContext.new_lock(Map.put(base, :operation, "OperationTypePlan")).mode ==
               "shared"

      assert LockContext.new_lock(Map.put(base, :operation, "manual")).mode == "exclusive"

      assert LockContext.new_lock(
               base
               |> Map.put(:operation, "OperationTypePlan")
               |> Map.put(:mode, "exclusive")
             ).mode == "exclusive"
    end

    test "changeset rejects an unknown mode" do
      project = create_project()
      env = create_env(project)

      assert {:error, changeset} =
               LockContext.create_lock(%{
                 uuid: Ecto.UUID.generate(),
                 environment_id: env.id,
                 mode: "upgradable",
                 is_active: true
               })

      assert {"is invalid", _} = changeset.errors[:mode]
    end
  end

  describe "database invariants" do
    test "duplicate active shared locks are allowed on one path" do
      project = create_project()
      env = create_env(project)

      create_lock(env, %{sub_path: "dns", operation: "OperationTypePlan"})
      create_lock(env, %{sub_path: "dns", operation: "OperationTypePlan"})
      create_lock(env, %{sub_path: "dns", operation: "OperationTypePlan"})

      assert length(LockContext.list_active_shared_locks(env.id, "dns")) == 3
      assert LockContext.get_active_exclusive_lock(env.id, "dns") == nil
    end

    test "a second active exclusive lock on one path is rejected" do
      project = create_project()
      env = create_env(project)

      create_lock(env, %{sub_path: "dns"})

      assert {:error, changeset} =
               LockContext.create_lock(
                 LockContext.new_lock(%{
                   environment_id: env.id,
                   operation: "OperationTypeApply",
                   info: "",
                   who: "",
                   version: "",
                   path: "",
                   sub_path: "dns",
                   is_active: true
                 })
               )

      assert changeset.errors[:environment_id]
    end

    test "an exclusive lock can be taken alongside active shared locks" do
      project = create_project()
      env = create_env(project)

      create_lock(env, %{sub_path: "dns", operation: "OperationTypePlan"})
      assert %{mode: "exclusive"} = create_lock(env, %{sub_path: "dns"})
    end
  end

  describe "lock_action/1" do
    test "losing the race to an exclusive holder returns that lock, not an error" do
      workspace = create_workspace()
      project = create_project(%{workspace_id: workspace.id})
      env = create_env(project)

      # Simulate the other writer inserting between the caller's is_locked
      # check and its insert.
      existing = create_lock(env, %{sub_path: "dns"})

      assert {:locked, %{uuid: uuid}} =
               LockContext.lock_action(tf_params(workspace, project, env, %{sub_path: "dns"}))

      assert uuid == existing.uuid
    end

    test "a plan records a shared lock" do
      workspace = create_workspace()
      project = create_project(%{workspace_id: workspace.id})
      env = create_env(project)

      assert {:success, _} =
               LockContext.lock_action(
                 tf_params(workspace, project, env, %{
                   sub_path: "dns",
                   operation: "OperationTypePlan"
                 })
               )

      assert [%{mode: "shared"}] = LockContext.list_active_shared_locks(env.id, "dns")
    end
  end

  describe "is_locked/1 and is_environment_locked/1" do
    test "shared locks never count as locked" do
      workspace = create_workspace()
      project = create_project(%{workspace_id: workspace.id})
      env = create_env(project)

      create_lock(env, %{sub_path: "", operation: "OperationTypePlan"})
      create_lock(env, %{sub_path: "dns", operation: "OperationTypePlan"})

      refute LockContext.is_environment_locked(env.id)

      assert {:success, _} =
               LockContext.is_locked(tf_params(workspace, project, env, %{sub_path: "dns"}))

      assert {:success, _} = LockContext.is_locked(tf_params(workspace, project, env, %{}))
    end

    test "an env-wide exclusive lock blocks every unit" do
      workspace = create_workspace()
      project = create_project(%{workspace_id: workspace.id})
      env = create_env(project)

      create_lock(env, %{sub_path: ""})

      assert {:locked, _} =
               LockContext.is_locked(tf_params(workspace, project, env, %{sub_path: "dns"}))

      assert LockContext.is_environment_locked(env.id)
    end
  end

  describe "force_lock/2" do
    test "is not refused by in-flight plans" do
      project = create_project()
      env = create_env(project)

      create_lock(env, %{sub_path: "dns", operation: "OperationTypePlan"})

      assert {:success, _} = LockContext.force_lock(env.id, "admin")
      assert LockContext.is_environment_locked(env.id)
    end

    test "is refused by a unit's exclusive lock" do
      project = create_project()
      env = create_env(project)

      create_lock(env, %{sub_path: "dns"})

      assert {:already_locked, _} = LockContext.force_lock(env.id, "admin")
    end
  end

  describe "force unlock cascades" do
    test "force_unlock/1 clears shared rows too" do
      project = create_project()
      env = create_env(project)

      create_lock(env, %{sub_path: ""})
      create_lock(env, %{sub_path: "dns", operation: "OperationTypePlan"})
      create_lock(env, %{sub_path: "dns", operation: "OperationTypePlan"})

      assert {:success, msg} = LockContext.force_unlock(env.id)
      assert msg =~ "3 locks cleared"
      assert LockContext.count_active_shared_locks(env.id) == 0
    end

    test "force_unlock_unit/2 clears both modes on one path only" do
      project = create_project()
      env = create_env(project)

      create_lock(env, %{sub_path: "dns"})
      create_lock(env, %{sub_path: "dns", operation: "OperationTypePlan"})
      create_lock(env, %{sub_path: "vpc", operation: "OperationTypePlan"})

      assert {:success, 2} = LockContext.force_unlock_unit(env.id, "dns")
      assert LockContext.get_active_exclusive_lock(env.id, "dns") == nil
      assert LockContext.list_active_shared_locks(env.id, "dns") == []
      assert length(LockContext.list_active_shared_locks(env.id, "vpc")) == 1
    end
  end
end

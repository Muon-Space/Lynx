defmodule LynxWeb.TfControllerRwLockTest do
  @moduledoc """
  Readers-writer semantics on `/tf/.../lock` and `/tf/.../unlock`.

  `terraform plan` (Operation `OperationTypePlan`) takes a shared lock: any
  number can coexist on one path. Every other operation takes an exclusive
  lock. A shared lock is refused while an exclusive lock is active; an
  exclusive lock is refused only by another exclusive lock and never waits
  for in-flight plans.
  """
  use LynxWeb.ConnCase

  alias Lynx.Context.AuditContext
  alias Lynx.Context.EnvironmentContext
  alias Lynx.Context.LockContext
  alias Lynx.Context.ProjectContext
  alias Lynx.Context.TeamContext
  alias Lynx.Context.WorkspaceContext

  @base "/tf/aws-govcloud/platform/production"

  setup %{conn: conn} do
    post(conn, "/action/install", %{
      app_name: "Lynx",
      app_url: "https://lynx.com",
      app_email: "hello@lynx.com",
      admin_name: "Admin",
      admin_email: "admin@example.com",
      admin_password: "password123"
    })

    {:ok, workspace} =
      WorkspaceContext.create_workspace(
        WorkspaceContext.new_workspace(%{
          name: "AWS GovCloud",
          slug: "aws-govcloud",
          description: "GovCloud infra"
        })
      )

    {:ok, team} =
      TeamContext.create_team(
        TeamContext.new_team(%{name: "Infra", slug: "infra", description: "Infra team"})
      )

    {:ok, project} =
      ProjectContext.create_project(
        ProjectContext.new_project(%{
          name: "Platform",
          slug: "platform",
          description: "Platform project",
          team_id: team.id,
          workspace_id: workspace.id
        })
      )

    {:ok, env} =
      EnvironmentContext.create_env(
        EnvironmentContext.new_env(%{
          name: "Production",
          slug: "production",
          username: "tf-user",
          secret: "tf-secret",
          project_id: project.id
        })
      )

    {:ok, conn: conn, env: env}
  end

  defp tf_conn(env) do
    encoded = Base.encode64("#{env.username}:#{env.secret}")

    build_conn()
    |> put_req_header("authorization", "Basic #{encoded}")
    |> put_req_header("content-type", "application/json")
  end

  # Mirrors the body terraform's http backend sends: `statemgr.LockInfo`.
  defp lock_info(operation, id \\ Ecto.UUID.generate()) do
    %{
      "ID" => id,
      "Operation" => operation,
      "Info" => "",
      "Who" => "ci@runner",
      "Version" => "1.9.0",
      "Path" => ""
    }
  end

  defp lock(env, unit, body), do: tf_conn(env) |> post("#{@base}#{unit}/lock", body)
  defp unlock(env, unit, body), do: tf_conn(env) |> post("#{@base}#{unit}/unlock", body)

  defp plan(env, unit \\ ""), do: lock(env, unit, lock_info("OperationTypePlan"))
  defp tf_apply(env, unit), do: lock(env, unit, lock_info("OperationTypeApply"))

  describe "shared plan locks" do
    test "many plans hold the same unit at once", %{env: env} do
      assert plan(env, "/vpc").status == 200
      assert plan(env, "/vpc").status == 200
      assert plan(env, "/vpc").status == 200

      assert length(LockContext.list_active_shared_locks(env.id, "vpc")) == 3
      refute LockContext.is_environment_locked(env.id)
    end

    test "an apply does not wait for in-flight plans", %{env: env} do
      assert plan(env, "/vpc").status == 200
      assert plan(env, "/vpc").status == 200

      assert tf_apply(env, "/vpc").status == 200
      assert LockContext.get_active_exclusive_lock(env.id, "vpc") != nil
      # The plans are still recorded; nothing released them.
      assert length(LockContext.list_active_shared_locks(env.id, "vpc")) == 2
    end

    test "a plan is refused while an apply holds the unit, with the apply's LockInfo",
         %{env: env} do
      apply_id = Ecto.UUID.generate()
      assert lock(env, "/vpc", lock_info("OperationTypeApply", apply_id)).status == 200

      refused = plan(env, "/vpc")
      assert refused.status == 423
      body = Jason.decode!(refused.resp_body)
      assert body["ID"] == apply_id
      assert body["Operation"] == "OperationTypeApply"
    end

    test "a plan is refused by an env-wide force lock", %{env: env} do
      {:success, _} = LockContext.force_lock(env.id, "admin")
      assert plan(env, "/vpc").status == 423
      assert plan(env).status == 423
    end

    test "a plan on one unit is not blocked by an apply on another", %{env: env} do
      assert tf_apply(env, "/dns").status == 200
      assert plan(env, "/vpc").status == 200
    end

    test "a second apply is still refused", %{env: env} do
      assert tf_apply(env, "/vpc").status == 200
      assert tf_apply(env, "/vpc").status == 423
    end

    test "an unknown operation is treated as exclusive", %{env: env} do
      assert lock(env, "/vpc", lock_info("OperationTypeRefresh")).status == 200
      assert plan(env, "/vpc").status == 423
      assert lock(env, "/vpc", lock_info("")).status == 423
    end

    test "the audit row records the mode", %{env: env} do
      assert plan(env, "/vpc").status == 200
      assert tf_apply(env, "/dns").status == 200

      {events, _} = AuditContext.list_events(%{resource_type: "environment"})
      locked = Enum.filter(events, &(&1.action == "locked"))
      modes = locked |> Enum.map(&Jason.decode!(&1.metadata)["mode"]) |> Enum.sort()
      assert modes == ["exclusive", "shared"]
    end
  end

  describe "unlock releases by ID" do
    test "a plan releases only its own shared lock", %{env: env} do
      mine = Ecto.UUID.generate()
      other = Ecto.UUID.generate()
      assert lock(env, "/vpc", lock_info("OperationTypePlan", mine)).status == 200
      assert lock(env, "/vpc", lock_info("OperationTypePlan", other)).status == 200

      assert unlock(env, "/vpc", lock_info("OperationTypePlan", mine)).status == 200

      remaining = LockContext.list_active_shared_locks(env.id, "vpc")
      assert Enum.map(remaining, & &1.uuid) == [other]
    end

    test "releasing the apply lets the next plan through", %{env: env} do
      apply_id = Ecto.UUID.generate()
      assert lock(env, "/vpc", lock_info("OperationTypeApply", apply_id)).status == 200
      assert plan(env, "/vpc").status == 423

      assert unlock(env, "/vpc", lock_info("OperationTypeApply", apply_id)).status == 200
      assert plan(env, "/vpc").status == 200
    end

    test "an unlock with someone else's ID leaves the exclusive lock in place", %{env: env} do
      apply_id = Ecto.UUID.generate()
      assert lock(env, "/vpc", lock_info("OperationTypeApply", apply_id)).status == 200

      # Idempotent no-op for the caller, but the real holder keeps the lock.
      assert unlock(env, "/vpc", lock_info("OperationTypeApply", Ecto.UUID.generate())).status ==
               200

      assert LockContext.get_active_exclusive_lock(env.id, "vpc").uuid == apply_id
      assert tf_apply(env, "/vpc").status == 423
    end

    test "a shared lock's ID cannot release the exclusive lock", %{env: env} do
      plan_id = Ecto.UUID.generate()
      assert lock(env, "/vpc", lock_info("OperationTypePlan", plan_id)).status == 200
      assert tf_apply(env, "/vpc").status == 200

      assert unlock(env, "/vpc", lock_info("OperationTypePlan", plan_id)).status == 200
      assert LockContext.get_active_exclusive_lock(env.id, "vpc") != nil
      assert LockContext.list_active_shared_locks(env.id, "vpc") == []
    end

    test "an unlock with no ID releases the exclusive lock (legacy clients)", %{env: env} do
      assert plan(env, "/vpc").status == 200
      assert tf_apply(env, "/vpc").status == 200

      assert unlock(env, "/vpc", %{}).status == 200
      assert LockContext.get_active_exclusive_lock(env.id, "vpc") == nil
      # Shared rows are untouched by the legacy path.
      assert length(LockContext.list_active_shared_locks(env.id, "vpc")) == 1
    end

    test "a non-UUID ID is a no-op", %{env: env} do
      assert tf_apply(env, "/vpc").status == 200
      assert unlock(env, "/vpc", %{"ID" => "not-a-uuid"}).status == 200
      assert LockContext.get_active_exclusive_lock(env.id, "vpc") != nil
    end
  end

  describe "state push under mixed locks" do
    test "the exclusive holder pushes while plans are in flight", %{env: env} do
      assert plan(env, "/vpc").status == 200
      apply_id = Ecto.UUID.generate()
      assert lock(env, "/vpc", lock_info("OperationTypeApply", apply_id)).status == 200

      push = tf_conn(env) |> post("#{@base}/vpc/state?ID=#{apply_id}", %{"version" => 4})
      assert push.status == 200
    end

    test "a shared lock's ID does not authorise a push past a running apply", %{env: env} do
      plan_id = Ecto.UUID.generate()
      assert lock(env, "/vpc", lock_info("OperationTypePlan", plan_id)).status == 200
      assert tf_apply(env, "/vpc").status == 200

      push = tf_conn(env) |> post("#{@base}/vpc/state?ID=#{plan_id}", %{"version" => 4})
      assert push.status == 423
    end

    test "in-flight plans alone do not block a push", %{env: env} do
      # Same as `terraform apply -lock=false` today: no exclusive lock, no block.
      assert plan(env, "/vpc").status == 200
      push = tf_conn(env) |> post("#{@base}/vpc/state", %{"version" => 4})
      assert push.status == 200
    end
  end

  describe "LockInfo body terraform can decode" do
    # terraform's http client decodes a 423 body into statemgr.LockInfo,
    # whose Created is a Go time.Time and only parses RFC 3339. A naive
    # timestamp makes terraform treat the LockError as malformed and skip
    # the -lock-timeout retry loop entirely.
    test "Created is RFC 3339 with an offset and string fields are never null", %{env: env} do
      apply_id = Ecto.UUID.generate()
      assert lock(env, "/vpc", lock_info("OperationTypeApply", apply_id)).status == 200

      refused = plan(env, "/vpc")
      assert refused.status == 423
      body = Jason.decode!(refused.resp_body)

      assert {:ok, %DateTime{}, 0} = DateTime.from_iso8601(body["Created"])
      assert String.ends_with?(body["Created"], "Z")

      for key <- ~w(ID Path Operation Who Version Info) do
        assert is_binary(body[key]), "#{key} should be a string, got #{inspect(body[key])}"
      end
    end
  end

  describe "concurrent lock requests on one node" do
    # The old single-slot :sleeplocks guard answered 500 whenever two lock
    # inserts overlapped on one node. Shared locks overlap by design.
    test "16 simultaneous plan locks all succeed", %{env: env} do
      codes =
        1..16
        |> Task.async_stream(fn _ -> plan(env, "/vpc").status end,
          max_concurrency: 16,
          timeout: 30_000
        )
        |> Enum.map(fn {:ok, code} -> code end)

      assert Enum.uniq(codes) == [200]
      assert length(LockContext.list_active_shared_locks(env.id, "vpc")) == 16
    end

    test "16 simultaneous applies: one winner, the rest 423, never 5xx", %{env: env} do
      codes =
        1..16
        |> Task.async_stream(fn _ -> tf_apply(env, "/vpc").status end,
          max_concurrency: 16,
          timeout: 30_000
        )
        |> Enum.map(fn {:ok, code} -> code end)

      assert Enum.count(codes, &(&1 == 200)) == 1
      assert Enum.count(codes, &(&1 == 423)) == 15
      refute Enum.any?(codes, &(&1 >= 500))
    end
  end
end

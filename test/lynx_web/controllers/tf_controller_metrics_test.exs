defmodule LynxWeb.TfControllerMetricsTest do
  use LynxWeb.ConnCase, async: false

  alias Lynx.Context.EnvironmentContext
  alias Lynx.Context.PolicyContext
  alias Lynx.Context.ProjectContext
  alias Lynx.Context.TeamContext
  alias Lynx.Context.WorkspaceContext
  alias Lynx.Service.PolicyEngine.Stub

  @base "/tf/acme/network/production"
  @events [:lock, :unlock, :state_write, :apply_blocked, :plan_check]

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
          name: "Acme",
          slug: "acme",
          description: "Example workspace"
        })
      )

    {:ok, team} =
      TeamContext.create_team(
        TeamContext.new_team(%{name: "Infra", slug: "infra", description: "Infra team"})
      )

    {:ok, project} =
      ProjectContext.create_project(
        ProjectContext.new_project(%{
          name: "Network",
          slug: "network",
          description: "Network project",
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

    test_pid = self()
    handler = "metrics-test-#{inspect(test_pid)}"

    :telemetry.attach_many(
      handler,
      Enum.map(@events, &[:lynx, :tf, &1]),
      fn [:lynx, :tf, event], measurements, metadata, _ ->
        send(test_pid, {:tf_event, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    Stub.reset()

    {:ok, env: env, project: project}
  end

  defp tf_conn(env) do
    encoded = Base.encode64("#{env.username}:#{env.secret}")

    build_conn()
    |> put_req_header("authorization", "Basic #{encoded}")
    |> put_req_header("content-type", "application/json")
  end

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

  defp post_tf(env, path, body), do: tf_conn(env) |> post("#{@base}#{path}", body)

  @vpc %{workspace: "acme", project: "network", environment: "production", unit: "vpc"}

  test "plan lock and unlock emit plan events", %{env: env} do
    body = lock_info("OperationTypePlan")
    assert post_tf(env, "/vpc/lock", body).status == 200
    assert post_tf(env, "/vpc/unlock", body).status == 200

    assert_received {:tf_event, :lock, _, metadata}
    assert metadata == Map.merge(@vpc, %{operation: "plan", result: "acquired"})

    assert_received {:tf_event, :unlock, %{held_seconds: held}, metadata}
    assert held >= 0
    assert metadata == %{workspace: "acme", project: "network", operation: "plan"}
  end

  test "apply emits lock, state write and unlock", %{env: env} do
    id = Ecto.UUID.generate()
    body = lock_info("OperationTypeApply", id)
    assert post_tf(env, "/vpc/lock", body).status == 200
    assert post_tf(env, "/vpc/state?ID=#{id}", %{"version" => 4}).status == 200
    assert post_tf(env, "/vpc/unlock", body).status == 200

    assert_received {:tf_event, :lock, _, %{operation: "apply", result: "acquired"}}
    assert_received {:tf_event, :state_write, _, metadata}
    assert metadata == @vpc
    assert_received {:tf_event, :unlock, _, %{operation: "apply"}}
  end

  test "refused lock is a conflict", %{env: env} do
    assert post_tf(env, "/vpc/lock", lock_info("OperationTypeApply")).status == 200
    assert post_tf(env, "/vpc/lock", lock_info("OperationTypePlan")).status == 423

    assert_received {:tf_event, :lock, _, %{operation: "apply", result: "acquired"}}
    assert_received {:tf_event, :lock, _, %{operation: "plan", result: "conflict"}}
  end

  test "unrecognised operations are bucketed as other", %{env: env} do
    assert post_tf(env, "/vpc/lock", lock_info("state-mv")).status == 200
    assert_received {:tf_event, :lock, _, %{operation: "other"}}
  end

  test "unlock without a matching lock emits no duration", %{env: env} do
    assert post_tf(env, "/vpc/unlock", lock_info("OperationTypeApply")).status == 200
    refute_received {:tf_event, :unlock, _, _}
  end

  test "plan check emits its outcome for the unit", %{env: env} do
    assert post_tf(env, "/vpc/plan", %{"resource_changes" => []}).status == 200

    assert_received {:tf_event, :plan_check, _, metadata}
    assert metadata == Map.put(@vpc, :outcome, "passed")
  end

  test "state write without a passing plan check is blocked by the plan gate", %{env: env} do
    {:ok, env} = EnvironmentContext.update_env(env, %{require_passing_plan: true})

    assert post_tf(env, "/vpc/state", %{"version" => 4}).status == 423

    assert_received {:tf_event, :apply_blocked, _, metadata}
    assert metadata == Map.put(@vpc, :gate, "plan_gate")
    refute_received {:tf_event, :state_write, _, _}
  end

  test "state write violating a policy is blocked", %{env: env, project: project} do
    {:ok, env} = EnvironmentContext.update_env(env, %{block_violating_apply: true})

    {:ok, policy} =
      PolicyContext.create_policy(
        PolicyContext.new_policy(%{
          name: "deny-all",
          project_id: project.id,
          rego_source: "package x"
        })
      )

    Stub.register(policy.uuid, fn _input -> ["denied"] end)

    assert post_tf(env, "/vpc/state", %{"version" => 4}).status == 423

    assert_received {:tf_event, :apply_blocked, _, metadata}
    assert metadata == Map.put(@vpc, :gate, "policy_violation")
  end

  test "reporter exposes the series in Prometheus format", %{env: env} do
    start_supervised!(
      {TelemetryMetricsPrometheus.Core, name: Lynx.Metrics, metrics: Lynx.Metrics.metrics()}
    )

    body = lock_info("OperationTypeApply")
    assert post_tf(env, "/vpc/lock", body).status == 200
    assert post_tf(env, "/vpc/unlock", body).status == 200

    scrape = Lynx.Metrics.scrape()

    assert scrape =~
             ~s(lynx_tf_locks_total{environment="production",operation="apply",project="network",result="acquired",unit="vpc",workspace="acme"} 1)

    assert scrape =~
             ~s(lynx_tf_lock_held_seconds_count{operation="apply",project="network",workspace="acme"} 1)

    {:ok, env} = EnvironmentContext.update_env(env, %{require_passing_plan: true})
    assert post_tf(env, "/vpc/plan", %{"resource_changes" => []}).status == 200
    assert post_tf(env, "/vpc/state", %{"version" => 4}).status == 200
    assert post_tf(env, "/vpc/state", %{"version" => 4}).status == 423

    scrape = Lynx.Metrics.scrape()

    assert scrape =~
             ~s(lynx_tf_plan_checks_total{environment="production",outcome="passed",project="network",unit="vpc",workspace="acme"} 1)

    assert scrape =~
             ~s(lynx_tf_apply_blocked_total{environment="production",gate="plan_gate",project="network",unit="vpc",workspace="acme"} 1)

    conn = Lynx.Metrics.Plug.call(Plug.Test.conn(:get, "/metrics"), [])
    assert conn.status == 200
    assert conn.resp_body =~ "lynx_tf_locks_total"

    assert Lynx.Metrics.Plug.call(Plug.Test.conn(:get, "/"), []).status == 404
  end
end

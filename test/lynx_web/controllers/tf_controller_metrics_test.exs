defmodule LynxWeb.TfControllerMetricsTest do
  use LynxWeb.ConnCase, async: false

  alias Lynx.Context.EnvironmentContext
  alias Lynx.Context.ProjectContext
  alias Lynx.Context.TeamContext
  alias Lynx.Context.WorkspaceContext

  @base "/tf/aws-govcloud/platform/production"
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

    {:ok, env: env}
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

  @vpc %{workspace: "aws-govcloud", project: "platform", environment: "production", unit: "vpc"}

  test "plan lock and unlock emit plan events", %{env: env} do
    body = lock_info("OperationTypePlan")
    assert post_tf(env, "/vpc/lock", body).status == 200
    assert post_tf(env, "/vpc/unlock", body).status == 200

    assert_received {:tf_event, :lock, _, metadata}
    assert metadata == Map.merge(@vpc, %{operation: "plan", result: "acquired"})

    assert_received {:tf_event, :unlock, %{held_seconds: held}, metadata}
    assert held >= 0
    assert metadata == %{workspace: "aws-govcloud", project: "platform", operation: "plan"}
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

  test "reporter exposes the series in Prometheus format", %{env: env} do
    start_supervised!(
      {TelemetryMetricsPrometheus.Core, name: Lynx.Metrics, metrics: Lynx.Metrics.metrics()}
    )

    body = lock_info("OperationTypeApply")
    assert post_tf(env, "/vpc/lock", body).status == 200
    assert post_tf(env, "/vpc/unlock", body).status == 200

    scrape = Lynx.Metrics.scrape()

    assert scrape =~
             ~s(lynx_tf_locks_total{environment="production",operation="apply",project="platform",result="acquired",unit="vpc",workspace="aws-govcloud"} 1)

    assert scrape =~
             ~s(lynx_tf_lock_held_seconds_count{operation="apply",project="platform",workspace="aws-govcloud"} 1)

    conn = Lynx.Metrics.Plug.call(Plug.Test.conn(:get, "/metrics"), [])
    assert conn.status == 200
    assert conn.resp_body =~ "lynx_tf_locks_total"

    assert Lynx.Metrics.Plug.call(Plug.Test.conn(:get, "/"), []).status == 404
  end
end

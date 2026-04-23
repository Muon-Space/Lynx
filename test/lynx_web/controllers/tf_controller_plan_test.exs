defmodule LynxWeb.TfControllerPlanTest do
  @moduledoc """
  POST /tf/.../plan + apply gate (issue #38).

  Uses the in-memory `PolicyEngine.Stub` registered by `config/test.exs`
  so the suite doesn't depend on an OPA binary on PATH.
  """
  use LynxWeb.ConnCase, async: false

  alias Lynx.Context.{
    EnvironmentContext,
    PlanCheckContext,
    PolicyContext,
    ProjectContext,
    WorkspaceContext
  }

  alias Lynx.Service.PolicyEngine.Stub

  setup %{conn: conn} do
    install_params = %{
      app_name: "Lynx",
      app_url: "https://lynx.com",
      app_email: "hello@lynx.com",
      admin_name: "Admin",
      admin_email: "admin@example.com",
      admin_password: "password123"
    }

    post(conn, "/action/install", install_params)

    {:ok, ws} =
      WorkspaceContext.create_workspace(
        WorkspaceContext.new_workspace(%{name: "WS", slug: "ws", description: "x"})
      )

    {:ok, project} =
      ProjectContext.create_project(
        ProjectContext.new_project(%{
          name: "Proj",
          slug: "proj",
          description: "x",
          workspace_id: ws.id
        })
      )

    {:ok, env} =
      EnvironmentContext.create_env(
        EnvironmentContext.new_env(%{
          name: "Prod",
          slug: "prod",
          username: "tf-user",
          secret: "tf-secret",
          project_id: project.id
        })
      )

    Stub.reset()

    {:ok, conn: conn, project: project, env: env}
  end

  defp basic_auth(conn, username, password) do
    encoded = Base.encode64("#{username}:#{password}")
    put_req_header(conn, "authorization", "Basic #{encoded}")
  end

  defp post_plan(conn, env, plan, sub_path \\ nil) do
    path =
      case sub_path do
        nil -> "/tf/ws/proj/prod/plan"
        sp -> "/tf/ws/proj/prod/#{sp}/plan"
      end

    conn
    |> basic_auth(env.username, env.secret)
    |> put_req_header("content-type", "application/json")
    |> post(path, plan)
  end

  describe "POST /tf/.../plan" do
    test "no policies attached → outcome=passed with empty violations", %{conn: conn, env: env} do
      conn = post_plan(conn, env, %{"resource_changes" => []})

      body = json_response(conn, 200)
      assert body["outcome"] == "passed"
      assert body["violations"] == []
      assert body["policiesEvaluated"] == 0
      assert is_binary(body["id"])
    end

    test "passing policy → outcome=passed, plan_check row recorded", %{
      conn: conn,
      env: env,
      project: project
    } do
      {:ok, policy} =
        PolicyContext.create_policy(
          PolicyContext.new_policy(%{
            name: "no-public-buckets",
            project_id: project.id,
            rego_source: "package x"
          })
        )

      Stub.register(policy.uuid, fn _input -> [] end)

      conn = post_plan(conn, env, %{"resource_changes" => []})

      assert json_response(conn, 200)["outcome"] == "passed"

      [recorded] = PlanCheckContext.list_for_env(env.id, 5)
      assert recorded.outcome == "passed"
      assert recorded.violations == "[]"
      assert recorded.actor_type == "env_secret"
    end

    test "failing policy → outcome=failed, violations carry the messages", %{
      conn: conn,
      env: env,
      project: project
    } do
      {:ok, policy} =
        PolicyContext.create_policy(
          PolicyContext.new_policy(%{
            name: "no-public-buckets",
            project_id: project.id,
            rego_source: "package x"
          })
        )

      Stub.register(policy.uuid, fn _input -> ["bucket foo is public"] end)

      conn = post_plan(conn, env, %{"resource_changes" => [%{"address" => "aws_s3_bucket.foo"}]})

      body = json_response(conn, 200)
      assert body["outcome"] == "failed"

      assert [%{"policyName" => "no-public-buckets", "messages" => ["bucket foo is public"]}] =
               body["violations"]
    end

    test "engine error → outcome=errored", %{conn: conn, env: env, project: project} do
      {:ok, policy} =
        PolicyContext.create_policy(
          PolicyContext.new_policy(%{
            name: "broken",
            project_id: project.id,
            rego_source: "package x"
          })
        )

      Stub.fail(policy.uuid, :opa_unreachable)

      conn = post_plan(conn, env, %{"resource_changes" => []})

      body = json_response(conn, 200)
      assert body["outcome"] == "errored"
      assert [%{"messages" => [msg]}] = body["violations"]
      assert msg =~ "engine error"
    end

    test "404 when env doesn't exist", %{conn: conn, env: env} do
      conn =
        conn
        |> basic_auth(env.username, env.secret)
        |> put_req_header("content-type", "application/json")
        |> post("/tf/ws/proj/nope/plan", %{})

      assert conn.status in [403, 404]
    end
  end

  describe "apply gate" do
    setup %{env: env} do
      # Opt this env in to the apply gate.
      {:ok, env} = EnvironmentContext.update_env(env, %{require_passing_plan: true})
      {:ok, env: env}
    end

    test "without a passing plan_check, state-write is denied", %{conn: conn, env: env} do
      conn =
        conn
        |> basic_auth(env.username, env.secret)
        |> put_req_header("content-type", "application/json")
        |> post("/tf/ws/proj/prod/state", %{"version" => 4})

      # Apply-gate denials return 423 with a LockJSON body so terraform's
      # lock-error path can surface the message (the only path it doesn't
      # drop the body on). State-push 4xx surfaces no body.
      assert conn.status == 423
      assert conn.resp_body =~ "Apply gate"
    end

    test "with a fresh passing plan_check, state-write succeeds and consumes it", %{
      conn: conn,
      env: env
    } do
      # Step 1: Upload a plan that passes (no policies attached so this is automatic).
      _ = post_plan(conn, env, %{"resource_changes" => []})

      # Step 2: state-write for the same actor.
      conn =
        build_conn()
        |> basic_auth(env.username, env.secret)
        |> put_req_header("content-type", "application/json")
        |> post("/tf/ws/proj/prod/state", %{"version" => 4})

      assert conn.status == 200

      # Step 3: the same plan_check is now consumed; a second state-write 401s.
      conn2 =
        build_conn()
        |> basic_auth(env.username, env.secret)
        |> put_req_header("content-type", "application/json")
        |> post("/tf/ws/proj/prod/state", %{"version" => 5})

      assert conn2.status == 423
      assert conn2.resp_body =~ "Apply gate"
    end

    test "stale plan_check (older than plan_max_age_seconds) is rejected", %{
      conn: conn,
      env: env
    } do
      # Tighten the window so we don't have to fast-forward time.
      {:ok, env} = EnvironmentContext.update_env(env, %{plan_max_age_seconds: 1})

      # Insert a passing check directly with an old inserted_at.
      old_ts =
        DateTime.utc_now()
        |> DateTime.add(-3600, :second)
        |> DateTime.to_naive()
        |> NaiveDateTime.truncate(:second)

      attrs =
        PlanCheckContext.new_plan_check(%{
          environment_id: env.id,
          sub_path: "",
          outcome: "passed",
          plan_json: "{}",
          actor_signature: "env_secret:#{env.username}",
          actor_name: env.username,
          actor_type: "env_secret"
        })

      {:ok, check} = PlanCheckContext.create_plan_check(attrs)

      check
      |> Ecto.Changeset.change(%{inserted_at: old_ts})
      |> Lynx.Repo.update!()

      conn =
        conn
        |> basic_auth(env.username, env.secret)
        |> put_req_header("content-type", "application/json")
        |> post("/tf/ws/proj/prod/state", %{"version" => 4})

      assert conn.status == 423
      assert conn.resp_body =~ "older than"
    end

    test "actor mismatch: plan from one credential, apply from another → denied", %{
      conn: conn,
      env: env
    } do
      # Plan via env-secret auth.
      _ = post_plan(conn, env, %{"resource_changes" => []})

      # Try to consume via a *different* credential. Since we don't have
      # another credential set up, we can't easily test cross-actor, but
      # we can verify that explicitly: a plan_check from actor A is not
      # findable by latest_unconsumed_passing for actor B.
      assert PlanCheckContext.latest_unconsumed_passing(env.id, "", "user:other@example.com") ==
               nil
    end
  end

  describe "block_violating_apply gate (state-write evaluation)" do
    setup %{env: env, project: project} do
      # Per-env override on, no plan upload required. The state body
      # synthesizer produces `resource_changes[]` with action=update from
      # whatever's in the pushed state, which is what each policy sees.
      {:ok, env} = EnvironmentContext.update_env(env, %{block_violating_apply: true})

      {:ok, policy} =
        PolicyContext.create_policy(
          PolicyContext.new_policy(%{
            name: "no-public-buckets",
            project_id: project.id,
            rego_source: "package x"
          })
        )

      {:ok, env: env, policy: policy}
    end

    test "rejects state-write when a policy fires + emits apply_blocked audit", %{
      conn: conn,
      env: env,
      policy: policy
    } do
      # Stub fires deny on any input that mentions a public S3 bucket
      # in resource_changes[].after.acl.
      Stub.register(policy.uuid, fn input ->
        for change <- Map.get(input, "resource_changes", []),
            get_in(change, ["change", "after", "acl"]) == "public-read" do
          "S3 bucket #{change["address"]} is public"
        end
      end)

      conn =
        conn
        |> basic_auth(env.username, env.secret)
        |> put_req_header("content-type", "application/json")
        |> post("/tf/ws/proj/prod/state", %{
          "version" => 4,
          "resources" => [
            %{
              "mode" => "managed",
              "type" => "aws_s3_bucket",
              "name" => "foo",
              "instances" => [%{"attributes" => %{"acl" => "public-read"}}]
            }
          ]
        })

      assert conn.status == 423
      assert conn.resp_body =~ "S3 bucket aws_s3_bucket.foo is public"

      # Audit row written with the policy uuid in metadata so the
      # per-policy detail page can find it.
      import Ecto.Query

      [event] =
        Lynx.Repo.all(
          from(a in Lynx.Model.AuditEvent,
            where: a.action == "apply_blocked" and a.resource_id == ^env.uuid
          )
        )

      meta = Jason.decode!(event.metadata)
      assert meta["gate"] == "policy_violation"
      assert [%{"name" => "no-public-buckets", "uuid" => uuid}] = meta["policies"]
      assert uuid == policy.uuid
    end

    test "passes through when no resource trips a policy", %{
      conn: conn,
      env: env,
      policy: policy
    } do
      Stub.register(policy.uuid, fn _input -> [] end)

      conn =
        conn
        |> basic_auth(env.username, env.secret)
        |> put_req_header("content-type", "application/json")
        |> post("/tf/ws/proj/prod/state", %{"version" => 4, "resources" => []})

      assert conn.status == 200
    end

    test "fail-closed on engine error: state-write rejected when OPA can't be reached", %{
      conn: conn,
      env: env,
      policy: policy
    } do
      Stub.fail(policy.uuid, :opa_unreachable)

      conn =
        conn
        |> basic_auth(env.username, env.secret)
        |> put_req_header("content-type", "application/json")
        |> post("/tf/ws/proj/prod/state", %{"version" => 4, "resources" => []})

      assert conn.status == 423
      assert conn.resp_body =~ "engine error"
    end
  end
end

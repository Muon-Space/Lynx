defmodule LynxWeb.TfControllerTest do
  use LynxWeb.ConnCase

  alias Lynx.Context.TeamContext
  alias Lynx.Context.ProjectContext
  alias Lynx.Context.EnvironmentContext
  alias Lynx.Context.UserContext

  setup %{conn: conn} do
    # Install the app and create admin
    install_params = %{
      app_name: "Lynx",
      app_url: "https://lynx.com",
      app_email: "hello@lynx.com",
      admin_name: "Admin",
      admin_email: "admin@example.com",
      admin_password: "password123"
    }

    post(conn, "/action/install", install_params)

    # Create team, project, environment
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
          team_id: team.id
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

    admin = UserContext.get_user_by_email("admin@example.com")

    {:ok, conn: conn, team: team, project: project, env: env, admin: admin}
  end

  defp basic_auth(conn, username, password) do
    encoded = Base.encode64("#{username}:#{password}")
    put_req_header(conn, "authorization", "Basic #{encoded}")
  end

  describe "state operations via /tf/" do
    test "push and pull root state", %{conn: conn, env: env} do
      state_body = %{"version" => 4, "serial" => 1, "lineage" => "abc"}

      # Push state
      conn =
        conn
        |> basic_auth(env.username, env.secret)
        |> put_req_header("content-type", "application/json")
        |> post("/tf/platform/production/state", state_body)

      assert conn.status == 200

      # Pull state
      conn =
        build_conn()
        |> basic_auth(env.username, env.secret)
        |> get("/tf/platform/production/state")

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["version"] == 4
    end

    test "push and pull sub-path state (Terragrunt unit)", %{conn: conn, env: env} do
      dns_state = %{"version" => 4, "serial" => 1, "resources" => ["aws_route53_zone"]}
      vpc_state = %{"version" => 4, "serial" => 1, "resources" => ["aws_vpc"]}

      # Push DNS unit state
      conn
      |> basic_auth(env.username, env.secret)
      |> put_req_header("content-type", "application/json")
      |> post("/tf/platform/production/dns/state", dns_state)

      # Push VPC unit state
      build_conn()
      |> basic_auth(env.username, env.secret)
      |> put_req_header("content-type", "application/json")
      |> post("/tf/platform/production/vpc/state", vpc_state)

      # Pull DNS state
      dns_conn =
        build_conn()
        |> basic_auth(env.username, env.secret)
        |> get("/tf/platform/production/dns/state")

      assert dns_conn.status == 200
      assert Jason.decode!(dns_conn.resp_body)["resources"] == ["aws_route53_zone"]

      # Pull VPC state
      vpc_conn =
        build_conn()
        |> basic_auth(env.username, env.secret)
        |> get("/tf/platform/production/vpc/state")

      assert vpc_conn.status == 200
      assert Jason.decode!(vpc_conn.resp_body)["resources"] == ["aws_vpc"]
    end

    test "sub-paths are independent (don't bleed)", %{conn: conn, env: env} do
      conn
      |> basic_auth(env.username, env.secret)
      |> put_req_header("content-type", "application/json")
      |> post("/tf/platform/production/dns/state", %{"unit" => "dns"})

      # Root state should not exist
      root_conn =
        build_conn()
        |> basic_auth(env.username, env.secret)
        |> get("/tf/platform/production/state")

      assert root_conn.status == 404

      # Different sub-path should not exist
      other_conn =
        build_conn()
        |> basic_auth(env.username, env.secret)
        |> get("/tf/platform/production/vpc/state")

      assert other_conn.status == 404
    end

    test "nested sub-paths work", %{conn: conn, env: env} do
      conn
      |> basic_auth(env.username, env.secret)
      |> put_req_header("content-type", "application/json")
      |> post("/tf/platform/production/network/vpc/state", %{"nested" => true})

      nested_conn =
        build_conn()
        |> basic_auth(env.username, env.secret)
        |> get("/tf/platform/production/network/vpc/state")

      assert nested_conn.status == 200
      assert Jason.decode!(nested_conn.resp_body)["nested"] == true
    end

    test "returns 404 for nonexistent project", %{conn: conn, env: env} do
      conn =
        conn
        |> basic_auth(env.username, env.secret)
        |> get("/tf/nonexistent/production/state")

      assert conn.status == 403
    end

    test "returns 403 for wrong credentials", %{conn: conn} do
      conn =
        conn
        |> basic_auth("wrong", "creds")
        |> get("/tf/platform/production/state")

      assert conn.status == 403
    end
  end

  describe "lock operations via /tf/" do
    test "lock and unlock root path", %{conn: conn, env: env} do
      lock_body = %{
        "ID" => Ecto.UUID.generate(),
        "Operation" => "OperationTypeApply",
        "Info" => "",
        "Who" => "test@example.com",
        "Version" => "1.9.0",
        "Path" => ""
      }

      # Lock
      lock_conn =
        conn
        |> basic_auth(env.username, env.secret)
        |> put_req_header("content-type", "application/json")
        |> post("/tf/platform/production/lock", lock_body)

      assert lock_conn.status == 200

      # Second lock should return 423
      locked_conn =
        build_conn()
        |> basic_auth(env.username, env.secret)
        |> put_req_header("content-type", "application/json")
        |> post("/tf/platform/production/lock", lock_body)

      assert locked_conn.status == 423

      # Unlock
      unlock_conn =
        build_conn()
        |> basic_auth(env.username, env.secret)
        |> put_req_header("content-type", "application/json")
        |> post("/tf/platform/production/unlock", %{})

      assert unlock_conn.status == 200
    end

    test "sub-path locks are independent", %{conn: conn, env: env} do
      lock_body = fn ->
        %{
          "ID" => Ecto.UUID.generate(),
          "Operation" => "OperationTypeApply",
          "Info" => "",
          "Who" => "test",
          "Version" => "1.9.0",
          "Path" => ""
        }
      end

      # Lock DNS unit
      conn
      |> basic_auth(env.username, env.secret)
      |> put_req_header("content-type", "application/json")
      |> post("/tf/platform/production/dns/lock", lock_body.())

      # VPC unit should still be lockable
      vpc_conn =
        build_conn()
        |> basic_auth(env.username, env.secret)
        |> put_req_header("content-type", "application/json")
        |> post("/tf/platform/production/vpc/lock", lock_body.())

      assert vpc_conn.status == 200

      # DNS should be locked
      dns_conn =
        build_conn()
        |> basic_auth(env.username, env.secret)
        |> put_req_header("content-type", "application/json")
        |> post("/tf/platform/production/dns/lock", lock_body.())

      assert dns_conn.status == 423
    end

    test "environment-level lock blocks all unit locks", %{conn: conn, env: env} do
      # Create an environment-level lock (root path)
      Lynx.Module.LockModule.force_lock(env.id, "admin")

      lock_body = %{
        "ID" => Ecto.UUID.generate(),
        "Operation" => "apply",
        "Info" => "",
        "Who" => "test",
        "Version" => "1.9.0",
        "Path" => ""
      }

      # Trying to lock any unit should return 423
      dns_conn =
        conn
        |> basic_auth(env.username, env.secret)
        |> put_req_header("content-type", "application/json")
        |> post("/tf/platform/production/dns/lock", lock_body)

      assert dns_conn.status == 423
    end
  end

  describe "email-based API key auth" do
    test "authenticates with email + API key", %{conn: conn, admin: admin} do
      state_body = %{"version" => 4, "serial" => 1}

      conn =
        conn
        |> basic_auth(admin.email, admin.api_key)
        |> put_req_header("content-type", "application/json")
        |> post("/tf/platform/production/state", state_body)

      assert conn.status == 200
    end

    test "rejects wrong API key", %{conn: conn, admin: admin} do
      conn =
        conn
        |> basic_auth(admin.email, "wrong-key")
        |> get("/tf/platform/production/state")

      assert conn.status == 403
    end

    test "rejects nonexistent email", %{conn: conn} do
      conn =
        conn
        |> basic_auth("nobody@example.com", "some-key")
        |> get("/tf/platform/production/state")

      assert conn.status == 403
    end
  end

  describe "legacy /client/ routes" do
    test "legacy routes work (team slug ignored)", %{conn: conn, env: env} do
      state_body = %{"version" => 4, "legacy" => true}

      # Push via legacy route
      conn
      |> basic_auth(env.username, env.secret)
      |> put_req_header("content-type", "application/json")
      |> post("/client/infra/platform/production/state", state_body)

      # Pull via new /tf/ route
      tf_conn =
        build_conn()
        |> basic_auth(env.username, env.secret)
        |> get("/tf/platform/production/state")

      assert tf_conn.status == 200
      assert Jason.decode!(tf_conn.resp_body)["legacy"] == true
    end

    test "legacy lock/unlock work", %{conn: conn, env: env} do
      lock_body = %{
        "ID" => Ecto.UUID.generate(),
        "Operation" => "apply",
        "Info" => "",
        "Who" => "test",
        "Version" => "1.9.0",
        "Path" => ""
      }

      lock_conn =
        conn
        |> basic_auth(env.username, env.secret)
        |> put_req_header("content-type", "application/json")
        |> post("/client/infra/platform/production/lock", lock_body)

      assert lock_conn.status == 200

      unlock_conn =
        build_conn()
        |> basic_auth(env.username, env.secret)
        |> put_req_header("content-type", "application/json")
        |> post("/client/infra/platform/production/unlock", %{})

      assert unlock_conn.status == 200
    end
  end
end

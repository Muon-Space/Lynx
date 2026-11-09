defmodule LynxWeb.StateRollbackControllerTest do
  @moduledoc """
  `POST /api/v1/environment/:e_uuid/state/:state_uuid/rollback`.
  """
  use LynxWeb.ConnCase, async: false

  alias Lynx.Context.{
    AuditContext,
    EnvironmentContext,
    LockContext,
    PolicyContext,
    ProjectContext,
    RoleContext,
    StateContext,
    TeamContext,
    UserContext,
    WorkspaceContext
  }

  alias Lynx.Service.PolicyEngine.Stub

  setup %{conn: conn} do
    api_key = install_admin_and_get_api_key(conn)
    Stub.reset()

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

    v1 = add_state(env, 1, ["aws_s3_bucket.logs"])
    v2 = add_state(env, 2, ["aws_s3_bucket.logs", "aws_iam_role.ci"])
    v3 = add_state(env, 3, [])

    {:ok, conn: conn, api_key: api_key, project: project, env: env, v1: v1, v2: v2, v3: v3}
  end

  defp add_state(env, serial, addresses, sub_path \\ "") do
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

    value =
      Jason.encode!(%{
        "version" => 4,
        "serial" => serial,
        "lineage" => "lineage-1",
        "resources" => resources
      })

    {:ok, state} =
      StateContext.create_state(
        StateContext.new_state(%{
          name: "_tf_state_",
          value: value,
          sub_path: sub_path,
          environment_id: env.id
        })
      )

    state
  end

  defp rollback_path(env, state),
    do: "/api/v1/environment/#{env.uuid}/state/#{state.uuid}/rollback"

  defp grant(user, project, role_name) do
    role = RoleContext.get_role_by_name(role_name)
    n = System.unique_integer([:positive])

    {:ok, team} =
      TeamContext.create_team(
        TeamContext.new_team(%{name: "T-#{n}", slug: "t-#{n}", description: "x"})
      )

    {:ok, _} = UserContext.add_user_to_team(user.id, team.id)
    {:ok, _} = ProjectContext.add_project_to_team(project.id, team.id, role.id)
  end

  test "creates a new version that copies the target", %{
    conn: conn,
    api_key: api_key,
    env: env,
    v1: v1,
    v3: v3
  } do
    conn = conn |> with_api_key(api_key) |> post(rollback_path(env, v1))
    body = json_response(conn, 201)

    assert body["rolledBackFrom"] == v1.uuid
    assert body["rolledBackFromVersion"] == 1
    assert body["previousId"] == v3.uuid
    assert body["version"] == 4
    assert body["serial"] == 4
    assert body["subPath"] == ""

    latest = StateContext.get_latest_state_by_environment_and_path(env.id, "")
    assert latest.uuid == body["id"]
    assert Jason.decode!(latest.value)["resources"] == Jason.decode!(v1.value)["resources"]

    {[event], 1} = AuditContext.list_events(%{action: "state_rolled_back"})
    assert event.resource_id == env.uuid
    assert event.actor_name == "John Doe"
    assert Jason.decode!(event.metadata)["from_state_uuid"] == v1.uuid
  end

  test "rolls back a unit", %{conn: conn, api_key: api_key, env: env} do
    u1 = add_state(env, 1, ["aws_vpc.main"], "network/vpc")
    _u2 = add_state(env, 2, [], "network/vpc")

    conn = conn |> with_api_key(api_key) |> post(rollback_path(env, u1))
    assert json_response(conn, 201)["subPath"] == "network/vpc"
  end

  test "404 for an unknown version or environment", %{
    conn: conn,
    api_key: api_key,
    env: env,
    v1: v1
  } do
    missing = %{uuid: Ecto.UUID.generate()}

    assert conn
           |> with_api_key(api_key)
           |> post(rollback_path(env, missing))
           |> json_response(404)

    assert build_conn()
           |> with_api_key(api_key)
           |> post("/api/v1/environment/#{Ecto.UUID.generate()}/state/#{v1.uuid}/rollback")
           |> response(404)
  end

  test "400 when the version is already current", %{
    conn: conn,
    api_key: api_key,
    env: env,
    v3: v3
  } do
    body = conn |> with_api_key(api_key) |> post(rollback_path(env, v3)) |> json_response(400)
    assert body["errorMessage"] =~ "already current"
  end

  test "423 while an apply holds the lock", %{conn: conn, api_key: api_key, env: env, v1: v1} do
    {:ok, _} =
      LockContext.create_lock(
        LockContext.new_lock(%{
          environment_id: env.id,
          operation: "OperationTypeApply",
          info: "",
          who: "ci@runner",
          version: "1.9.0",
          path: "",
          sub_path: "",
          is_active: true
        })
      )

    body = conn |> with_api_key(api_key) |> post(rollback_path(env, v1)) |> json_response(423)
    assert body["errorMessage"] =~ "ci@runner"
    assert StateContext.count_states_by_path(env.id, "") == 3
  end

  test "422 when the restored body violates a policy and the gate is on", %{
    conn: conn,
    api_key: api_key,
    project: project,
    env: env,
    v2: v2
  } do
    {:ok, _} = EnvironmentContext.update_env(env, %{block_violating_apply: true})

    {:ok, policy} =
      PolicyContext.create_policy(
        PolicyContext.new_policy(%{
          name: "no-iam",
          project_id: project.id,
          rego_source: "package x"
        })
      )

    Stub.register(policy.uuid, fn input ->
      for c <- input["resource_changes"], c["type"] == "aws_iam_role", do: "no IAM roles here"
    end)

    body = conn |> with_api_key(api_key) |> post(rollback_path(env, v2)) |> json_response(422)
    assert body["errorMessage"] =~ "no IAM roles here"
    assert StateContext.count_states_by_path(env.id, "") == 3
  end

  describe "permissions" do
    test "planner gets 403", %{project: project, env: env, v1: v1} do
      {user, key} = create_regular_user_with_api_key()
      grant(user, project, "planner")

      assert build_conn() |> with_api_key(key) |> post(rollback_path(env, v1)) |> response(403)
      assert StateContext.count_states_by_path(env.id, "") == 3
    end

    test "applier can roll back", %{project: project, env: env, v1: v1} do
      {user, key} = create_regular_user_with_api_key()
      grant(user, project, "applier")

      assert build_conn()
             |> with_api_key(key)
             |> post(rollback_path(env, v1))
             |> json_response(201)
    end

    test "state:rollback is seeded on applier and admin only" do
      for {role, expected} <- [{"planner", false}, {"applier", true}, {"admin", true}] do
        perms = RoleContext.get_role_by_name(role) |> RoleContext.permissions_for()
        assert "state:rollback" in perms == expected, "#{role}"
      end
    end
  end
end

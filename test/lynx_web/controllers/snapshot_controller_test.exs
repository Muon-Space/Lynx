defmodule LynxWeb.SnapshotControllerTest do
  use LynxWeb.ConnCase

  setup %{conn: conn} do
    api_key = install_admin_and_get_api_key(conn)
    {:ok, conn: conn, api_key: api_key}
  end

  defp create_team_via_api(api_key) do
    n = System.unique_integer([:positive])
    admin = Lynx.Context.UserContext.get_user_by_email("john@example.com")

    conn =
      build_conn()
      |> with_api_key(api_key)
      |> post("/api/v1/team", %{
        name: "T#{n}",
        slug: "t-#{n}",
        description: "for snapshot tests",
        members: [admin.uuid]
      })

    json_response(conn, 201)["id"]
  end

  defp create_project_via_api(api_key) do
    team_uuid = create_team_via_api(api_key)
    n = System.unique_integer([:positive])

    conn =
      build_conn()
      |> with_api_key(api_key)
      |> post("/api/v1/project", %{
        name: "P#{n}",
        slug: "p-#{n}",
        description: "for snapshot tests",
        team_ids: [team_uuid]
      })

    json_response(conn, 201)["id"]
  end

  describe "auth" do
    test "GET /api/v1/snapshot without API key returns 403", %{conn: conn} do
      conn = get(conn, "/api/v1/snapshot")
      assert response(conn, 403)
    end
  end

  describe "list" do
    test "returns snapshot list", %{conn: conn, api_key: api_key} do
      conn = conn |> with_api_key(api_key) |> get("/api/v1/snapshot")
      body = json_response(conn, 200)
      assert is_list(body["snapshots"])
    end
  end

  describe "create" do
    test "creates a snapshot for a project", %{conn: conn, api_key: api_key} do
      team_uuid = create_team_via_api(api_key)
      project_uuid = create_project_via_api(api_key)

      conn =
        conn
        |> with_api_key(api_key)
        |> post("/api/v1/snapshot", %{
          title: "First",
          description: "test snapshot",
          record_type: "project",
          record_uuid: project_uuid,
          team_id: team_uuid
        })

      body = json_response(conn, 201)
      assert body["title"] == "First"
    end

    test "returns 400 when title is missing", %{conn: conn, api_key: api_key} do
      team_uuid = create_team_via_api(api_key)
      project_uuid = create_project_via_api(api_key)

      conn =
        conn
        |> with_api_key(api_key)
        |> post("/api/v1/snapshot", %{
          record_type: "project",
          record_uuid: project_uuid,
          team_id: team_uuid
        })

      assert response(conn, 400)
    end
  end

  describe "index" do
    test "404 for unknown uuid", %{conn: conn, api_key: api_key} do
      conn =
        conn
        |> with_api_key(api_key)
        |> get("/api/v1/snapshot/00000000-0000-0000-0000-000000000000")

      assert response(conn, 404)
    end
  end
end

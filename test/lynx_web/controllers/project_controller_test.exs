defmodule LynxWeb.ProjectControllerTest do
  use LynxWeb.ConnCase

  setup %{conn: conn} do
    api_key = install_admin_and_get_api_key(conn)
    {:ok, conn: conn, api_key: api_key}
  end

  describe "auth" do
    test "GET /api/v1/project without API key returns 403", %{conn: conn} do
      conn = get(conn, "/api/v1/project")
      assert response(conn, 403)
    end
  end

  describe "list" do
    test "returns projects list", %{conn: conn, api_key: api_key} do
      conn = conn |> with_api_key(api_key) |> get("/api/v1/project")
      body = json_response(conn, 200)
      assert is_list(body["projects"])
    end
  end

  describe "create" do
    test "creates a project", %{conn: conn, api_key: api_key} do
      # `team_ids` is optional (see "creates a project without any teams"
      # below) but the happy path here still attaches one.
      admin = Lynx.Context.UserContext.get_user_by_email("john@example.com")

      team_resp =
        build_conn()
        |> with_api_key(api_key)
        |> post("/api/v1/team", %{
          name: "T1",
          slug: "t1",
          description: "test team",
          members: [admin.uuid]
        })

      team_uuid = json_response(team_resp, 201)["id"]

      conn =
        conn
        |> with_api_key(api_key)
        |> post("/api/v1/project", %{
          name: "Backend",
          slug: "backend",
          description: "API server",
          team_ids: [team_uuid]
        })

      body = json_response(conn, 201)
      assert body["name"] == "Backend"
      assert body["slug"] == "backend"
    end

    test "returns 400 when name is missing", %{conn: conn, api_key: api_key} do
      conn =
        conn
        |> with_api_key(api_key)
        |> post("/api/v1/project", %{slug: "x", description: "y"})

      assert response(conn, 400)
    end

    test "creates a project without any teams", %{conn: conn, api_key: api_key} do
      conn =
        conn
        |> with_api_key(api_key)
        |> post("/api/v1/project", %{
          name: "Solo",
          slug: "solo",
          description: "no team attached"
        })

      body = json_response(conn, 201)
      assert body["name"] == "Solo"
      assert body["teams"] == []
      assert body["team"] == nil
    end
  end

  describe "index" do
    test "404 for unknown uuid", %{conn: conn, api_key: api_key} do
      conn =
        conn
        |> with_api_key(api_key)
        |> get("/api/v1/project/00000000-0000-0000-0000-000000000000")

      assert response(conn, 404)
    end
  end
end

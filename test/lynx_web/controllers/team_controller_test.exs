defmodule LynxWeb.TeamControllerTest do
  use LynxWeb.ConnCase

  setup %{conn: conn} do
    api_key = install_admin_and_get_api_key(conn)
    {:ok, conn: conn, api_key: api_key}
  end

  describe "auth" do
    test "GET /api/v1/team without API key returns 403", %{conn: conn} do
      conn = get(conn, "/api/v1/team")
      assert response(conn, 403)
    end
  end

  describe "list" do
    test "returns teams list", %{conn: conn, api_key: api_key} do
      conn = conn |> with_api_key(api_key) |> get("/api/v1/team")
      body = json_response(conn, 200)
      assert is_list(body["teams"])
    end
  end

  describe "create" do
    test "creates a team", %{conn: conn, api_key: api_key} do
      # team_controller requires non-empty `members`; use the admin user's uuid
      admin = Lynx.Context.UserContext.get_user_by_email("john@example.com")

      conn =
        conn
        |> with_api_key(api_key)
        |> post("/api/v1/team", %{
          name: "Platform",
          slug: "platform",
          description: "Platform team",
          members: [admin.uuid]
        })

      body = json_response(conn, 201)
      assert body["name"] == "Platform"
      assert body["slug"] == "platform"
    end

    test "returns 400 when name is missing", %{conn: conn, api_key: api_key} do
      conn = conn |> with_api_key(api_key) |> post("/api/v1/team", %{slug: "x"})
      assert response(conn, 400)
    end
  end

  describe "index/delete" do
    test "404 for unknown uuid on get", %{conn: conn, api_key: api_key} do
      conn =
        conn |> with_api_key(api_key) |> get("/api/v1/team/00000000-0000-0000-0000-000000000000")

      assert response(conn, 404)
    end

    test "404 for unknown uuid on delete", %{conn: conn, api_key: api_key} do
      conn =
        conn
        |> with_api_key(api_key)
        |> delete("/api/v1/team/00000000-0000-0000-0000-000000000000")

      assert response(conn, 404)
    end
  end
end

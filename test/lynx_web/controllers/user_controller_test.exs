defmodule LynxWeb.UserControllerTest do
  use LynxWeb.ConnCase

  setup %{conn: conn} do
    api_key = install_admin_and_get_api_key(conn)
    {:ok, conn: conn, api_key: api_key}
  end

  describe "auth" do
    test "GET /api/v1/user without API key returns 403", %{conn: conn} do
      conn = get(conn, "/api/v1/user")
      assert response(conn, 403)
    end

    test "POST /api/v1/user without API key returns 403", %{conn: conn} do
      conn = post(conn, "/api/v1/user", %{name: "x"})
      assert response(conn, 403)
    end
  end

  describe "list" do
    test "returns paginated users", %{conn: conn, api_key: api_key} do
      conn = conn |> with_api_key(api_key) |> get("/api/v1/user")
      body = json_response(conn, 200)
      assert is_list(body["users"])
      # admin user from install is included
      assert Enum.any?(body["users"], &(&1["email"] == "john@example.com"))
    end
  end

  describe "create" do
    test "creates a new user with valid params", %{conn: conn, api_key: api_key} do
      conn =
        conn
        |> with_api_key(api_key)
        |> post("/api/v1/user", %{
          name: "Alice",
          email: "alice@example.com",
          password: "secretpass",
          role: "regular"
        })

      body = json_response(conn, 201)
      assert body["email"] == "alice@example.com"
      assert body["name"] == "Alice"
    end

    test "returns 400 when email is missing", %{conn: conn, api_key: api_key} do
      conn =
        conn
        |> with_api_key(api_key)
        |> post("/api/v1/user", %{name: "x", password: "y", role: "regular"})

      assert response(conn, 400)
    end
  end

  describe "index/show" do
    test "returns 404 for unknown uuid", %{conn: conn, api_key: api_key} do
      conn =
        conn |> with_api_key(api_key) |> get("/api/v1/user/00000000-0000-0000-0000-000000000000")

      assert response(conn, 404)
    end
  end
end

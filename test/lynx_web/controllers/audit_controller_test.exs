defmodule LynxWeb.AuditControllerTest do
  use LynxWeb.ConnCase

  alias Lynx.Module.AuditModule
  alias Lynx.Context.UserContext

  setup %{conn: conn} do
    api_key = install_admin_and_get_api_key(conn)
    admin = UserContext.get_user_by_email("john@example.com")
    {:ok, conn: conn, api_key: api_key, admin: admin}
  end

  describe "auth" do
    test "GET /api/v1/audit without API key returns 403", %{conn: conn} do
      conn = get(conn, "/api/v1/audit")
      assert response(conn, 403)
    end

    test "non-super user gets 403", %{conn: conn} do
      # Create a regular user with an api_key for header-based auth
      {:ok, user} =
        UserContext.create_user(
          UserContext.new_user(%{
            email: "regular@example.com",
            name: "Regular User",
            password_hash: "$2b$12$" <> String.duplicate("a", 53),
            verified: true,
            last_seen: DateTime.utc_now() |> DateTime.truncate(:second),
            role: "user",
            api_key: "regular-api-key-123",
            uuid: Ecto.UUID.generate()
          })
        )

      conn = conn |> with_api_key(user.api_key) |> get("/api/v1/audit")
      assert response(conn, 403)
    end
  end

  describe "list" do
    test "returns empty events when no audits logged", %{conn: conn, api_key: api_key} do
      conn = conn |> with_api_key(api_key) |> get("/api/v1/audit")
      body = json_response(conn, 200)
      assert is_list(body["events"])
      assert is_map(body["_metadata"])
      assert body["_metadata"]["limit"] == 50
      assert body["_metadata"]["offset"] == 0
    end

    test "returns logged events", %{conn: conn, api_key: api_key, admin: admin} do
      AuditModule.log_user(admin, "created", "project", "p-uuid-1", "Cool Project")
      AuditModule.log_user(admin, "deleted", "team", "t-uuid-1", "Old Team")

      conn = conn |> with_api_key(api_key) |> get("/api/v1/audit")
      body = json_response(conn, 200)

      names = Enum.map(body["events"], & &1["resourceName"])
      assert "Cool Project" in names
      assert "Old Team" in names
    end

    test "filters by action param", %{conn: conn, api_key: api_key, admin: admin} do
      AuditModule.log_user(admin, "created", "project", "p1", "Created Item")
      AuditModule.log_user(admin, "deleted", "project", "p2", "Deleted Item")

      conn = conn |> with_api_key(api_key) |> get("/api/v1/audit?action=created")
      body = json_response(conn, 200)

      names = Enum.map(body["events"], & &1["resourceName"])
      assert "Created Item" in names
      refute "Deleted Item" in names
    end

    test "filters by resource_type param", %{conn: conn, api_key: api_key, admin: admin} do
      AuditModule.log_user(admin, "created", "project", "p1", "ProjOne")
      AuditModule.log_user(admin, "created", "team", "t1", "TeamOne")

      conn = conn |> with_api_key(api_key) |> get("/api/v1/audit?resource_type=team")
      body = json_response(conn, 200)

      names = Enum.map(body["events"], & &1["resourceName"])
      assert "TeamOne" in names
      refute "ProjOne" in names
    end

    test "respects limit and offset query params", %{conn: conn, api_key: api_key, admin: admin} do
      for i <- 1..5 do
        AuditModule.log_user(admin, "created", "project", "p#{i}", "Item #{i}")
      end

      conn = conn |> with_api_key(api_key) |> get("/api/v1/audit?limit=2&offset=1")
      body = json_response(conn, 200)

      assert body["_metadata"]["limit"] == 2
      assert body["_metadata"]["offset"] == 1
      assert length(body["events"]) <= 2
    end

    test "invalid limit/offset values fall back to defaults", %{conn: conn, api_key: api_key} do
      conn = conn |> with_api_key(api_key) |> get("/api/v1/audit?limit=abc&offset=xyz")
      body = json_response(conn, 200)
      assert body["_metadata"]["limit"] == 50
      assert body["_metadata"]["offset"] == 0
    end
  end
end

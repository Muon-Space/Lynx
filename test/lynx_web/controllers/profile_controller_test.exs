defmodule LynxWeb.ProfileControllerTest do
  use LynxWeb.ConnCase

  setup %{conn: conn} do
    api_key = install_admin_and_get_api_key(conn)
    {:ok, conn: conn, api_key: api_key}
  end

  describe "auth" do
    test "GET /api/v1/action/fetch_api_key without API key returns 403", %{conn: conn} do
      conn = get(conn, "/api/v1/action/fetch_api_key")
      assert response(conn, 403)
    end

    test "POST /api/v1/action/update_profile without API key returns 403", %{conn: conn} do
      conn = post(conn, "/api/v1/action/update_profile", %{name: "x"})
      assert response(conn, 403)
    end
  end

  describe "fetch_api_key" do
    test "returns the current user's api_key prefix (full key is unrecoverable)",
         %{conn: conn, api_key: api_key} do
      conn = conn |> with_api_key(api_key) |> get("/api/v1/action/fetch_api_key")
      body = json_response(conn, 200)
      # The full plaintext is stored hashed; the GET endpoint now only
      # returns the prefix (`apiKeyPrefix`). To get a fresh full key,
      # callers must call rotate_api_key.
      assert body["apiKey"] == nil
      assert is_binary(body["apiKeyPrefix"])
    end
  end

  describe "rotate_api_key" do
    test "rotates the api key", %{conn: conn, api_key: api_key} do
      conn = conn |> with_api_key(api_key) |> post("/api/v1/action/rotate_api_key", %{})
      body = json_response(conn, 200)
      assert is_binary(body["apiKey"])
      assert body["apiKey"] != api_key
    end
  end

  describe "update" do
    test "updates the profile name", %{conn: conn, api_key: api_key} do
      conn =
        conn
        |> with_api_key(api_key)
        |> post("/api/v1/action/update_profile", %{
          name: "Renamed",
          email: "john@example.com",
          password: ""
        })

      assert response(conn, 200)
    end
  end
end

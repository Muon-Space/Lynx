defmodule LynxWeb.SettingsControllerTest do
  use LynxWeb.ConnCase

  setup %{conn: conn} do
    api_key = install_admin_and_get_api_key(conn)
    {:ok, conn: conn, api_key: api_key}
  end

  describe "auth" do
    test "PUT /api/v1/action/update_settings without API key returns 403", %{conn: conn} do
      conn = put(conn, "/api/v1/action/update_settings", %{})
      assert response(conn, 403)
    end

    test "POST /api/v1/action/scim_token without API key returns 403", %{conn: conn} do
      conn = post(conn, "/api/v1/action/scim_token", %{})
      assert response(conn, 403)
    end
  end

  describe "update general settings" do
    test "updates app_name and app_url", %{conn: conn, api_key: api_key} do
      conn =
        conn
        |> with_api_key(api_key)
        |> put("/api/v1/action/update_settings", %{
          app_name: "Lynx Updated",
          app_url: "https://lynx.updated",
          app_email: "ops@lynx.updated"
        })

      assert response(conn, 200)
      assert Lynx.Module.SettingsModule.get_config("app_name", "") == "Lynx Updated"
    end
  end

  describe "scim_token CRUD" do
    test "lists, generates, and revokes a SCIM token", %{conn: conn, api_key: api_key} do
      # Generate
      conn =
        conn
        |> with_api_key(api_key)
        |> post("/api/v1/action/scim_token", %{name: "ci-token"})

      assert response(conn, 201)
      generated = json_response(conn, 201)
      token_uuid = generated["uuid"]

      # List
      conn = build_conn() |> with_api_key(api_key) |> get("/api/v1/action/scim_tokens")
      list_body = json_response(conn, 200)
      assert is_list(list_body["tokens"])
      assert Enum.any?(list_body["tokens"], &(&1["uuid"] == token_uuid))

      # Revoke
      conn =
        build_conn()
        |> with_api_key(api_key)
        |> delete("/api/v1/action/scim_token/#{token_uuid}")

      assert response(conn, 200)
    end
  end

  describe "saml_cert" do
    test "generates a SAML certificate", %{conn: conn, api_key: api_key} do
      conn = conn |> with_api_key(api_key) |> post("/api/v1/action/saml_cert", %{})
      assert response(conn, 200) || response(conn, 201)
    end
  end
end

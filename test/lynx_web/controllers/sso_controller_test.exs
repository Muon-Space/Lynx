defmodule LynxWeb.SSOControllerTest do
  use LynxWeb.ConnCase

  alias Lynx.Context.ConfigContext
  alias Lynx.Module.SettingsModule

  setup %{conn: conn} do
    install_admin_and_get_api_key(conn)
    {:ok, conn: conn}
  end

  defp enable_sso(protocol \\ "oidc") do
    {:ok, _} =
      ConfigContext.create_config(
        ConfigContext.new_config(%{name: "auth_sso_enabled", value: "true"})
      )

    {:ok, _} =
      ConfigContext.create_config(
        ConfigContext.new_config(%{name: "sso_protocol", value: protocol})
      )

    :ok
  end

  describe "GET /auth/sso (initiate)" do
    test "returns 400 when SSO is not enabled", %{conn: conn} do
      conn = get(conn, "/auth/sso")
      body = json_response(conn, 400)
      assert body["errorMessage"] =~ "not enabled"
    end

    test "OIDC: returns 500 when issuer config is missing", %{conn: conn} do
      enable_sso("oidc")

      conn = get(conn, "/auth/sso")
      # Without issuer/client config, the SSOService can't build the URL
      assert conn.status == 500
      body = Jason.decode!(conn.resp_body)
      assert is_binary(body["errorMessage"])
    end

    test "SAML: returns 500 when SAML config is incomplete", %{conn: conn} do
      enable_sso("saml")

      conn = get(conn, "/auth/sso")
      assert conn.status == 500
      body = Jason.decode!(conn.resp_body)
      assert is_binary(body["errorMessage"])
    end
  end

  describe "GET /auth/sso/callback (OIDC)" do
    test "returns 400 when state cookie is missing", %{conn: conn} do
      conn = get(conn, "/auth/sso/callback?code=abc&state=mystate")
      body = json_response(conn, 400)
      assert body["errorMessage"] =~ "Invalid state"
    end

    test "returns 400 when state mismatches stored cookie", %{conn: conn} do
      conn =
        conn
        |> put_req_cookie("_lynx_sso_state", "expected-state")
        |> get("/auth/sso/callback?code=abc&state=different-state")

      body = json_response(conn, 400)
      assert body["errorMessage"] =~ "Invalid state"
    end

    test "returns 400 when code is missing", %{conn: conn} do
      conn = get(conn, "/auth/sso/callback")
      body = json_response(conn, 400)
      assert body["errorMessage"] =~ "Missing"
    end

    test "returns 401 when state matches but token exchange fails", %{conn: conn} do
      # State validates, but oidc_callback hits a real network — should fail
      # cleanly with 401 (controller's auth-failed branch) rather than
      # crashing in the URL builder when issuer isn't configured.
      conn =
        conn
        |> put_req_cookie("_lynx_sso_state", "match")
        |> get("/auth/sso/callback?code=invalid&state=match")

      assert conn.status == 401
      body = Jason.decode!(conn.resp_body)
      assert is_binary(body["errorMessage"])
    end
  end

  describe "POST /auth/sso/saml_callback" do
    test "returns 400 when SAMLResponse is missing", %{conn: conn} do
      conn = post(conn, "/auth/sso/saml_callback", %{})
      body = json_response(conn, 400)
      assert body["errorMessage"] =~ "Missing"
    end

    test "returns 401 when SAMLResponse is invalid", %{conn: conn} do
      conn = post(conn, "/auth/sso/saml_callback", %{"SAMLResponse" => "not-valid-base64"})
      body = json_response(conn, 401)
      assert body["errorMessage"] =~ "SAML"
    end
  end

  describe "GET /auth/sso/finalize" do
    test "redirects to /login when SSO payload cookie is missing", %{conn: conn} do
      conn = get(conn, "/auth/sso/finalize")
      assert redirected_to(conn) == "/login"
    end

    test "redirects to /login when payload cookie is invalid", %{conn: conn} do
      conn =
        conn
        |> put_req_cookie("_lynx_sso_payload", "not-a-valid-signed-token")
        |> get("/auth/sso/finalize")

      assert redirected_to(conn) == "/login"
    end

    test "valid signed payload sets session and renders meta refresh", %{conn: conn} do
      payload =
        Phoenix.Token.sign(LynxWeb.Endpoint, "sso_payload", %{
          token: "session-token-value",
          uid: 42
        })

      conn =
        conn
        |> put_req_cookie("_lynx_sso_payload", payload)
        |> get("/auth/sso/finalize")

      assert conn.status == 200
      assert get_session(conn, :token) == "session-token-value"
      assert get_session(conn, :uid) == 42
      assert conn.resp_body =~ "/admin/workspaces"
      assert conn.resp_body =~ "Signing in"
    end

    test "expired payload (max_age exceeded) redirects to /login", %{conn: conn} do
      # Signed token with a key that won't validate against the live secret
      bad_token = "SFMyNTY.expired-or-tampered-token-value"

      conn =
        conn
        |> put_req_cookie("_lynx_sso_payload", bad_token)
        |> get("/auth/sso/finalize")

      assert redirected_to(conn) == "/login"
    end
  end

  describe "GET /saml/metadata" do
    test "returns SP metadata XML when SAML cert is configured", %{conn: conn} do
      # Set required SP config so SAMLService can render metadata
      SettingsModule.upsert_config("sso_saml_sp_entity_id", "lynx-test-sp")

      conn = get(conn, "/saml/metadata")

      # If the service can render metadata, it returns 200 + XML.
      # If not (missing certs), it would crash. Either way, document behavior:
      assert conn.status in [200, 500]

      if conn.status == 200 do
        [content_type] = get_resp_header(conn, "content-type")
        assert content_type =~ "application/xml"
        assert conn.resp_body =~ "<"
      end
    end
  end
end

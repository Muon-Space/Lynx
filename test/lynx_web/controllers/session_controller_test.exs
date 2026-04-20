defmodule LynxWeb.SessionControllerTest do
  use LynxWeb.ConnCase

  alias Lynx.Context.{ConfigContext, UserContext}
  alias Lynx.Service.AuthService

  setup %{conn: conn} do
    install_admin_and_get_api_key(conn)
    {:ok, conn: conn}
  end

  describe "POST /action/auth (login)" do
    test "valid credentials redirect to /admin/workspaces and set session", %{conn: conn} do
      conn =
        post(conn, "/action/auth", %{
          "email" => "john@example.com",
          "password" => "password123"
        })

      assert redirected_to(conn) == "/admin/workspaces"
      assert get_session(conn, :uid) != nil
      assert get_session(conn, :token) != nil
    end

    test "XHR header returns JSON success instead of redirecting", %{conn: conn} do
      conn =
        conn
        |> put_req_header("x-requested-with", "XMLHttpRequest")
        |> post("/action/auth", %{
          "email" => "john@example.com",
          "password" => "password123"
        })

      body = json_response(conn, 200)
      assert body["successMessage"] =~ "logged in"
    end

    test "wrong password returns 400 with error message", %{conn: conn} do
      conn =
        post(conn, "/action/auth", %{
          "email" => "john@example.com",
          "password" => "wrongpassword"
        })

      body = json_response(conn, 400)
      assert body["errorMessage"] =~ "Invalid"
    end

    test "unknown email returns 400", %{conn: conn} do
      conn =
        post(conn, "/action/auth", %{
          "email" => "nobody@example.com",
          "password" => "password123"
        })

      body = json_response(conn, 400)
      assert body["errorMessage"] =~ "Invalid"
    end

    test "missing password returns 400", %{conn: conn} do
      conn = post(conn, "/action/auth", %{"email" => "john@example.com"})
      body = json_response(conn, 400)
      assert body["errorMessage"] =~ "Invalid"
    end

    test "invalid email format returns 400", %{conn: conn} do
      conn =
        post(conn, "/action/auth", %{
          "email" => "not-an-email",
          "password" => "password123"
        })

      body = json_response(conn, 400)
      assert body["errorMessage"] =~ "Invalid"
    end

    test "returns 400 when password auth is disabled", %{conn: conn} do
      {:ok, _} =
        ConfigContext.create_config(
          ConfigContext.new_config(%{name: "auth_password_enabled", value: "false"})
        )

      conn =
        post(conn, "/action/auth", %{
          "email" => "john@example.com",
          "password" => "password123"
        })

      assert response(conn, 400) =~ "disabled"
    end
  end

  describe "GET /logout" do
    test "clears session and redirects to /", %{conn: conn} do
      # Establish a session first by logging in
      user = UserContext.get_user_by_email("john@example.com")
      {:success, session} = AuthService.authenticate(user.id)

      conn =
        conn
        |> Plug.Test.init_test_session(%{})
        |> put_session(:uid, user.id)
        |> put_session(:token, session.value)
        |> get("/logout")

      assert redirected_to(conn) == "/"
      assert get_session(conn, :uid) == nil
      assert get_session(conn, :token) == nil
    end

    test "anonymous logout still redirects without crashing", %{conn: conn} do
      conn = get(conn, "/logout")
      assert redirected_to(conn) == "/"
    end
  end
end

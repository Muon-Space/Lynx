defmodule LynxWeb.LoginLiveTest do
  use LynxWeb.LiveCase

  describe "mount" do
    test "redirects to /install when app is not installed", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/install"}}} = live(conn, "/login")
    end

    test "renders sign-in form for unauthenticated user", %{conn: conn} do
      mark_installed()
      {:ok, _view, html} = live(conn, "/login")

      assert html =~ "Sign in"
      assert html =~ ~s(action="/action/auth")
      assert html =~ ~s(name="email")
      assert html =~ ~s(name="password")
    end

    test "redirects authenticated user to /admin/workspaces (canonical landing)", %{conn: conn} do
      # `/admin/projects` (no uuid) is not a route — only `/admin/projects/:uuid`
      # exists. Redirecting there 404s the user out of the app, so the
      # post-login landing is the workspaces list instead.
      mark_installed()
      user = create_user()
      conn = log_in_user(conn, user)

      assert {:error, {:redirect, %{to: "/admin/workspaces"}}} = live(conn, "/login")
    end

    test "shows SSO button when SSO is enabled", %{conn: conn} do
      mark_installed()
      set_config("auth_sso_enabled", "true")
      set_config("sso_login_label", "Acme SSO")

      {:ok, _view, html} = live(conn, "/login")

      assert html =~ ~s(href="/auth/sso")
      assert html =~ "Acme SSO"
    end

    test "hides password form when password auth is disabled", %{conn: conn} do
      mark_installed()
      set_config("auth_sso_enabled", "true")
      set_config("auth_password_enabled", "false")

      {:ok, _view, html} = live(conn, "/login")

      refute html =~ ~s(action="/action/auth")
      assert html =~ ~s(href="/auth/sso")
    end
  end
end

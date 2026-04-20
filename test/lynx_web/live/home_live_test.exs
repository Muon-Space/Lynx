defmodule LynxWeb.HomeLiveTest do
  use LynxWeb.LiveCase

  describe "mount" do
    test "redirects to /install when app is not installed", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/install"}}} = live(conn, "/")
    end

    test "redirects to /login when installed but not authenticated", %{conn: conn} do
      mark_installed()
      assert {:error, {:redirect, %{to: "/login"}}} = live(conn, "/")
    end

    test "redirects authenticated user to /admin/workspaces", %{conn: conn} do
      mark_installed()
      user = create_user()
      conn = log_in_user(conn, user)

      assert {:error, {:redirect, %{to: "/admin/workspaces"}}} = live(conn, "/")
    end
  end
end

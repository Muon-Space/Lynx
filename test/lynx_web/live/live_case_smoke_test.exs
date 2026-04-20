defmodule LynxWeb.LiveCaseSmokeTest do
  use LynxWeb.LiveCase

  describe "log_in_user/2" do
    test "anonymous request to authed page redirects to /login", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/login"}}} = live(conn, "/admin/profile")
    end

    test "authed request to authed page mounts", %{conn: conn} do
      user = create_user()
      conn = log_in_user(conn, user)

      {:ok, _view, html} = live(conn, "/admin/profile")
      assert html =~ user.name
    end

    test "non-super user cannot reach super-only page", %{conn: conn} do
      user = create_user()
      conn = log_in_user(conn, user)

      {:ok, _view, html} = live(conn, "/admin/workspaces")
      refute html =~ "Audit Log"
    end

    test "super user sees super-only nav links", %{conn: conn} do
      user = create_super()
      conn = log_in_user(conn, user)

      {:ok, _view, html} = live(conn, "/admin/workspaces")
      assert html =~ "Audit Log"
      assert html =~ "Settings"
    end
  end

  describe "disconnected vs connected mount" do
    # Phoenix LiveView mounts twice: first via HTTP GET (disconnected, used
    # by SEO/initial paint), then via WebSocket (connected, where the LV
    # process actually runs). `live/2` exercises both. These tests prove
    # both paths work and let us assert on each independently.
    test "disconnected mount renders user-visible content via plain HTTP GET",
         %{conn: conn} do
      user = create_user(%{name: "Disconnected User"})
      conn = log_in_user(conn, user) |> get("/admin/profile")

      assert html_response(conn, 200) =~ "Disconnected User"
      # The page MUST render its primary content server-side, not wait for
      # the socket — otherwise SEO + first-paint break.
      assert html_response(conn, 200) =~ "Profile"
    end

    test "connected mount succeeds after disconnected GET", %{conn: conn} do
      user = create_user(%{name: "Connected User"})
      conn = log_in_user(conn, user) |> get("/admin/profile")

      # `live/1` (no path) takes the conn from the previous GET and upgrades
      # it to a connected LV process. If the LV crashes during connected
      # mount, this fails even though the disconnected GET succeeded.
      {:ok, view, _html} = live(conn)
      assert has_element?(view, "code#api-key-content")
    end
  end
end

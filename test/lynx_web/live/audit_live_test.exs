defmodule LynxWeb.AuditLiveTest do
  use LynxWeb.LiveCase

  alias Lynx.Context.AuditContext

  setup %{conn: conn} do
    user = create_super()
    {:ok, conn: log_in_user(conn, user), user: user}
  end

  describe "mount" do
    test "renders Audit Log title", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin/audit")
      assert html =~ "Audit Log"
    end

    test "non-super user is redirected to /login", %{conn: conn} do
      regular = create_user()
      conn = log_in_user(conn, regular)

      assert {:error, {:redirect, %{to: "/login"}}} = live(conn, "/admin/audit")
    end

    test "lists existing audit events", %{conn: conn, user: user} do
      AuditContext.log_user(user, "created", "project", "p-uuid", "Cool Project")

      {:ok, _view, html} = live(conn, "/admin/audit")
      assert html =~ "Cool Project"
      assert html =~ "created"
      assert html =~ "project"
    end
  end

  describe "filter event" do
    test "filters by action", %{conn: conn, user: user} do
      AuditContext.log_user(user, "created", "project", "p1", "Will Match")
      AuditContext.log_user(user, "deleted", "project", "p2", "Wont Match")

      {:ok, view, _} = live(conn, "/admin/audit")

      # Sanity: both visible before filter
      assert render(view) =~ "Will Match"
      assert render(view) =~ "Wont Match"

      render_change(view, "filter", %{"action" => "created", "resource_type" => ""})

      html = render(view)
      assert html =~ "Will Match"
      refute html =~ "Wont Match"
    end

    test "filters by resource type", %{conn: conn, user: user} do
      AuditContext.log_user(user, "created", "project", "p1", "ProjectMatch")
      AuditContext.log_user(user, "created", "team", "t1", "TeamMatch")

      {:ok, view, _} = live(conn, "/admin/audit")
      render_change(view, "filter", %{"action" => "", "resource_type" => "team"})

      html = render(view)
      assert html =~ "TeamMatch"
      refute html =~ "ProjectMatch"
    end

    test "empty filter values show all events", %{conn: conn, user: user} do
      AuditContext.log_user(user, "created", "project", "p1", "Event A")

      {:ok, view, _} = live(conn, "/admin/audit")
      render_change(view, "filter", %{"action" => "", "resource_type" => ""})

      assert render(view) =~ "Event A"
    end
  end
end

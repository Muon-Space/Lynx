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

  defp count_events(html) do
    # Streamed rows live under `<tbody id="audit-events">`; each row is a `<tr id="events-N">`.
    {:ok, doc} = Floki.parse_fragment(html)
    doc |> Floki.find("tbody#audit-events > tr") |> length()
  end

  describe "stream + load_more" do
    test "renders the events stream container", %{conn: conn, user: user} do
      AuditContext.log_user(user, "created", "project", "p-uuid", "Streamed Event")

      {:ok, _view, html} = live(conn, "/admin/audit")
      # Stream-mode container is `phx-update="stream"` on `id=audit-events`.
      assert html =~ ~s(id="audit-events")
      assert html =~ ~s(phx-update="stream")
      assert html =~ "Streamed Event"
    end

    test "Load more button hidden when total fits in one page", %{conn: conn, user: user} do
      AuditContext.log_user(user, "created", "project", "p", "Single")

      {:ok, _view, html} = live(conn, "/admin/audit")
      refute html =~ "Load more"
    end

    test "Load more button shown and load_more appends events", %{conn: conn, user: user} do
      # @per_page is 50; insert 60 events so a second page exists.
      for i <- 1..60 do
        AuditContext.log_user(user, "created", "project", "p#{i}", "Event #{i}")
      end

      {:ok, view, html} = live(conn, "/admin/audit")
      first_count = count_events(html)
      assert first_count == 50
      assert html =~ "Load more"

      render_click(view, "load_more", %{})
      html2 = render(view)

      assert count_events(html2) == 60
      # has_more? toggles off once everything's loaded.
      refute html2 =~ "Load more"
    end

    test "filter resets the stream to the matching set", %{conn: conn, user: user} do
      AuditContext.log_user(user, "created", "project", "p", "KeepMe")
      AuditContext.log_user(user, "deleted", "project", "p2", "DropMe")

      {:ok, view, _} = live(conn, "/admin/audit")

      render_change(view, "filter", %{"action" => "created", "resource_type" => ""})
      html = render(view)

      assert html =~ "KeepMe"
      refute html =~ "DropMe"
    end
  end
end

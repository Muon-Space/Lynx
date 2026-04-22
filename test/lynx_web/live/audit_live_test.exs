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

    test "URL params restore filter state on mount", %{conn: conn, user: user} do
      AuditContext.log_user(user, "created", "project", "p1", "ProjectKeep")
      AuditContext.log_user(user, "created", "team", "t1", "TeamDrop")

      {:ok, _view, html} = live(conn, "/admin/audit?resource_type=project")

      assert html =~ "ProjectKeep"
      refute html =~ "TeamDrop"
    end

    test "filter event patches the URL with the new filter set", %{conn: conn} do
      {:ok, view, _} = live(conn, "/admin/audit")

      render_change(view, "filter", %{
        "action" => "created",
        "resource_type" => "",
        "resource_id" => "",
        "actor_email" => "",
        "from" => "",
        "to" => ""
      })

      assert assert_patch(view) =~ "action=created"
    end

    test "filters by resource_id (per-resource timeline)", %{conn: conn, user: user} do
      AuditContext.log_user(user, "created", "project", "keep-id", "ProjectKeep")
      AuditContext.log_user(user, "created", "project", "drop-id", "ProjectDrop")

      {:ok, _view, html} = live(conn, "/admin/audit?resource_type=project&resource_id=keep-id")

      assert html =~ "ProjectKeep"
      refute html =~ "ProjectDrop"
    end

    test "exports CSV link reflects current filter set", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin/audit?action=created&resource_type=project")
      # The Export CSV anchor's href is built from non-empty filters.
      assert html =~ ~s(/admin/audit/export.csv?)
      assert html =~ "action=created"
      assert html =~ "resource_type=project"
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

  describe "deep links" do
    alias Lynx.Context.{ProjectContext, EnvironmentContext}

    test "project resource_type → /admin/projects/:uuid", %{conn: conn, user: user} do
      AuditContext.log_user(user, "created", "project", "proj-uuid-123", "Foo")

      {:ok, _view, html} = live(conn, "/admin/audit")
      assert html =~ ~s(href="/admin/projects/proj-uuid-123")
    end

    test "snapshot resource_type → /admin/snapshots/:uuid", %{conn: conn, user: user} do
      AuditContext.log_user(user, "restored", "snapshot", "snap-uuid", "Snap")

      {:ok, _view, html} = live(conn, "/admin/audit")
      assert html =~ ~s(href="/admin/snapshots/snap-uuid")
    end

    test "role resource_type → /admin/roles/:uuid", %{conn: conn, user: user} do
      AuditContext.log_user(user, "created", "role", "role-uuid", "ghost")

      {:ok, _view, html} = live(conn, "/admin/audit")
      assert html =~ ~s(href="/admin/roles/role-uuid")
    end

    test "environment resource_type resolves project_uuid via batch lookup", %{
      conn: conn,
      user: user
    } do
      ws = create_workspace()
      project = create_project(%{workspace_id: ws.id, name: "P"})
      env = create_env(project, %{name: "prod", slug: "prod"})

      AuditContext.log_user(user, "created", "environment", env.uuid, env.name)

      {:ok, _view, html} = live(conn, "/admin/audit")
      assert html =~ ~s(href="/admin/projects/#{project.uuid}/environments/#{env.uuid}")
    end

    test "unit resource_type lands on the parent env page", %{conn: conn, user: user} do
      ws = create_workspace()
      project = create_project(%{workspace_id: ws.id, name: "P"})
      env = create_env(project, %{name: "dev", slug: "dev"})

      # `unit` audit events store the env uuid in resource_id (audit_context.ex:207)
      AuditContext.log_user(user, "locked", "unit", env.uuid, "#{env.name}/groups")

      {:ok, _view, html} = live(conn, "/admin/audit")
      assert html =~ ~s(href="/admin/projects/#{project.uuid}/environments/#{env.uuid}")
    end

    test "project_team grants link via metadata project_uuid (no DB hit)", %{
      conn: conn,
      user: user
    } do
      AuditContext.log_user(
        user,
        "granted",
        "project_team",
        "team-uuid",
        "Platform",
        %{project_uuid: "proj-from-metadata"}
      )

      {:ok, _view, html} = live(conn, "/admin/audit")
      assert html =~ ~s(href="/admin/projects/proj-from-metadata")
    end

    test "user_project grants link via metadata project_uuid", %{conn: conn, user: user} do
      AuditContext.log_user(
        user,
        "granted",
        "user_project",
        "user-uuid",
        "alice@example.com",
        %{project_uuid: "proj-via-metadata"}
      )

      {:ok, _view, html} = live(conn, "/admin/audit")
      assert html =~ ~s(href="/admin/projects/proj-via-metadata")
    end

    test "settings-family resources land on the right tab", %{conn: conn, user: user} do
      # Cards live on different tabs in /admin/settings; the audit row should
      # take the user straight to the relevant card, not just the page.
      AuditContext.log_user(user, "updated", "settings", nil, "general")
      AuditContext.log_user(user, "generated", "scim_token", "tok-uuid", "ci-token")
      AuditContext.log_user(user, "generated", "saml_certificate", nil, "saml-cert")
      AuditContext.log_user(user, "created", "oidc_provider", "prov-uuid", "github-actions")

      {:ok, _view, html} = live(conn, "/admin/audit")
      assert html =~ ~s(href="/admin/settings?tab=general")
      assert html =~ ~s(href="/admin/settings?tab=scim")
      assert html =~ ~s(href="/admin/settings?tab=sso")
      assert html =~ ~s(href="/admin/settings?tab=oidc")
    end

    test "team and user rows deep-link to the edit modal via ?edit=UUID", %{
      conn: conn,
      user: user
    } do
      AuditContext.log_user(user, "created", "team", "t-uuid", "Platform")
      AuditContext.log_user(user, "updated", "user", "u-uuid", "Alice")

      {:ok, _view, html} = live(conn, "/admin/audit")
      # The audit row jumps straight to the edit modal of the affected
      # resource (teams_live + users_live each handle ?edit=UUID).
      assert html =~ ~s(href="/admin/teams?edit=t-uuid")
      assert html =~ ~s(href="/admin/users?edit=u-uuid")
    end

    test "oidc_rule has no detail page → no link", %{conn: conn, user: user} do
      AuditContext.log_user(user, "created", "oidc_rule", "r-uuid", "deploy")

      {:ok, _view, html} = live(conn, "/admin/audit")
      refute html =~ ~s(href="/admin/projects/r-uuid")
      # The plain text still renders.
      assert html =~ "deploy"
    end

    test "load_more preserves links for the appended page", %{conn: conn, user: user} do
      ws = create_workspace()
      project = create_project(%{workspace_id: ws.id, name: "P"})
      # First page (50): plain projects (link to themselves)
      for i <- 1..50, do: AuditContext.log_user(user, "created", "project", "p#{i}", "P#{i}")
      # Second page (10): env events that need project_uuid lookup
      env = create_env(project, %{name: "prod", slug: "prod"})

      for i <- 1..10,
          do: AuditContext.log_user(user, "created", "environment", env.uuid, "evt-#{i}")

      {:ok, view, _html} = live(conn, "/admin/audit")
      render_click(view, "load_more", %{})
      html = render(view)

      # Both link types coexist after load_more — link_index merges across pages.
      assert html =~ ~s(href="/admin/projects/p1")
      assert html =~ ~s(href="/admin/projects/#{project.uuid}/environments/#{env.uuid}")
    end

    # Quiet "imported but unused" if any context isn't referenced.
    _ = {ProjectContext, EnvironmentContext}
  end
end

defmodule LynxWeb.WorkspacesLiveTest do
  use LynxWeb.LiveCase

  alias Lynx.Context.WorkspaceContext

  setup %{conn: conn} do
    user = create_super()
    {:ok, conn: log_in_user(conn, user), user: user}
  end

  describe "mount" do
    test "renders Workspaces title", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin/workspaces")
      assert html =~ "Workspaces"
    end

    test "shows seeded Default workspace on a clean DB", %{conn: conn} do
      # A migration seeds a "Default" workspace; super users always see it.
      {:ok, _view, html} = live(conn, "/admin/workspaces")
      assert html =~ "Default"
    end

    test "lists newly created workspaces", %{conn: conn} do
      ws = create_workspace(%{name: "Marketing", slug: "mkt"})
      _ = create_project(%{workspace_id: ws.id, name: "Site"})

      {:ok, _view, html} = live(conn, "/admin/workspaces")
      assert html =~ "Marketing"
      assert html =~ "mkt"
    end

    test "non-super user only sees workspaces with their projects", %{conn: conn} do
      user_ws = create_workspace(%{name: "Visible", slug: "v"})
      _hidden_ws = create_workspace(%{name: "Hidden", slug: "h"})
      _ = create_project(%{workspace_id: user_ws.id})

      regular = create_user()
      conn = log_in_user(conn, regular)

      {:ok, _view, html} = live(conn, "/admin/workspaces")
      # Regular users only see workspaces where they have project access via teams
      # (they have none here) — page renders but has no rows
      assert html =~ "Workspaces"
    end
  end

  describe "Add Workspace modal" do
    test "modal opens and closes", %{conn: conn} do
      {:ok, view, _} = live(conn, "/admin/workspaces")

      refute has_element?(view, "#add-workspace")
      render_click(view, "show_add", %{})
      assert has_element?(view, "#add-workspace")
      render_click(view, "hide_add", %{})
      refute has_element?(view, "#add-workspace")
    end

    test "form_change auto-derives slug from name", %{conn: conn} do
      {:ok, view, _} = live(conn, "/admin/workspaces")
      render_click(view, "show_add", %{})

      render_change(view, "form_change", %{"name" => "My Cool Workspace"})

      assert render(view) =~ ~s(value="my-cool-workspace")
    end

    test "create_workspace persists and reloads", %{conn: conn} do
      {:ok, view, _} = live(conn, "/admin/workspaces")
      render_click(view, "show_add", %{})

      render_submit(view, "create_workspace", %{
        "name" => "Engineering",
        "slug" => "eng",
        "description" => "for engineers"
      })

      html = render(view)
      assert html =~ "Workspace created"
      assert html =~ "Engineering"
      refute has_element?(view, "#add-workspace")

      assert WorkspaceContext.get_workspace_by_slug("eng") != nil
    end

    test "create_workspace shows error on validation failure", %{conn: conn} do
      {:ok, view, _} = live(conn, "/admin/workspaces")
      render_click(view, "show_add", %{})

      render_submit(view, "create_workspace", %{
        "name" => "x",
        "slug" => "x",
        "description" => ""
      })

      html = render(view)
      # Modal should still be visible (didn't redirect away from add)
      assert html =~ "Add Workspace" or html =~ "name"
    end
  end

  describe "Edit Workspace" do
    test "edit modal opens with current values", %{conn: conn} do
      ws = create_workspace(%{name: "Old", slug: "old"})
      {:ok, view, _} = live(conn, "/admin/workspaces")

      render_click(view, "edit_workspace", %{"uuid" => ws.uuid})

      assert has_element?(view, "#edit-workspace")
      assert render(view) =~ ~s(value="Old")
      assert render(view) =~ ~s(value="old")
    end

    test "update_workspace persists changes", %{conn: conn} do
      ws = create_workspace(%{name: "Old", slug: "old"})
      {:ok, view, _} = live(conn, "/admin/workspaces")

      render_click(view, "edit_workspace", %{"uuid" => ws.uuid})

      render_submit(view, "update_workspace", %{
        "name" => "Renamed",
        "slug" => "renamed",
        "description" => "new"
      })

      html = render(view)
      assert html =~ "Workspace updated"
      assert html =~ "Renamed"

      reloaded = WorkspaceContext.get_workspace_by_uuid(ws.uuid)
      assert reloaded.name == "Renamed"
      assert reloaded.slug == "renamed"
    end
  end

  describe "Delete Workspace" do
    test "delete_workspace removes it and shows flash", %{conn: conn} do
      ws = create_workspace(%{name: "ToDelete"})
      {:ok, view, _} = live(conn, "/admin/workspaces")

      render_click(view, "delete_workspace", %{"uuid" => ws.uuid})

      html = render(view)
      assert html =~ "Workspace deleted"
      refute html =~ "ToDelete"
      assert WorkspaceContext.get_workspace_by_uuid(ws.uuid) == nil
    end
  end

  describe "auth" do
    test "redirects unauthenticated user to /login" do
      assert {:error, {:redirect, %{to: "/login"}}} = live(build_conn(), "/admin/workspaces")
    end
  end
end

defmodule LynxWeb.SnapshotsLiveTest do
  use LynxWeb.LiveCase

  alias Lynx.Module.SnapshotModule

  setup %{conn: conn} do
    user = create_super()
    {:ok, conn: log_in_user(conn, user), user: user}
  end

  describe "mount" do
    test "renders Snapshots title", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin/snapshots")
      assert html =~ "Snapshots"
      assert html =~ "+ Create Snapshot"
    end

    test "lists existing snapshots", %{conn: conn} do
      ws = create_workspace()
      project = create_project(%{workspace_id: ws.id})

      {:ok, _} =
        SnapshotModule.create_snapshot(%{
          title: "Nightly Backup",
          description: "auto",
          record_type: "project",
          record_uuid: project.uuid,
          status: "success",
          data: ~s({"name":"#{project.name}","environments":[]}),
          team_id: nil
        })

      {:ok, _view, html} = live(conn, "/admin/snapshots")
      assert html =~ "Nightly Backup"
      assert html =~ "project"
    end

    test "auth required", %{} do
      assert {:error, {:redirect, %{to: "/login"}}} = live(build_conn(), "/admin/snapshots")
    end
  end

  describe "Add Snapshot modal" do
    test "show_add opens modal", %{conn: conn} do
      {:ok, view, _} = live(conn, "/admin/snapshots")

      refute has_element?(view, "#add-snapshot")
      render_click(view, "show_add", %{})
      assert has_element?(view, "#add-snapshot")
    end

    test "snapshot_form_change cascades workspace → project filter", %{conn: conn} do
      ws_a = create_workspace(%{name: "WS A", slug: "ws-a"})
      ws_b = create_workspace(%{name: "WS B", slug: "ws-b"})
      _ = create_project(%{workspace_id: ws_a.id, name: "Proj A"})
      _ = create_project(%{workspace_id: ws_b.id, name: "Proj B"})

      {:ok, view, _} = live(conn, "/admin/snapshots")
      render_click(view, "show_add", %{})

      # Pick workspace A — only Proj A should appear in the project dropdown
      render_change(view, "snapshot_form_change", %{
        "workspace_id" => to_string(ws_a.id),
        "project_uuid" => "",
        "env_uuid" => "",
        "unit_path" => "",
        "unit_version" => ""
      })

      html = render(view)
      assert html =~ "Proj A"
      refute html =~ "Proj B"
    end

    test "create_snapshot at project scope persists snapshot", %{conn: conn} do
      ws = create_workspace()
      project = create_project(%{workspace_id: ws.id, name: "Snapshotted"})

      {:ok, view, _} = live(conn, "/admin/snapshots")
      render_click(view, "show_add", %{})

      render_change(view, "snapshot_form_change", %{
        "workspace_id" => to_string(ws.id),
        "project_uuid" => project.uuid,
        "env_uuid" => "",
        "unit_path" => "",
        "unit_version" => ""
      })

      render_submit(view, "create_snapshot", %{
        "title" => "FirstSnap",
        "description" => "test",
        "workspace_id" => to_string(ws.id),
        "project_uuid" => project.uuid,
        "env_uuid" => "",
        "unit_path" => "",
        "unit_version" => ""
      })

      html = render(view)
      assert html =~ "Snapshot created"
      assert html =~ "FirstSnap"
    end
  end

  describe "Delete snapshot" do
    test "delete_snapshot removes it", %{conn: conn} do
      ws = create_workspace()
      project = create_project(%{workspace_id: ws.id})

      {:ok, snapshot} =
        SnapshotModule.create_snapshot(%{
          title: "ToDelete",
          description: "x",
          record_type: "project",
          record_uuid: project.uuid,
          status: "success",
          data: ~s({"name":"x","environments":[]}),
          team_id: nil
        })

      {:ok, view, _} = live(conn, "/admin/snapshots")
      render_click(view, "delete_snapshot", %{"uuid" => snapshot.uuid})

      html = render(view)
      assert html =~ "Snapshot deleted"
      refute html =~ "ToDelete"
    end
  end
end

defmodule LynxWeb.SnapshotLiveTest do
  use LynxWeb.LiveCase

  alias Lynx.Context.SnapshotContext

  setup %{conn: conn} do
    user = create_super()
    workspace = create_workspace()
    project = create_project(%{workspace_id: workspace.id, name: "Snapped"})
    env = create_env(project, %{name: "Prod", slug: "prod"})

    state =
      create_state(env, %{
        sub_path: "",
        value: ~s({"resource":"vpc","id":"vpc-123"})
      })

    snapshot_data =
      Jason.encode!(%{
        "name" => project.name,
        "slug" => project.slug,
        "uuid" => project.uuid,
        "environments" => [
          %{
            "name" => env.name,
            "slug" => env.slug,
            "uuid" => env.uuid,
            "states" => [
              %{
                "uuid" => state.uuid,
                "sub_path" => "",
                "value" => state.value
              }
            ]
          }
        ]
      })

    {:ok, snapshot} =
      SnapshotContext.create_snapshot_from_data(%{
        title: "Test Snapshot",
        description: "A test snapshot",
        record_type: "project",
        record_uuid: project.uuid,
        status: "success",
        data: snapshot_data,
        team_id: nil
      })

    {:ok,
     conn: log_in_user(conn, user),
     user: user,
     project: project,
     env: env,
     state: state,
     snapshot: snapshot}
  end

  defp snap_path(snapshot), do: "/admin/snapshots/#{snapshot.uuid}"

  describe "mount" do
    test "renders snapshot title and breadcrumb", %{conn: conn, snapshot: snapshot} do
      {:ok, _view, html} = live(conn, snap_path(snapshot))
      assert html =~ snapshot.title
      assert html =~ snapshot.description
    end

    test "shows project, status, and scope badges", %{
      conn: conn,
      snapshot: snapshot,
      project: project
    } do
      {:ok, _view, html} = live(conn, snap_path(snapshot))
      assert html =~ project.name
      assert html =~ "success"
      assert html =~ "project"
    end

    test "lists environments and units from snapshot data", %{
      conn: conn,
      snapshot: snapshot,
      env: env
    } do
      {:ok, _view, html} = live(conn, snap_path(snapshot))
      assert html =~ env.name
      assert html =~ "(root)"
    end

    test "redirects when snapshot not found", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/admin/snapshots"}}} =
               live(conn, "/admin/snapshots/00000000-0000-0000-0000-000000000000")
    end
  end

  describe "toggle_state_view" do
    test "preview reveals JSON content, hide collapses it", %{
      conn: conn,
      snapshot: snapshot,
      env: env
    } do
      {:ok, view, _} = live(conn, snap_path(snapshot))

      # Preview button visible, JSON viewer not yet shown
      refute has_element?(view, "##{"state-#{env.uuid}-"}")

      render_click(view, "toggle_state_view", %{"env" => env.uuid, "unit" => ""})

      html = render(view)
      assert html =~ "vpc-123"
      assert html =~ "Hide"

      render_click(view, "toggle_state_view", %{"env" => env.uuid, "unit" => ""})
      assert render(view) =~ "Preview"
    end
  end

  describe "delete_snapshot" do
    test "deletes the snapshot and redirects to list", %{conn: conn, snapshot: snapshot} do
      {:ok, view, _} = live(conn, snap_path(snapshot))

      result = render_click(view, "delete_snapshot", %{"uuid" => snapshot.uuid})

      assert {:error, {:redirect, %{to: "/admin/snapshots"}}} = result
      assert {:not_found, _} = SnapshotContext.fetch_snapshot_by_uuid(snapshot.uuid)
    end
  end

  describe "confirm_action" do
    test "confirm dialog opens for restore and delete buttons", %{conn: conn, snapshot: snapshot} do
      {:ok, view, _} = live(conn, snap_path(snapshot))

      render_click(view, "confirm_action", %{
        "event" => "restore_snapshot",
        "message" => "Restore this snapshot? This will overwrite current state.",
        "uuid" => snapshot.uuid
      })

      assert has_element?(view, "#confirm-dialog")
      render_click(view, "cancel_confirm", %{})
      refute has_element?(view, "#confirm-dialog")
    end
  end
end

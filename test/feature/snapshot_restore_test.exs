defmodule LynxWeb.Feature.SnapshotRestoreTest do
  @moduledoc """
  Restoring a snapshot is a destructive multi-step interaction:
  Restore → confirm dialog (CSS-fixed overlay with focus management) →
  Confirm → server action → flash. The whole interaction (modal lifecycle
  plus the click chain) is a place where small CSS / DOM changes can
  silently break the destructive path. Pin it.
  """
  use LynxWeb.FeatureCase, async: false

  alias Lynx.Context.SnapshotContext

  setup do
    mark_installed()
    user = create_super()
    workspace = create_workspace()
    project = create_project(%{workspace_id: workspace.id, name: "Snapped"})

    {:ok, snapshot} =
      SnapshotContext.create_snapshot_from_data(%{
        title: "v1 baseline",
        description: "before risky change",
        record_type: "project",
        record_uuid: project.uuid,
        status: "success",
        # `restore_snapshot/1` iterates `data["environments"]` — empty list
        # is a no-op restore that still exercises the full handler path.
        data: Jason.encode!(%{"environments" => []})
      })

    %{user: user, snapshot: snapshot}
  end

  test "Restore opens confirm dialog; Confirm fires the restore handler", %{
    conn: conn,
    user: user,
    snapshot: snapshot
  } do
    # Drive on the detail page (`/admin/snapshots/:uuid`). The list page's
    # rows have `phx-click={JS.navigate(...)}` on the cells, which is a
    # different (well-tested) interaction; the restore *destructive flow*
    # is the actual feature under test and lives identically on both pages.
    conn
    |> add_lynx_session(user)
    |> visit("/admin/snapshots/#{snapshot.uuid}")
    |> assert_has("body", text: "v1 baseline")
    |> click_button("Restore")
    # `#confirm-dialog` itself is `position: relative` with zero dimensions
    # (the visible content sits in fixed-positioned children); Playwright's
    # `assert_has` filters out non-visible elements so assert on the
    # rendered text instead of the wrapper id.
    |> assert_has("h3", text: "Are you sure?")
    |> click_button("Confirm")
    |> assert_has("body", text: "Snapshot restored successfully")
  end
end

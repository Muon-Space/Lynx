defmodule LynxWeb.StateExplorerLiveTest do
  use LynxWeb.LiveCase

  alias Lynx.Context.LockContext

  setup %{conn: conn} do
    user = create_user()
    workspace = create_workspace()
    project = create_project(%{workspace_id: workspace.id})
    env = create_env(project)

    s1 = create_state(env, %{value: ~s({"v":1})})
    s2 = create_state(env, %{value: ~s({"v":2})})
    s3 = create_state(env, %{value: ~s({"v":3})})

    {:ok,
     conn: log_in_user(conn, user),
     user: user,
     workspace: workspace,
     project: project,
     env: env,
     states: [s1, s2, s3]}
  end

  defp explorer_path(project, env, sub_path \\ nil) do
    base = "/admin/projects/#{project.uuid}/environments/#{env.uuid}/state"
    if sub_path, do: "#{base}/#{sub_path}", else: base
  end

  # Extract the JSON shown in a state viewer pane and decode it.
  # Returns the decoded value (a map) so tests can assert on logical content
  # rather than HTML-escaped strings.
  defp viewer_state(view, version) do
    view
    |> render()
    |> Floki.parse_document!()
    |> Floki.find("#state-viewer-#{version}, #state-left-#{version}, #state-right-#{version}")
    |> Floki.text()
    |> case do
      "" -> nil
      json -> Jason.decode!(json)
    end
  end

  describe "mount" do
    test "renders breadcrumb and selects latest version by default", %{
      conn: conn,
      project: project,
      env: env
    } do
      {:ok, view, html} = live(conn, explorer_path(project, env))

      assert html =~ project.name
      assert html =~ env.name
      assert html =~ "(root)"
      assert html =~ "(Current)"
      # Default selected version is the latest (v3)
      assert viewer_state(view, 3) == %{"v" => 3}
    end

    test "redirects when project not found", %{conn: conn, env: env} do
      assert {:ok, conn} =
               live(
                 conn,
                 "/admin/projects/00000000-0000-0000-0000-000000000000/environments/#{env.uuid}/state"
               )
               |> follow_redirect(conn, "/admin/workspaces")

      assert conn.request_path == "/admin/workspaces"
    end

    test "redirects when env not found", %{conn: conn, project: project} do
      target = "/admin/projects/#{project.uuid}"

      assert {:ok, conn} =
               live(
                 conn,
                 "/admin/projects/#{project.uuid}/environments/00000000-0000-0000-0000-000000000000/state"
               )
               |> follow_redirect(conn, target)

      assert conn.request_path == target
    end

    test "lock badge shows Unlocked when no active lock", %{
      conn: conn,
      project: project,
      env: env
    } do
      {:ok, _view, html} = live(conn, explorer_path(project, env))
      assert html =~ "Unit Unlocked"
      refute html =~ "Unit Locked"
    end

    test "lock badge shows Locked when active lock exists", %{
      conn: conn,
      project: project,
      env: env
    } do
      create_lock(env, %{sub_path: ""})
      {:ok, _view, html} = live(conn, explorer_path(project, env))
      assert html =~ "Unit Locked"
      refute html =~ "Unit Unlocked"
    end
  end

  describe "version_change event" do
    # Note: the select uses CustomSelect (phx-update="ignore"), so form()
    # validation rejects values not in the rendered options. We push the
    # event directly instead.
    test "selecting an older version shows that version's decoded JSON", %{
      conn: conn,
      project: project,
      env: env
    } do
      {:ok, view, _} = live(conn, explorer_path(project, env))

      render_change(view, "version_change", %{"version" => "1", "compare" => ""})

      assert viewer_state(view, 1) == %{"v" => 1}
    end

    test "compare with shows two panes and diff container id", %{
      conn: conn,
      project: project,
      env: env
    } do
      {:ok, view, _} = live(conn, explorer_path(project, env))

      render_change(view, "version_change", %{"version" => "3", "compare" => "1"})

      assert has_element?(view, "#diff-3-1")
      assert viewer_state(view, 3) == %{"v" => 3}
      assert viewer_state(view, 1) == %{"v" => 1}
    end

    test "compare equal to selected hides diff and shows single pane", %{
      conn: conn,
      project: project,
      env: env
    } do
      {:ok, view, _} = live(conn, explorer_path(project, env))

      render_change(view, "version_change", %{"version" => "2", "compare" => "2"})

      refute has_element?(view, "[id^=\"diff-\"]")
      assert viewer_state(view, 2) == %{"v" => 2}
    end
  end

  describe "snapshot query param" do
    test "?snapshot=<uuid> selects matching version and shows Snapshot label", %{
      conn: conn,
      project: project,
      env: env,
      states: [s1, _, _]
    } do
      {:ok, view, html} = live(conn, explorer_path(project, env) <> "?snapshot=#{s1.uuid}")

      assert html =~ "(Snapshot)"
      # s1 is the oldest state — idx=1 in the reversed list
      assert viewer_state(view, 1) == %{"v" => 1}
    end

    test "?snapshot=<bad uuid> is ignored, latest still selected", %{
      conn: conn,
      project: project,
      env: env
    } do
      {:ok, _view, html} =
        live(
          conn,
          explorer_path(project, env) <> "?snapshot=00000000-0000-0000-0000-000000000000"
        )

      refute html =~ "(Snapshot)"
      assert html =~ "(Current)"
    end
  end

  describe "lock_unit / unlock_unit" do
    test "lock_unit creates an active lock and updates badge", %{
      conn: conn,
      project: project,
      env: env
    } do
      {:ok, view, _} = live(conn, explorer_path(project, env))

      render_click(view, "lock_unit", %{})

      assert render(view) =~ "Unit Locked"
      assert LockContext.get_active_lock_by_environment_and_path(env.id, "") != nil
    end

    test "unlock_unit deactivates lock and updates badge", %{
      conn: conn,
      project: project,
      env: env
    } do
      create_lock(env, %{sub_path: ""})
      {:ok, view, _} = live(conn, explorer_path(project, env))

      render_click(view, "unlock_unit", %{})

      assert render(view) =~ "Unit Unlocked"
      assert LockContext.get_active_lock_by_environment_and_path(env.id, "") == nil
    end
  end

  describe "confirm_action / cancel_confirm" do
    test "confirm_action opens dialog, cancel dismisses it", %{
      conn: conn,
      project: project,
      env: env
    } do
      {:ok, view, _} = live(conn, explorer_path(project, env))

      render_click(view, "confirm_action", %{
        "event" => "lock_unit",
        "message" => "Lock this unit?",
        "uuid" => ""
      })

      assert has_element?(view, "#confirm-dialog")

      render_click(view, "cancel_confirm", %{})
      refute has_element?(view, "#confirm-dialog")
    end
  end

  describe "sub_path filtering" do
    test "states with non-matching sub_path are excluded", %{
      conn: conn,
      project: project,
      env: env
    } do
      create_state(env, %{sub_path: "dns", value: ~s({"only":"dns"})})

      # Visit root explorer — should show v3 root state, not the dns state
      {:ok, view, _} = live(conn, explorer_path(project, env))
      assert viewer_state(view, 3) == %{"v" => 3}

      # Visit dns sub_path explorer — should show the dns state at v1
      {:ok, view, _} = live(conn, explorer_path(project, env, "dns"))
      assert viewer_state(view, 1) == %{"only" => "dns"}
    end
  end
end

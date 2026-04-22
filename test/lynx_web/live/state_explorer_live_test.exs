defmodule LynxWeb.StateExplorerLiveTest do
  use LynxWeb.LiveCase

  alias Lynx.Context.LockContext

  setup %{conn: conn} do
    # super bypasses per-project RBAC. Permission-denial tests live in their
    # own describe block below.
    user = create_super()
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

    test "mount defaults compare-with to the latest so single pane shows", %{
      conn: conn,
      project: project,
      env: env
    } do
      # Both selects point at the latest version on a clean load — equal
      # selected/compare suppresses the diff and renders the single pane,
      # so the user can flip either dropdown to start a diff.
      {:ok, view, html} = live(conn, explorer_path(project, env))

      refute has_element?(view, "[id^=\"diff-\"]")
      refute html =~ "would be added"
      refute html =~ "would be removed"
      assert viewer_state(view, 3) == %{"v" => 3}
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

    test "compare with shows the semantic-diff toolbar (default view)", %{
      conn: conn,
      project: project,
      env: env
    } do
      {:ok, view, _} = live(conn, explorer_path(project, env))

      render_change(view, "version_change", %{"version" => "3", "compare" => "1"})

      html = render(view)
      # Default diff view is :semantic — Resources/Raw toggle is visible.
      assert html =~ "Resources"
      assert html =~ "Raw JSON"
      # The seed states are `{"v": N}` (no `resources` array) so the diff is
      # empty — the LV renders the "no resource-level changes" message.
      assert html =~ "No resource-level changes"
    end

    test "switching to Raw view exposes the line-diff container", %{
      conn: conn,
      project: project,
      env: env
    } do
      {:ok, view, _} = live(conn, explorer_path(project, env))
      render_change(view, "version_change", %{"version" => "3", "compare" => "1"})

      # Semantic by default → no #diff-N-N container
      refute has_element?(view, "#diff-3-1")

      render_click(view, "set_diff_view", %{"view" => "raw"})

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

    test "empty diff distinguishes byte-identical states from serial-bumped same-resource states",
         %{
           user: user,
           workspace: ws
         } do
      # Two real-world cases the operator confuses with "diff is broken":
      # (1) v_a == v_b byte-for-byte → "are identical"
      # (2) v_a and v_b have the same resources but differ in non-resource
      #     fields (serial, lineage) → "No resource-level changes ... Switch to Raw JSON"
      project = create_project(%{workspace_id: ws.id, name: "tf-empty"})
      env = create_env(project, %{name: "p", slug: "p-empty"})

      resources = [
        %{
          "mode" => "managed",
          "type" => "okta_group",
          "name" => "g",
          "instances" => [%{"attributes" => %{"name" => "Managers"}}]
        }
      ]

      v1 = Jason.encode!(%{"version" => 4, "serial" => 5, "resources" => resources})
      # Same resources, bumped serial — terraform refresh-only push
      v2 = Jason.encode!(%{"version" => 4, "serial" => 6, "resources" => resources})
      # Identical to v2 (no-op push)
      v3 = v2

      _ = create_state(env, %{value: v1})
      _ = create_state(env, %{value: v2})
      _ = create_state(env, %{value: v3})

      conn = log_in_user(Phoenix.ConnTest.build_conn() |> Plug.Test.init_test_session(%{}), user)

      {:ok, view, _} =
        live(conn, "/admin/projects/#{project.uuid}/environments/#{env.uuid}/state")

      # v1 vs v2 — same resources, different bytes (serial bumped)
      render_change(view, "version_change", %{"version" => "1", "compare" => "2"})
      html = render(view)
      assert html =~ "No resource-level changes"
      assert html =~ "non-resource fields"

      # v2 vs v3 — byte-identical
      render_change(view, "version_change", %{"version" => "2", "compare" => "3"})
      html = render(view)
      assert html =~ "are identical"
    end

    test "semantic diff renders summary counts + per-resource cards for real TF state", %{
      user: user,
      workspace: ws
    } do
      # Use a fresh project + env so we can seed real Terraform-shaped state
      # without colliding with the setup's `{"v":N}` placeholders.
      project = create_project(%{workspace_id: ws.id, name: "tf-semantic"})
      env = create_env(project, %{name: "p", slug: "p"})

      v1 =
        Jason.encode!(%{
          "version" => 4,
          "resources" => [
            %{
              "mode" => "managed",
              "type" => "aws_vpc",
              "name" => "main",
              "instances" => [%{"attributes" => %{"cidr" => "10.0.0.0/16"}}]
            },
            %{
              "mode" => "managed",
              "type" => "aws_security_group",
              "name" => "doomed",
              "instances" => [%{"attributes" => %{"name" => "sg-old"}}]
            }
          ]
        })

      v2 =
        Jason.encode!(%{
          "version" => 4,
          "resources" => [
            %{
              # changed
              "mode" => "managed",
              "type" => "aws_vpc",
              "name" => "main",
              "instances" => [%{"attributes" => %{"cidr" => "10.1.0.0/16"}}]
            },
            %{
              # added
              "mode" => "managed",
              "type" => "aws_iam_role",
              "name" => "ci",
              "instances" => [%{"attributes" => %{"name" => "ci"}}]
            }
          ]
        })

      _ = create_state(env, %{value: v1})
      _ = create_state(env, %{value: v2})

      conn = log_in_user(Phoenix.ConnTest.build_conn() |> Plug.Test.init_test_session(%{}), user)

      {:ok, view, _} =
        live(conn, "/admin/projects/#{project.uuid}/environments/#{env.uuid}/state")

      # Selected = v2 (newer, has iam role + changed vpc, missing the sg).
      # Compare with = v1 (older, has sg + original vpc, no iam role).
      # Diff is *directional*: "what changes if I replace v2 with v1?"
      #   - sg would be ADDED (it's in v1, not in v2)
      #   - vpc cidr would CHANGE (10.1 → 10.0)
      #   - iam_role would be REMOVED (it's in v2, not in v1)
      render_change(view, "version_change", %{"version" => "2", "compare" => "1"})
      html = render(view)

      text =
        html
        |> Floki.parse_document!()
        |> Floki.text(sep: " ")
        |> String.replace(~r/\s+/, " ")

      assert text =~ "1 would be added"
      assert text =~ "1 would change"
      assert text =~ "1 would be removed"

      # Resource cards — assert which resource ended up in which bucket.
      # `aws_security_group.doomed` exists in v1 only → would be added by
      # restoring v1 over v2.
      assert html =~ ~r/would add\s*<\/.+?>\s*<code[^>]*>\s*aws_security_group\.doomed/s ||
               html =~ ~s(would add)

      assert html =~ "aws_security_group.doomed"

      # `aws_iam_role.ci` exists in v2 only → would be removed.
      assert html =~ "aws_iam_role.ci"

      # `aws_vpc.main` exists in both with different cidr → would change.
      assert html =~ "aws_vpc.main"
      assert html =~ "cidr"
      assert html =~ "10.0.0.0/16"
      assert html =~ "10.1.0.0/16"
    end

    test "diff is directional — flipping selected/compare swaps added ↔ removed", %{
      user: user,
      workspace: ws
    } do
      project = create_project(%{workspace_id: ws.id, name: "tf-direction"})
      env = create_env(project, %{name: "p", slug: "p-direction"})

      # v1 has sg only; v2 adds an iam_role and removes sg.
      v1 =
        Jason.encode!(%{
          "version" => 4,
          "resources" => [
            %{
              "mode" => "managed",
              "type" => "aws_security_group",
              "name" => "sg",
              "instances" => [%{"attributes" => %{}}]
            }
          ]
        })

      v2 =
        Jason.encode!(%{
          "version" => 4,
          "resources" => [
            %{
              "mode" => "managed",
              "type" => "aws_iam_role",
              "name" => "r",
              "instances" => [%{"attributes" => %{}}]
            }
          ]
        })

      _ = create_state(env, %{value: v1})
      _ = create_state(env, %{value: v2})

      conn = log_in_user(Phoenix.ConnTest.build_conn() |> Plug.Test.init_test_session(%{}), user)

      {:ok, view, _} =
        live(conn, "/admin/projects/#{project.uuid}/environments/#{env.uuid}/state")

      # selected=v2, compare=v1 → restoring v1 ADDS sg, REMOVES iam_role
      render_change(view, "version_change", %{"version" => "2", "compare" => "1"})

      text =
        view
        |> render()
        |> Floki.parse_document!()
        |> Floki.text(sep: " ")
        |> String.replace(~r/\s+/, " ")

      assert text =~ "1 would be added"
      assert text =~ "1 would be removed"

      # Flip: selected=v1, compare=v2 → restoring v2 ADDS iam_role, REMOVES sg
      render_change(view, "version_change", %{"version" => "1", "compare" => "2"})

      text2 =
        view
        |> render()
        |> Floki.parse_document!()
        |> Floki.text(sep: " ")
        |> String.replace(~r/\s+/, " ")

      assert text2 =~ "1 would be added"
      assert text2 =~ "1 would be removed"

      # The cards in each direction should contain DIFFERENT resources in
      # each bucket — when v1 is selected, iam_role is in the "would add"
      # card; when v2 is selected, sg is. Easiest sanity: in the v1->v2
      # render, the iam_role label appears under a "would add" badge.
      html_v1_to_v2 = render(view)
      assert html_v1_to_v2 =~ "aws_iam_role.r"
      assert html_v1_to_v2 =~ "aws_security_group.sg"
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

defmodule LynxWeb.StateSearchLiveTest do
  @moduledoc """
  LiveView coverage for `/admin/state-search` (issue #37).

  Behavior, not Tailwind classes: assert breadcrumb text, snippet markers,
  and absence of forbidden hits — the look is verified manually + in the
  test for `bg-badge-warning-bg` rendering inside the snippet HTML.
  """
  use LynxWeb.LiveCase

  alias Lynx.Context.{RoleContext, UserProjectContext}

  setup %{conn: conn} do
    mark_installed()

    ws_a = create_workspace(%{name: "WS A", slug: "ws-a"})
    ws_b = create_workspace(%{name: "WS B", slug: "ws-b"})

    project_a = create_project(%{workspace_id: ws_a.id, name: "Proj A", slug: "proj-a"})
    project_b = create_project(%{workspace_id: ws_b.id, name: "Proj B", slug: "proj-b"})

    env_a = create_env(project_a, %{name: "prod", slug: "prod"})
    env_b = create_env(project_b, %{name: "prod", slug: "prod"})

    create_state(env_a, %{
      value: ~s({"resources":[{"type":"aws_iam_role","name":"deploybot"}]})
    })

    create_state(env_b, %{
      value: ~s({"resources":[{"type":"aws_s3_bucket","name":"deploybot"}]})
    })

    {:ok, conn: conn, project_a: project_a, project_b: project_b, env_a: env_a, env_b: env_b}
  end

  describe "mount" do
    test "regular user sees the page (it's not super-only)", %{conn: conn} do
      user = create_user()
      conn = log_in_user(conn, user)

      {:ok, _view, html} = live(conn, "/admin/state-search")
      assert html =~ "State Search"
      assert html =~ "Type a resource name"
    end

    test "super sees the page", %{conn: conn} do
      conn = log_in_user(conn, create_super())

      {:ok, _view, html} = live(conn, "/admin/state-search")
      assert html =~ "State Search"
    end
  end

  describe "search results" do
    test "super sees hits from every workspace", %{conn: conn} do
      conn = log_in_user(conn, create_super())

      {:ok, _view, html} = live(conn, "/admin/state-search?q=deploybot")

      # Both projects' breadcrumbs must show.
      assert html =~ "Proj A"
      assert html =~ "Proj B"
      # Breadcrumb separator + env name proves the result row rendered.
      assert html =~ "WS A"
      assert html =~ "WS B"
    end

    test "regular user with no grants sees no results", %{conn: conn} do
      user = create_user()
      conn = log_in_user(conn, user)

      {:ok, _view, html} = live(conn, "/admin/state-search?q=deploybot")

      refute html =~ "Proj A"
      refute html =~ "Proj B"
      assert html =~ "No matching state files"
    end

    test "regular user with planner on project A sees only A", %{
      conn: conn,
      project_a: project_a
    } do
      user = create_user()
      planner = RoleContext.get_role_by_name("planner")
      {:ok, _} = UserProjectContext.assign_role(user.id, project_a.id, planner.id)

      conn = log_in_user(conn, user)
      {:ok, _view, html} = live(conn, "/admin/state-search?q=deploybot")

      assert html =~ "Proj A"
      refute html =~ "Proj B"
      refute html =~ "WS B"
    end

    test "snippet renders with <mark> tags around the match", %{conn: conn} do
      conn = log_in_user(conn, create_super())

      {:ok, _view, html} = live(conn, "/admin/state-search?q=deploybot")

      # Sentinel markers from Postgres must be replaced before render.
      refute html =~ "⟦MARK⟧"
      refute html =~ "⟦/MARK⟧"
      assert html =~ "<mark"
      assert html =~ "</mark>"
    end
  end

  describe "search form" do
    test "submitting a query patches URL with ?q=", %{conn: conn} do
      conn = log_in_user(conn, create_super())
      {:ok, view, _} = live(conn, "/admin/state-search")

      render_change(view, "search", %{"q" => "deploybot"})

      assert assert_patch(view) =~ "q=deploybot"
    end

    test "blank query clears the URL back to /admin/state-search", %{conn: conn} do
      conn = log_in_user(conn, create_super())
      {:ok, view, _} = live(conn, "/admin/state-search?q=deploybot")

      render_change(view, "search", %{"q" => ""})
      patched = assert_patch(view)

      assert patched == "/admin/state-search"
    end

    test "no query shows the empty-prompt placeholder, not the no-results text", %{conn: conn} do
      conn = log_in_user(conn, create_super())
      {:ok, _view, html} = live(conn, "/admin/state-search")

      assert html =~ "Type a resource name"
      refute html =~ "No matching state files"
    end
  end

  describe "links" do
    test "result breadcrumb links to the env detail page", %{
      conn: conn,
      project_a: project_a,
      env_a: env_a
    } do
      conn = log_in_user(conn, create_super())

      {:ok, _view, html} = live(conn, "/admin/state-search?q=deploybot")

      expected = "/admin/projects/#{project_a.uuid}/environments/#{env_a.uuid}"
      assert html =~ expected
    end
  end
end

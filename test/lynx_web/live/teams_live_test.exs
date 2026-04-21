defmodule LynxWeb.TeamsLiveTest do
  use LynxWeb.LiveCase

  alias Lynx.Context.TeamContext

  setup %{conn: conn} do
    user = create_super()
    {:ok, conn: log_in_user(conn, user), user: user}
  end

  describe "mount" do
    test "renders Teams title", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin/teams")
      assert html =~ "Teams"
      assert html =~ "+ Add Team"
    end

    test "lists existing teams", %{conn: conn} do
      {:ok, _team} =
        TeamContext.create_team_from_data(%{name: "Platform", slug: "platform", description: "x"})

      {:ok, _view, html} = live(conn, "/admin/teams")
      assert html =~ "Platform"
      assert html =~ "platform"
    end

    test "non-super user is redirected to /login", %{conn: conn} do
      regular = create_user()
      conn = log_in_user(conn, regular)

      assert {:error, {:redirect, %{to: "/login"}}} = live(conn, "/admin/teams")
    end
  end

  describe "Add Team modal" do
    test "modal opens and closes", %{conn: conn} do
      {:ok, view, _} = live(conn, "/admin/teams")

      refute has_element?(view, "#add-team")
      render_click(view, "show_add", %{})
      assert has_element?(view, "#add-team")
      render_click(view, "hide_add", %{})
      refute has_element?(view, "#add-team")
    end

    test "form_change derives slug from name", %{conn: conn} do
      {:ok, view, _} = live(conn, "/admin/teams")
      render_click(view, "show_add", %{})

      render_change(view, "add_form_change", %{"name" => "Cloud Infra"})

      assert render(view) =~ ~s(value="cloud-infra")
    end

    test "create_team persists team", %{conn: conn} do
      {:ok, view, _} = live(conn, "/admin/teams")
      render_click(view, "show_add", %{})

      render_submit(view, "create_team", %{
        "name" => "Backend",
        "slug" => "backend",
        "description" => "API team",
        "members" => []
      })

      html = render(view)
      assert html =~ "Team created"
      assert html =~ "Backend"
    end
  end

  describe "Edit Team" do
    test "edit_team opens modal with current values", %{conn: conn} do
      {:ok, team} =
        TeamContext.create_team_from_data(%{name: "Old Name", slug: "old", description: "x"})

      {:ok, view, _} = live(conn, "/admin/teams")

      render_click(view, "edit_team", %{"uuid" => team.uuid})

      assert has_element?(view, "#edit-team")
      assert render(view) =~ ~s(value="Old Name")
    end

    test "update_team persists changes", %{conn: conn} do
      {:ok, team} =
        TeamContext.create_team_from_data(%{name: "Old", slug: "old", description: "x"})

      {:ok, view, _} = live(conn, "/admin/teams")

      render_click(view, "edit_team", %{"uuid" => team.uuid})

      render_submit(view, "update_team", %{
        "name" => "Renamed",
        "slug" => "renamed",
        "description" => "new",
        "members" => []
      })

      html = render(view)
      assert html =~ "Team updated"
      assert html =~ "Renamed"
    end
  end

  describe "Projects & Roles column" do
    alias Lynx.Context.{ProjectContext, RoleContext}

    test "shows attached project name and role badge", %{conn: conn} do
      {:ok, team} =
        TeamContext.create_team_from_data(%{name: "Infra", slug: "infra", description: "x"})

      workspace = create_workspace()
      project = create_project(%{name: "Platform", workspace_id: workspace.id})
      planner = RoleContext.get_role_by_name("planner")

      ProjectContext.add_project_to_team(project.id, team.id, planner.id)

      {:ok, _view, html} = live(conn, "/admin/teams")
      assert html =~ "Projects &amp; Roles"
      assert html =~ "Platform"
      assert html =~ "Planner"
      assert html =~ ~s(href="/admin/projects/#{project.uuid}")
    end

    test "shows 'No projects' when team has no project assignments", %{conn: conn} do
      {:ok, _team} =
        TeamContext.create_team_from_data(%{name: "Lonely", slug: "lonely", description: "x"})

      {:ok, _view, html} = live(conn, "/admin/teams")
      assert html =~ "No projects"
    end
  end

  describe "Members combobox" do
    alias Lynx.Context.UserContext

    test "add modal: add_form_change populates options matching `_q_members`", %{conn: conn} do
      _alice = create_user(%{name: "Alice Findme", email: "alice@example.com"})
      _bob = create_user(%{name: "Bob Other", email: "bob@example.com"})

      {:ok, view, _} = live(conn, "/admin/teams")
      render_click(view, "show_add", %{})

      html =
        render_change(view, "add_form_change", %{"name" => "Whatever", "_q_members" => "find"})

      # Combobox option list re-renders from search results.
      assert html =~ "Alice Findme"
      refute html =~ "Bob Other"
    end

    test "edit modal pre-populates current members as combobox chips", %{conn: conn} do
      {:ok, team} =
        TeamContext.create_team_from_data(%{name: "Pre", slug: "pre", description: "x"})

      member = create_user(%{name: "Charlie Member", email: "c@example.com"})
      {:ok, _} = UserContext.add_user_to_team(member.id, team.id)

      {:ok, view, _} = live(conn, "/admin/teams")
      render_click(view, "edit_team", %{"uuid" => team.uuid})

      # Initial selection is JSON-encoded into data-initial on the trigger
      # so the colocated hook can render chips on mount.
      html = render(view)
      assert html =~ "Charlie Member"
      # Hidden input carries the user UUID so form submission works without JS.
      assert html =~ ~s(name="members[]")
      assert html =~ member.uuid
    end

    test "edit modal: edit_form_change refreshes options without losing selection", %{conn: conn} do
      {:ok, team} =
        TeamContext.create_team_from_data(%{name: "EditMe", slug: "editme", description: "x"})

      _zoe = create_user(%{name: "Zoe Searchable", email: "z@example.com"})

      {:ok, view, _} = live(conn, "/admin/teams")
      render_click(view, "edit_team", %{"uuid" => team.uuid})

      html = render_change(view, "edit_form_change", %{"_q_members" => "zoe"})
      assert html =~ "Zoe Searchable"
    end
  end

  describe "Delete Team" do
    test "delete_team removes the team", %{conn: conn} do
      {:ok, team} =
        TeamContext.create_team_from_data(%{name: "ToDelete", slug: "td", description: "x"})

      {:ok, view, _} = live(conn, "/admin/teams")

      render_click(view, "delete_team", %{"uuid" => team.uuid})

      html = render(view)
      assert html =~ "Team deleted"
      refute html =~ "ToDelete"
    end
  end
end

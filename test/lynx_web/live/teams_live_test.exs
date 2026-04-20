defmodule LynxWeb.TeamsLiveTest do
  use LynxWeb.LiveCase

  alias Lynx.Module.TeamModule

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
        TeamModule.create_team(%{name: "Platform", slug: "platform", description: "x"})

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

      render_change(view, "form_change", %{"name" => "Cloud Infra"})

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
      {:ok, team} = TeamModule.create_team(%{name: "Old Name", slug: "old", description: "x"})
      {:ok, view, _} = live(conn, "/admin/teams")

      render_click(view, "edit_team", %{"uuid" => team.uuid})

      assert has_element?(view, "#edit-team")
      assert render(view) =~ ~s(value="Old Name")
    end

    test "update_team persists changes", %{conn: conn} do
      {:ok, team} = TeamModule.create_team(%{name: "Old", slug: "old", description: "x"})
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

  describe "Delete Team" do
    test "delete_team removes the team", %{conn: conn} do
      {:ok, team} = TeamModule.create_team(%{name: "ToDelete", slug: "td", description: "x"})
      {:ok, view, _} = live(conn, "/admin/teams")

      render_click(view, "delete_team", %{"uuid" => team.uuid})

      html = render(view)
      assert html =~ "Team deleted"
      refute html =~ "ToDelete"
    end
  end
end

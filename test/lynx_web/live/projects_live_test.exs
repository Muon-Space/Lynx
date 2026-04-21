defmodule LynxWeb.ProjectsLiveTest do
  use LynxWeb.LiveCase

  alias Lynx.Context.ProjectContext

  setup %{conn: conn} do
    user = create_super()
    workspace = create_workspace()
    {:ok, conn: log_in_user(conn, user), user: user, workspace: workspace}
  end

  defp ws_path(workspace), do: "/admin/workspaces/#{workspace.uuid}"

  describe "mount" do
    test "renders workspace name as page header", %{conn: conn, workspace: ws} do
      {:ok, _view, html} = live(conn, ws_path(ws))
      assert html =~ ws.name
    end

    test "redirects when workspace not found", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/admin/workspaces"}}} =
               live(conn, "/admin/workspaces/00000000-0000-0000-0000-000000000000")
    end

    test "lists projects in the workspace", %{conn: conn, workspace: ws} do
      _ = create_project(%{workspace_id: ws.id, name: "Web"})
      _ = create_project(%{workspace_id: ws.id, name: "API"})

      {:ok, _view, html} = live(conn, ws_path(ws))
      assert html =~ "Web"
      assert html =~ "API"
    end
  end

  describe "Add Project modal" do
    test "modal opens and closes", %{conn: conn, workspace: ws} do
      {:ok, view, _} = live(conn, ws_path(ws))

      refute has_element?(view, "#add-project")
      render_click(view, "show_add", %{})
      assert has_element?(view, "#add-project")
      render_click(view, "hide_add", %{})
      refute has_element?(view, "#add-project")
    end

    test "form_change derives slug from name", %{conn: conn, workspace: ws} do
      {:ok, view, _} = live(conn, ws_path(ws))
      render_click(view, "show_add", %{})

      render_change(view, "add_form_change", %{"name" => "Cool Project!"})
      assert render(view) =~ ~s(value="cool-project")
    end

    test "create_project persists project", %{conn: conn, workspace: ws} do
      {:ok, view, _} = live(conn, ws_path(ws))
      render_click(view, "show_add", %{})

      render_submit(view, "create_project", %{
        "name" => "Backend",
        "slug" => "backend",
        "description" => "API server",
        "team_ids" => []
      })

      html = render(view)
      assert html =~ "Project created"
      assert html =~ "Backend"

      assert ProjectContext.get_projects_by_workspace(ws.id, 0, 10)
             |> Enum.any?(&(&1.slug == "backend"))
    end
  end

  describe "Edit Project" do
    test "edit_project opens modal with current values", %{conn: conn, workspace: ws} do
      project = create_project(%{workspace_id: ws.id, name: "Old", slug: "old"})

      {:ok, view, _} = live(conn, ws_path(ws))
      render_click(view, "edit_project", %{"uuid" => project.uuid})

      assert has_element?(view, "#edit-project")
      assert render(view) =~ ~s(value="Old")
      assert render(view) =~ ~s(value="old")
    end

    test "update_project persists changes", %{conn: conn, workspace: ws} do
      project = create_project(%{workspace_id: ws.id, name: "Old", slug: "old"})

      {:ok, view, _} = live(conn, ws_path(ws))
      render_click(view, "edit_project", %{"uuid" => project.uuid})

      render_submit(view, "update_project", %{
        "name" => "Renamed",
        "slug" => "renamed",
        "description" => "new description",
        "team_ids" => []
      })

      html = render(view)
      assert html =~ "Project updated"
      assert html =~ "Renamed"
    end
  end

  describe "Teams combobox" do
    alias Lynx.Context.{ProjectContext, TeamContext}

    test "add modal: add_form_change populates team options matching `_q_team_ids`", %{
      conn: conn,
      workspace: ws
    } do
      {:ok, _platform} =
        TeamContext.create_team_from_data(%{
          name: "Platform Findme",
          slug: "platform",
          description: "x"
        })

      {:ok, _other} =
        TeamContext.create_team_from_data(%{
          name: "Marketing Other",
          slug: "marketing",
          description: "x"
        })

      {:ok, view, _} = live(conn, ws_path(ws))
      render_click(view, "show_add", %{})

      html =
        render_change(view, "add_form_change", %{
          "name" => "Whatever",
          "_q_team_ids" => "platform"
        })

      assert html =~ "Platform Findme"
      refute html =~ "Marketing Other"
    end

    test "edit modal pre-populates currently-attached teams as combobox chips", %{
      conn: conn,
      workspace: ws
    } do
      {:ok, team} =
        TeamContext.create_team_from_data(%{
          name: "Already Attached",
          slug: "att",
          description: "x"
        })

      project = create_project(%{workspace_id: ws.id, name: "Proj", slug: "proj"})
      ProjectContext.add_project_to_team(project.id, team.id)

      {:ok, view, _} = live(conn, ws_path(ws))
      render_click(view, "edit_project", %{"uuid" => project.uuid})

      html = render(view)
      assert html =~ "Already Attached"
      assert html =~ ~s(name="team_ids[]")
      assert html =~ team.uuid
    end
  end

  describe "Delete Project" do
    test "confirm_delete opens confirm dialog", %{conn: conn, workspace: ws} do
      project = create_project(%{workspace_id: ws.id})

      {:ok, view, _} = live(conn, ws_path(ws))
      render_click(view, "confirm_delete", %{"uuid" => project.uuid})

      assert has_element?(view, "#confirm-dialog")
    end

    test "delete_project removes the project", %{conn: conn, workspace: ws} do
      project = create_project(%{workspace_id: ws.id, name: "ToDelete"})

      {:ok, view, _} = live(conn, ws_path(ws))
      render_click(view, "delete_project", %{"uuid" => project.uuid})

      html = render(view)
      assert html =~ "Project deleted"
      refute html =~ "ToDelete"
    end
  end

  describe "auth" do
    test "redirects unauthenticated user to /login", %{workspace: ws} do
      assert {:error, {:redirect, %{to: "/login"}}} = live(build_conn(), ws_path(ws))
    end
  end
end

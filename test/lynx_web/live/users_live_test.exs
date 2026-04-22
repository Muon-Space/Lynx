defmodule LynxWeb.UsersLiveTest do
  use LynxWeb.LiveCase

  alias Lynx.Context.UserContext

  setup %{conn: conn} do
    # UsersLive.create_user uses UserContext.create_user, which derives the
    # bcrypt salt from the `app_key` config — must be seeded.
    mark_installed()
    user = create_super(%{name: "Admin"})
    {:ok, conn: log_in_user(conn, user), user: user}
  end

  describe "mount" do
    test "renders Users title", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin/users")
      assert html =~ "Users"
      assert html =~ "+ Add User"
    end

    test "lists existing users", %{conn: conn, user: admin} do
      _ = create_user(%{name: "Other User", email: "other@x.test"})

      {:ok, _view, html} = live(conn, "/admin/users")
      assert html =~ admin.name
      assert html =~ "Other User"
    end

    test "non-super user is redirected to /login", %{conn: conn} do
      regular = create_user()
      conn = log_in_user(conn, regular)

      assert {:error, {:redirect, %{to: "/login"}}} = live(conn, "/admin/users")
    end
  end

  describe "Add User modal" do
    test "modal opens and closes", %{conn: conn} do
      {:ok, view, _} = live(conn, "/admin/users")

      refute has_element?(view, "#add-user-modal")
      render_click(view, "show_add", %{})
      assert has_element?(view, "#add-user-modal")
      render_click(view, "hide_add", %{})
      refute has_element?(view, "#add-user-modal")
    end

    test "create_user persists user and reloads list", %{conn: conn} do
      {:ok, view, _} = live(conn, "/admin/users")
      render_click(view, "show_add", %{})

      render_submit(view, "create_user", %{
        "name" => "Charlie",
        "email" => "charlie@x.test",
        "password" => "verygoodpassword",
        "role" => "regular"
      })

      html = render(view)
      assert html =~ "User created"
      assert html =~ "Charlie"
      refute has_element?(view, "#add-user-modal")

      assert UserContext.get_user_by_email("charlie@x.test") != nil
    end

    test "create_user shows error when email is missing", %{conn: conn} do
      {:ok, view, _} = live(conn, "/admin/users")
      render_click(view, "show_add", %{})

      html =
        render_submit(view, "create_user", %{
          "name" => "Eve",
          "email" => "",
          "password" => "verygoodpassword",
          "role" => "regular"
        })

      assert html =~ "email" or html =~ "Email"
      assert UserContext.get_user_by_email("") == nil
    end
  end

  describe "Edit User" do
    test "edit_user opens modal with current values", %{conn: conn} do
      target = create_user(%{name: "Old Name", email: "old@x.test"})
      {:ok, view, _} = live(conn, "/admin/users")

      render_click(view, "edit_user", %{"uuid" => target.uuid})

      assert has_element?(view, "#edit-user-modal")
      assert render(view) =~ ~s(value="Old Name")
      assert render(view) =~ ~s(value="old@x.test")
    end

    test "?edit=UUID deep-link from /admin/audit opens the modal", %{conn: conn} do
      target = create_user(%{name: "Linked", email: "link@x.test"})
      {:ok, _view, html} = live(conn, "/admin/users?edit=#{target.uuid}")

      assert html =~ ~s(id="edit-user-modal")
      assert html =~ ~s(value="Linked")
    end

    test "?edit=UUID with unknown UUID is a no-op", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin/users?edit=00000000-0000-0000-0000-000000000000")
      refute html =~ ~s(id="edit-user-modal")
    end

    test "update_user persists changes", %{conn: conn} do
      target = create_user(%{name: "Old", email: "x@y.test"})
      {:ok, view, _} = live(conn, "/admin/users")

      render_click(view, "edit_user", %{"uuid" => target.uuid})

      render_submit(view, "update_user", %{
        "name" => "Renamed User",
        "email" => "x@y.test",
        "password" => "",
        "role" => "user"
      })

      html = render(view)
      assert html =~ "User updated"
      assert html =~ "Renamed User"
    end
  end

  describe "Projects & Roles column" do
    alias Lynx.Context.{ProjectContext, RoleContext, UserProjectContext}

    test "shows direct user_project grants with project link + role badge", %{conn: conn} do
      target = create_user(%{name: "Grace", email: "grace@x.test"})
      workspace = create_workspace()
      project = create_project(%{name: "Atlas", workspace_id: workspace.id})
      planner = RoleContext.get_role_by_name("planner")
      UserProjectContext.assign_role(target.id, project.id, planner.id)

      {:ok, _view, html} = live(conn, "/admin/users")
      assert html =~ "Projects &amp; Roles"
      assert html =~ "Atlas"
      assert html =~ "Planner"
      assert html =~ ~s(href="/admin/projects/#{project.uuid}")
    end

    test "shows team-derived grants alongside direct ones", %{conn: conn} do
      target = create_user(%{name: "Hugo", email: "hugo@x.test"})
      workspace = create_workspace()
      project = create_project(%{name: "Beacon", workspace_id: workspace.id})

      {:ok, team} =
        Lynx.Context.TeamContext.create_team_from_data(%{
          name: "Infra",
          slug: "infra-x",
          description: "x"
        })

      {:ok, _} = Lynx.Context.UserContext.add_user_to_team(target.id, team.id)
      applier = RoleContext.get_role_by_name("applier")
      ProjectContext.add_project_to_team(project.id, team.id, applier.id)

      {:ok, _view, html} = live(conn, "/admin/users")
      assert html =~ "Beacon"
      assert html =~ "Applier"
    end

    test "super users show 'All projects (super)' instead of enumerating", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin/users")
      # The setup user is a super; the row for them should show the marker.
      assert html =~ "All projects (super)"
    end

    test "users without grants show 'No projects'", %{conn: conn} do
      _ = create_user(%{name: "Lonely", email: "lonely@x.test"})
      {:ok, _view, html} = live(conn, "/admin/users")
      assert html =~ "No projects"
    end
  end

  describe "Delete User" do
    test "delete_user removes the user", %{conn: conn} do
      target = create_user(%{name: "ToDelete", email: "del@x.test"})
      {:ok, view, _} = live(conn, "/admin/users")

      render_click(view, "delete_user", %{"uuid" => target.uuid})

      html = render(view)
      assert html =~ "User deleted"
      refute html =~ "ToDelete"
      assert UserContext.get_user_by_email("del@x.test") == nil
    end
  end
end

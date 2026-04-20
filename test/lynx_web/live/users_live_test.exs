defmodule LynxWeb.UsersLiveTest do
  use LynxWeb.LiveCase

  alias Lynx.Context.UserContext

  setup %{conn: conn} do
    # UsersLive.create_user uses UserModule.create_user, which derives the
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

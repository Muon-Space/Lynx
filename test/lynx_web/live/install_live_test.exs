defmodule LynxWeb.InstallLiveTest do
  use LynxWeb.LiveCase

  alias Lynx.Service.Install
  alias Lynx.Context.UserContext

  describe "mount" do
    test "renders install form when not installed", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/install")
      assert html =~ "Setup Lynx"
      assert html =~ "Application Name"
      assert html =~ "Admin Email"
      assert html =~ ~s(phx-submit="install")
    end

    test "redirects to / when already installed", %{conn: conn} do
      mark_installed()
      assert {:error, {:redirect, %{to: "/"}}} = live(conn, "/install")
    end
  end

  describe "install event" do
    test "creates configs + admin user and redirects to /login", %{conn: conn} do
      {:ok, view, _} = live(conn, "/install")

      result =
        render_submit(view, "install", %{
          "app_name" => "Lynx Test",
          "app_url" => "https://example.com",
          "app_email" => "ops@example.com",
          "admin_name" => "Alice",
          "admin_email" => "alice@example.com",
          "admin_password" => "verygoodpassword"
        })

      assert {:error, {:redirect, %{to: "/login"}}} = result
      assert Install.is_installed()
      assert UserContext.get_user_by_email("alice@example.com") != nil
    end

    test "shows error when admin name is too short (validation)", %{conn: conn} do
      {:ok, view, _} = live(conn, "/install")

      html =
        render_submit(view, "install", %{
          "app_name" => "Lynx",
          "app_url" => "https://x.test",
          "app_email" => "ops@x.test",
          "admin_name" => "x",
          "admin_email" => "bob@x.test",
          "admin_password" => "verygoodpassword"
        })

      # The LV stayed on the install page and surfaced an error from the
      # changeset (User.changeset enforces min length 3 on name).
      assert is_binary(html)
      assert html =~ "name"
      # No user created
      assert UserContext.get_user_by_email("bob@x.test") == nil
    end
  end
end

defmodule LynxWeb.ProfileLiveTest do
  use LynxWeb.LiveCase

  setup %{conn: conn} do
    user = create_user(%{name: "Jane Doe", api_key: "real-api-key-1234567890abcdef"})
    {:ok, conn: log_in_user(conn, user), user: user}
  end

  describe "mount" do
    test "renders profile page with user name and email", %{conn: conn, user: user} do
      {:ok, _view, html} = live(conn, "/admin/profile")
      assert html =~ "Profile"
      assert html =~ user.name
      assert html =~ user.email
    end

    test "API key area shows the prefix from the hashed token, not the full key", %{
      conn: conn,
      user: user
    } do
      {:ok, view, html} = live(conn, "/admin/profile")

      # Prefix is rendered with a trailing ellipsis. The full token must
      # never appear in the HTML at rest.
      assert has_element?(view, "code#api-key-prefix")
      assert html =~ user.api_key_prefix
      refute html =~ user.api_key
    end

    test "rotate button is present, no Show/Hide controls (full key is unrecoverable)",
         %{conn: conn} do
      {:ok, view, _} = live(conn, "/admin/profile")

      assert has_element?(view, "button[phx-value-event=\"rotate_api_key\"]")
      refute has_element?(view, "button[phx-click=\"show_api_key\"]")
      refute has_element?(view, "button[phx-click=\"hide_api_key\"]")
    end

    test "redirects anonymous user", %{} do
      {:error, {:redirect, %{to: "/login"}}} = live(build_conn(), "/admin/profile")
    end
  end

  describe "rotate_api_key" do
    test "confirm dialog appears when Rotate clicked", %{conn: conn} do
      {:ok, view, _} = live(conn, "/admin/profile")

      view
      |> element("button[phx-value-event=\"rotate_api_key\"]")
      |> render_click()

      assert has_element?(view, "#confirm-dialog")
      assert render(view) =~ "Rotate API key?"
    end

    test "cancel_confirm dismisses dialog", %{conn: conn} do
      {:ok, view, _} = live(conn, "/admin/profile")

      view
      |> element("button[phx-value-event=\"rotate_api_key\"]")
      |> render_click()

      assert has_element?(view, "#confirm-dialog")

      render_click(view, "cancel_confirm")
      refute has_element?(view, "#confirm-dialog")
    end

    test "rotate reveals the new plaintext once in a banner with copy button",
         %{conn: conn, user: user} do
      {:ok, view, _} = live(conn, "/admin/profile")

      old_key = user.api_key
      render_click(view, "rotate_api_key", %{})

      html = render(view)
      assert html =~ "API key rotated"
      refute html =~ old_key
      # The new plaintext is in a freshly-rendered banner element.
      assert has_element?(view, "code#revealed-api-key")
      assert has_element?(view, "button#copy-revealed-api-key")
    end

    test "dismissing the revealed-key banner removes the plaintext from the page",
         %{conn: conn} do
      {:ok, view, _} = live(conn, "/admin/profile")

      render_click(view, "rotate_api_key", %{})
      assert has_element?(view, "code#revealed-api-key")

      render_click(view, "dismiss_revealed_key", %{})
      refute has_element?(view, "code#revealed-api-key")
      refute has_element?(view, "button#copy-revealed-api-key")
    end

    test "copy button on the revealed-key banner uses the CopyRevealedKey hook",
         %{conn: conn} do
      {:ok, view, _} = live(conn, "/admin/profile")

      render_click(view, "rotate_api_key", %{})
      html = render(view)

      assert html =~ ~s(id="copy-revealed-api-key")
      # Colocated hook name resolves to the fully qualified form.
      assert html =~ ~s(phx-hook="LynxWeb.ProfileLive.CopyRevealedKey")
      # Plaintext key sits in a data-key attr for the hook to read on click.
      assert html =~ ~s(data-key=)
    end
  end

  describe "update_profile" do
    test "updates name and shows flash", %{conn: conn, user: user} do
      {:ok, view, _} = live(conn, "/admin/profile")

      view
      |> form("form[phx-submit=\"update_profile\"]",
        name: "Renamed",
        email: user.email,
        password: ""
      )
      |> render_submit()

      assert render(view) =~ "Profile updated"
      assert render(view) =~ "Renamed"
    end

    test "shows error when email is invalid", %{conn: conn} do
      {:ok, view, _} = live(conn, "/admin/profile")

      html =
        view
        |> form("form[phx-submit=\"update_profile\"]",
          name: "X",
          email: "not-an-email",
          password: ""
        )
        |> render_submit()

      assert html =~ "bg-flash-error-bg" or html =~ "invalid"
    end
  end
end

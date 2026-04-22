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

    test "API key starts hidden as bullets", %{conn: conn} do
      {:ok, view, _} = live(conn, "/admin/profile")

      assert has_element?(view, "code#api-key-content", "••••")
      assert has_element?(view, "button[phx-click=\"show_api_key\"]")
      refute has_element?(view, "button[phx-click=\"hide_api_key\"]")
    end

    test "redirects anonymous user", %{} do
      {:error, {:redirect, %{to: "/login"}}} = live(build_conn(), "/admin/profile")
    end
  end

  describe "API key reveal" do
    test "show_api_key reveals real key and swaps Show → Hide button", %{conn: conn, user: user} do
      {:ok, view, _} = live(conn, "/admin/profile")

      view |> element("button[phx-click=\"show_api_key\"]") |> render_click()

      assert has_element?(view, "code#api-key-content", user.api_key)
      assert has_element?(view, "button[phx-click=\"hide_api_key\"]")
      refute has_element?(view, "button[phx-click=\"show_api_key\"]")
    end

    test "hide_api_key re-masks the visible element and removes the key from the page", %{
      conn: conn,
      user: user
    } do
      {:ok, view, _} = live(conn, "/admin/profile")

      view |> element("button[phx-click=\"show_api_key\"]") |> render_click()
      assert has_element?(view, "code#api-key-content", user.api_key)

      view |> element("button[phx-click=\"hide_api_key\"]") |> render_click()
      assert has_element?(view, "code#api-key-content", "••••")
      refute render(view) =~ user.api_key
    end
  end

  describe "API key copy button" do
    test "key is never embedded in the rendered HTML at rest", %{conn: conn, user: user} do
      # Security contract: the API key must not be present in the page's HTML
      # in any form (visible code block, hidden element, data attribute).
      # The copy flow uses a server-side push_event instead.
      {:ok, _view, html} = live(conn, "/admin/profile")
      refute html =~ user.api_key
    end

    test "copy_api_key event returns the real key as a correlated reply", %{
      conn: conn,
      user: user
    } do
      # Drives the same path the JS hook uses: pushEvent("copy_api_key", {}, replyFn).
      # The LV replies with `{:reply, %{value: api_key}, socket}`. The hook then
      # writes that value to the clipboard. We can't drive the click via
      # `render_click` because the button no longer has phx-click — the hook
      # owns the click and converts it to a `pushEvent` so the response is
      # correlated and not a broadcast.
      {:ok, view, _} = live(conn, "/admin/profile")

      api_key = user.api_key
      render_hook(view, "copy_api_key", %{})
      assert_reply(view, %{value: ^api_key})
    end

    test "copy button is wired to the CopyApiKey hook with no phx-click", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin/profile")
      assert html =~ ~s(id="copy-api-key")
      # Colocated hooks render the dot-prefixed name resolved to the fully
      # qualified `<Module>.<HookName>` form — that's the contract LV uses
      # to look the hook up in the colocated manifest.
      assert html =~ ~s(phx-hook="LynxWeb.ProfileLive.CopyApiKey")
      # The hook owns the click + pushEvent (with reply); no phx-click on the
      # button. This avoids the broadcast-vs-correlated handleEvent fragility.
      refute html =~ ~s(phx-click="copy_api_key")
      # The old vulnerable target attribute should be gone
      refute html =~ "data-target=\"#api-key-real\""
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

    test "rotate replaces api key and reveals it", %{conn: conn, user: user} do
      {:ok, view, _} = live(conn, "/admin/profile")

      old_key = user.api_key
      render_click(view, "rotate_api_key", %{})

      html = render(view)
      assert html =~ "API key rotated"
      refute html =~ old_key
      # New key should be visible (not bullets) per rotate handler
      assert has_element?(view, "button[phx-click=\"hide_api_key\"]")
    end

    test "rotate pushes copy_api_key_set so the hook's cache stays current", %{conn: conn} do
      # Without this push_event, the hook's prefetched cache holds the
      # pre-rotation key and Copy returns the stale value. The hook listens
      # for "copy_api_key_set" and updates `this.apiKey` accordingly.
      {:ok, view, _} = live(conn, "/admin/profile")

      render_click(view, "rotate_api_key", %{})

      assert_push_event(view, "copy_api_key_set", %{value: rotated_key})
      assert is_binary(rotated_key)
      assert String.length(rotated_key) > 0
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

      # error flash exists (exact text depends on UserModule validation)
      assert html =~ "bg-flash-error-bg" or html =~ "invalid"
    end
  end
end

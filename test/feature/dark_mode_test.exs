defmodule LynxWeb.Feature.DarkModeTest do
  @moduledoc """
  The dark-mode toggle (`.DarkMode` hook in `core_components.ex`) toggles
  the `dark` class on `<html>` and persists the choice in localStorage.
  An inline script in `root.html.heex` reads localStorage on every page
  load to apply the class before the first paint — that's the no-flash
  guarantee from `feedback_color_tokens_dark_mode.md`.

  Both halves (toggle + inline-script restore) are pure-browser, so we
  pin them here.
  """
  use LynxWeb.FeatureCase, async: false

  setup do
    mark_installed()
    user = create_user()
    %{user: user}
  end

  test "toggle adds dark class to <html> and persists across reload", %{
    conn: conn,
    user: user
  } do
    # The toggle is icon-only (moon/sun emoji) so click via its stable id
    # rather than visible text.
    session =
      conn
      |> add_lynx_session(user)
      |> visit("/admin/profile")
      |> refute_has("html.dark")
      |> PhoenixTest.Playwright.click("#dark-mode-toggle")
      |> assert_has("html.dark")

    # Reload the same URL — the inline boot script in root.html.heex reads
    # localStorage and applies the class before paint, so the toggle's
    # effect must survive a full page navigation (not just a LV patch).
    session
    |> visit("/admin/profile")
    |> assert_has("html.dark")
  end
end

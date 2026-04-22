defmodule LynxWeb.Feature.ProfileCopyTest do
  @moduledoc """
  Browser-driven coverage for the API Key Copy + Rotate flow on
  `/admin/profile`. Two regressions live here:

  * **Clipboard activation** — `navigator.clipboard.writeText` is gated on
    a recent user-activation gesture. The old code did an async LV
    roundtrip first, which silently dropped the write in Safari/Firefox.
    Fix: prefetch the key on hook mount; click handler writes synchronously.
  * **Stale cache after Rotate** — the prefetched key was cached on the
    hook; rotating returned a new key but the cache wasn't refreshed, so
    Copy returned the old value. Fix: server emits `copy_api_key_set`
    after a successful rotate; hook updates its cache.

  Neither bug is reproducible in `LynxWeb.LiveCase` because the hook +
  clipboard layer don't run in the test process.
  """
  use LynxWeb.FeatureCase, async: false

  setup do
    mark_installed()
    user = create_user(%{api_key: "real-api-key-1234567890abcdef"})
    %{user: user}
  end

  test "Copy writes the real api_key to the system clipboard", %{conn: conn, user: user} do
    conn
    |> add_lynx_session(user)
    |> visit("/admin/profile")
    |> assert_has("h3", text: "API Key")
    |> click_button("Copy")
    |> assert_clipboard(user.api_key)
  end

  test "Show reveals the key inline and Hide re-masks it", %{conn: conn, user: user} do
    conn
    |> add_lynx_session(user)
    |> visit("/admin/profile")
    |> assert_has("h3", text: "API Key")
    |> click_button("Show")
    |> assert_has("#api-key-content", text: user.api_key)
    |> click_button("Hide")
    |> refute_has("#api-key-content", text: user.api_key)
  end

  test "Rotate then Copy returns the rotated key (regression for stale cache)", %{
    conn: conn,
    user: user
  } do
    old_key = user.api_key

    conn
    |> add_lynx_session(user)
    |> visit("/admin/profile")
    |> assert_has("h3", text: "API Key")
    |> click_button("Rotate")
    |> click_button("Confirm")
    |> assert_has("body", text: "API key rotated")
    |> click_button("Copy")
    |> refute_clipboard(old_key)
    |> assert_clipboard_matches(~r/^[0-9a-f-]{36,}$/i)
  end
end

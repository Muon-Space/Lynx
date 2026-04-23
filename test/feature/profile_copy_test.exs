defmodule LynxWeb.Feature.ProfileCopyTest do
  @moduledoc """
  Browser-driven coverage for the API Key Rotate + Copy flow on
  `/admin/profile`. After hashing (`api_key_hash`), the full plaintext
  is unrecoverable; the only path to a usable key is **Rotate**, which
  reveals the freshly-minted plaintext in a one-time banner with a
  Copy button. Drives the JS hook + clipboard layer that don't run in
  the LiveCase test process.
  """
  use LynxWeb.FeatureCase, async: false

  setup do
    mark_installed()
    user = create_user(%{api_key: "real-api-key-1234567890abcdef"})
    %{user: user}
  end

  test "page shows the prefix at rest, never the full key", %{conn: conn, user: user} do
    conn
    |> add_lynx_session(user)
    |> visit("/admin/profile")
    |> assert_has("h3", text: "API Key")
    |> assert_has("#api-key-prefix", text: user.api_key_prefix)
    |> refute_has("body", text: user.api_key)
  end

  test "Rotate reveals the new plaintext + Copy writes it to the clipboard",
       %{conn: conn, user: user} do
    old_key = user.api_key

    conn
    |> add_lynx_session(user)
    |> visit("/admin/profile")
    |> assert_has("h3", text: "API Key")
    |> click_button("Rotate")
    |> click_button("Confirm")
    |> assert_has("body", text: "API key rotated")
    |> assert_has("#revealed-api-key")
    |> click_button("Copy")
    # The clipboard now holds the new plaintext (UUID-shaped) — never
    # the pre-rotation value.
    |> refute_clipboard(old_key)
    |> assert_clipboard_matches(~r/^[0-9a-f-]{36,}$/i)
  end

  test "Dismissing the revealed-key banner removes the plaintext from the page",
       %{conn: conn, user: user} do
    conn
    |> add_lynx_session(user)
    |> visit("/admin/profile")
    |> click_button("Rotate")
    |> click_button("Confirm")
    |> assert_has("#revealed-api-key")
    |> click_button("I've saved it")
    |> refute_has("#revealed-api-key")
    # Page reverts to the prefix card. The prefix is the rotated key's
    # prefix now, so we don't assert on `user.api_key_prefix` (which was
    # the pre-rotation prefix); just confirm the prefix card came back.
    |> assert_has("#api-key-prefix")
  end
end

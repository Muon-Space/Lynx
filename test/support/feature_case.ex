defmodule LynxWeb.FeatureCase do
  @moduledoc """
  Test case for browser-driven feature tests via `PhoenixTest.Playwright`.

  Use this when an interaction can only be exercised in a real browser —
  colocated JS hooks, `navigator.clipboard` calls, focus/blur timing, etc.
  Anything that doesn't need a real browser belongs in `LynxWeb.LiveCase`,
  which is much faster.

  Imports the same factories `LynxWeb.LiveCase` exposes (`create_user`,
  `create_super`, `mark_installed`, …) so feature tests share the seed
  surface with the LV suite — no parallel fixture set to keep in sync.

  ## Auth

  `add_lynx_session(session, user)` writes the cookie that
  `LynxWeb.LiveAuth.assign_current_user/2` reads (session keys `uid` +
  `token`), using the same `AuthService.authenticate/1` path as
  `LynxWeb.LiveCase.log_in_user/2` — single source of truth for the
  session contract.

  ## Clipboard

  `assert_clipboard(session, expected)` and friends call into the browser
  via `PhoenixTest.Playwright.evaluate/3` to run
  `navigator.clipboard.readText()`. The browser context is launched with
  the `clipboard-read` permission (see `config :phoenix_test, ...` in
  `config/test.exs`); without it the read rejects.
  """

  use ExUnit.CaseTemplate

  alias Lynx.Service.AuthService

  using do
    quote do
      use PhoenixTest.Playwright.Case

      import LynxWeb.FeatureCase

      import LynxWeb.LiveCase,
        only: [
          create_user: 0,
          create_user: 1,
          create_super: 0,
          create_super: 1,
          create_workspace: 0,
          create_workspace: 1,
          create_project: 0,
          create_project: 1,
          create_env: 1,
          create_env: 2,
          create_state: 1,
          create_state: 2,
          create_lock: 1,
          create_lock: 2,
          mark_installed: 0,
          set_config: 2
        ]

      @moduletag :feature
    end
  end

  @doc """
  Adds the session cookie that `LynxWeb.LiveAuth` expects for `user`. Same
  contract as `LynxWeb.LiveCase.log_in_user/2` — produces a real session
  via `AuthService.authenticate/1` so revocation, invalidation, and
  `is_active` checks all work end-to-end.
  """
  def add_lynx_session(session, user) do
    {:success, auth_session} = AuthService.authenticate(user.id)

    PhoenixTest.Playwright.add_session_cookie(
      session,
      [value: %{uid: user.id, token: auth_session.value}],
      LynxWeb.Endpoint.session_options()
    )
  end

  @doc """
  Asserts the system clipboard's plain-text contents equal `expected`.
  Runs `navigator.clipboard.readText()` in the browser via PhoenixTest's
  `evaluate/3`. The browser context must have the `clipboard-read`
  permission (configured globally in `config/test.exs`).
  """
  def assert_clipboard(session, expected) do
    PhoenixTest.Playwright.evaluate(session, "navigator.clipboard.readText()", fn actual ->
      unless actual == expected do
        flunk("""
        Expected clipboard to contain:
          #{inspect(expected)}
        Got:
          #{inspect(actual)}
        """)
      end
    end)
  end

  @doc """
  Asserts the clipboard's contents do NOT equal `unexpected`. Useful for
  regression tests where a stale value would silently be copied.
  """
  def refute_clipboard(session, unexpected) do
    PhoenixTest.Playwright.evaluate(session, "navigator.clipboard.readText()", fn actual ->
      if actual == unexpected do
        flunk("Expected clipboard NOT to contain #{inspect(unexpected)}, but it did")
      end
    end)
  end

  @doc """
  Asserts the clipboard contents match `regex`.
  """
  def assert_clipboard_matches(session, %Regex{} = regex) do
    PhoenixTest.Playwright.evaluate(session, "navigator.clipboard.readText()", fn actual ->
      unless Regex.match?(regex, actual || "") do
        flunk("Expected clipboard to match #{inspect(regex)}, got #{inspect(actual)}")
      end
    end)
  end
end

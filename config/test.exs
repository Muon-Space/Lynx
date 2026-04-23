# Copyright 2023 Clivern. All rights reserved.
# Use of this source code is governed by the MIT
# license that can be found in the LICENSE file.

import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :lynx, Lynx.Repo,
  username: "lynx",
  password: "lynx",
  hostname: "localhost",
  database: "lynx_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

# `server: true` so PhoenixTest.Playwright (browser-driven feature tests)
# can hit a real port. ConnTest / LiveViewTest don't need it but tolerate it.
config :lynx, LynxWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "cBGndC+ZgHOIrWppfj45v3LYq7jFdXov339MuebP6HCEAEscZOUSkgC9y1YIZLmh",
  server: true

# Gates the `Phoenix.Ecto.SQL.Sandbox` plug in the endpoint so feature tests
# can share their sandboxed DB connection with the running server.
config :lynx, :sql_sandbox, true

# PhoenixTest.Playwright config — chromium headless; clipboard-read permission
# so feature tests can call `navigator.clipboard.readText()` to verify Copy
# actions. Trace artifacts on demand via `PW_TRACE=true`. Sandbox stop delay
# avoids `DBConnection.OwnershipError` on test exit while a LV is mid-render.
config :phoenix_test,
  otp_app: :lynx,
  endpoint: LynxWeb.Endpoint,
  playwright: [
    assets_dir: "./assets",
    browser: :chromium,
    headless: true,
    browser_context_opts: [permissions: ["clipboard-read", "clipboard-write"]],
    trace: System.get_env("PW_TRACE", "false") in ~w(t true),
    trace_dir: "tmp/playwright",
    ecto_sandbox_stop_owner_delay: 100
  ]

# In test we don't send emails.
config :lynx, Lynx.Mailer, adapter: Swoosh.Adapters.Test

# The grant-expiry sweeper runs on a 1-min timer in real envs; in tests it
# would interleave with sandboxed connections. Tests that exercise the
# sweeper start it explicitly via `start_supervised/2`.
config :lynx, :start_grant_sweeper, false

# Default the policy engine to the in-memory stub so unit tests don't need
# OPA on PATH. Integration tests tagged `:opa` swap to the real impl.
config :lynx, :policy_engine, Lynx.Service.PolicyEngine.Stub

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Copyright 2023 Clivern. All rights reserved.
# Use of this source code is governed by the MIT
# license that can be found in the LICENSE file.

# `:feature` tests drive a real browser via PhoenixTest.Playwright. Excluded
# from the default `mix test` run (~slow, needs `make playwright_install`);
# opt in with `mix test --only feature` (see `make feature_test`).
# `:opa` tests hit a real OPA daemon on localhost:8181. Excluded from the
# default `mix test` run; opt in with `mix test --only opa` (see
# `make ci_opa`). CI runs them in their own job so a flaky OPA install
# can't fail the unit suite.
ExUnit.start(exclude: [:feature, :opa])
Ecto.Adapters.SQL.Sandbox.mode(Lynx.Repo, :manual)

if :feature in ExUnit.configuration()[:include] do
  Application.put_env(:phoenix_test, :base_url, LynxWeb.Endpoint.url())
  {:ok, _} = PhoenixTest.Playwright.Supervisor.start_link()
end

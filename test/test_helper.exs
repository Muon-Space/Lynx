# Copyright 2023 Clivern. All rights reserved.
# Use of this source code is governed by the MIT
# license that can be found in the LICENSE file.

# `:feature` tests drive a real browser via PhoenixTest.Playwright. Excluded
# from the default `mix test` run (~slow, needs `make playwright_install`);
# opt in with `mix test --only feature` (see `make feature_test`).
ExUnit.start(exclude: [:feature])
Ecto.Adapters.SQL.Sandbox.mode(Lynx.Repo, :manual)

if :feature in ExUnit.configuration()[:include] do
  Application.put_env(:phoenix_test, :base_url, LynxWeb.Endpoint.url())
  {:ok, _} = PhoenixTest.Playwright.Supervisor.start_link()
end

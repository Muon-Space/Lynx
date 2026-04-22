# Copyright 2023 Clivern. All rights reserved.
# Use of this source code is governed by the MIT
# license that can be found in the LICENSE file.

defmodule Lynx.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Auto-instrumentation for Phoenix + Ecto. Both attach `:telemetry` handlers
    # that emit OTel spans for HTTP requests + DB queries respectively. Safe
    # to call unconditionally — when no OTLP endpoint is configured the SDK
    # is no-op (see `config/runtime.exs`).
    OpentelemetryPhoenix.setup(adapter: :bandit)
    OpentelemetryEcto.setup([:lynx, :repo])

    base = [
      # Start the Ecto repository
      Lynx.Repo,
      # Start the Telemetry supervisor
      LynxWeb.Telemetry,
      # Start the PubSub system
      {Phoenix.PubSub, name: Lynx.PubSub},
      # HTTP client for OIDC discovery/token exchange
      {Finch, name: Lynx.Finch},
      # Single-slot named lock used by LockModule to serialize lock
      # acquisition across concurrent TF requests. Owned by the supervisor
      # so it's created once at boot rather than re-initialized per call.
      %{
        id: :lynx_lock,
        start: {:sleeplocks, :start_link, [1, [name: :lynx_lock]]}
      },
      # Periodic sweeper for expired role grants (`expires_at`) — keeps
      # `project_teams` + `user_projects` clean and emits audit events.
      # Disabled in test (tests start it explicitly when they need it).
      sweeper_child()
    ]

    children = Enum.reject(base, &is_nil/1) ++ [LynxWeb.Endpoint]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Lynx.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    LynxWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  # In :test the sweeper is started by tests that need it (so its periodic
  # work doesn't interleave with sandboxed checkouts). Everywhere else it
  # runs at boot.
  defp sweeper_child do
    if Application.get_env(:lynx, :start_grant_sweeper, true) do
      Lynx.Worker.GrantExpirySweeper
    end
  end
end

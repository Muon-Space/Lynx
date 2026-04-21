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
    children =
      [
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
        # Start the Endpoint (http/https)
        LynxWeb.Endpoint
      ] ++ sso_children()

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Lynx.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp sso_children do
    if Application.get_env(:lynx, :auth_sso_enabled, false) and
         Application.get_env(:lynx, :sso_protocol, "oidc") == "oidc" do
      providers = Application.get_env(:lynx, :openid_connect_providers, [])
      [{OpenIDConnect.Worker, providers}]
    else
      []
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    LynxWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end

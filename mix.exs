# Copyright 2023 Clivern. All rights reserved.
# Use of this source code is governed by the MIT
# license that can be found in the LICENSE file.

defmodule Lynx.MixProject do
  use Mix.Project

  @version "1.17.0"

  def get_version, do: @version

  def project do
    [
      app: :lynx,
      version: @version,
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      test_coverage: [tool: ExCoveralls]
    ]
  end

  def cli do
    [
      preferred_envs: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.html": :test,
        "coveralls.json": :test,
        "coveralls.post": :test
      ]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Lynx.Application, []},
      extra_applications: [:logger, :runtime_tools, :os_mon]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:phoenix, "~> 1.8"},
      {:phoenix_ecto, "~> 4.6"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, "~> 0.22"},
      {:phoenix_html, "~> 4.3"},
      {:phoenix_live_reload, "~> 1.6", only: :dev},
      {:phoenix_live_view, "~> 1.1"},
      {:floki, "~> 0.38", only: :test},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:excoveralls, "~> 0.18", only: :test},
      {:phoenix_live_dashboard, "~> 0.8"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.3", runtime: Mix.env() == :dev},
      {:heroicons, "~> 0.5"},
      {:swoosh, "~> 1.25"},
      {:telemetry_metrics, "~> 1.1"},
      {:telemetry_poller, "~> 1.3"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.4"},
      {:nimble_csv, "~> 1.2"},
      {:open_api_spex, "~> 3.21"},
      {:ymlr, "~> 5.1"},
      {:plug_cowboy, "~> 2.8"},
      {:bandit, "~> 1.10"},
      {:bcrypt_elixir, "~> 3.3"},
      {:sleeplocks, "~> 1.1"},
      {:openid_connect, "~> 1.0"},
      {:samly, "~> 1.4"}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      coveralls: ["ecto.create --quiet", "ecto.migrate --quiet", "coveralls"],
      "coveralls.html": ["ecto.create --quiet", "ecto.migrate --quiet", "coveralls.html"]
      # "assets.deploy": ["esbuild default --minify", "phx.digest"]
    ]
  end
end

defmodule Mix.Tasks.Version do
  use Mix.Task

  def run(_) do
    Mix.shell().info("Currnt Version: v#{Lynx.MixProject.get_version()}")
  end
end

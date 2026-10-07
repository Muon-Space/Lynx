# Copyright 2023 Clivern. All rights reserved.
# Use of this source code is governed by the MIT
# license that can be found in the LICENSE file.

defmodule Lynx.Metrics do
  @moduledoc """
  Prometheus metrics for Terraform activity against Lynx-hosted state.

  `TfController` emits `[:lynx, :tf, *]` telemetry events; this module
  aggregates them and serves the result on `METRICS_PORT`. Nothing starts when
  the port is unset. The port is separate from the endpoint so `/metrics` is
  never reachable through whatever fronts the main HTTP port.
  """

  import Telemetry.Metrics

  @operations %{
    "OperationTypePlan" => "plan",
    "OperationTypeApply" => "apply",
    "OperationTypeRefresh" => "refresh"
  }

  # Lock hold time spans whole plan/apply runs, from seconds to an hour+.
  @held_buckets [1, 5, 15, 30, 60, 120, 300, 600, 1200, 1800, 3600, 7200]

  @path_tags [:workspace, :project, :environment, :unit]

  @doc """
  Children to add to the application supervisor: the aggregator plus its HTTP
  listener, or none when no port is configured.
  """
  def children do
    case Application.get_env(:lynx, :metrics_port) do
      nil ->
        []

      port ->
        [
          {TelemetryMetricsPrometheus.Core, name: __MODULE__, metrics: metrics()},
          {Bandit, plug: Lynx.Metrics.Plug, port: port, startup_log: false}
        ]
    end
  end

  def scrape, do: TelemetryMetricsPrometheus.Core.scrape(__MODULE__)

  def metrics do
    [
      counter("lynx.tf.locks.total",
        event_name: [:lynx, :tf, :lock],
        tags: @path_tags ++ [:operation, :result],
        description: "Terraform lock requests, by normalized operation and result"
      ),
      distribution("lynx.tf.lock_held.seconds",
        event_name: [:lynx, :tf, :unlock],
        measurement: :held_seconds,
        tags: [:workspace, :project, :operation],
        reporter_options: [buckets: @held_buckets],
        description: "Seconds a Terraform lock was held before unlock (run duration)"
      ),
      counter("lynx.tf.state_writes.total",
        event_name: [:lynx, :tf, :state_write],
        tags: @path_tags,
        description: "Terraform state writes persisted"
      ),
      counter("lynx.tf.apply_blocked.total",
        event_name: [:lynx, :tf, :apply_blocked],
        tags: [:workspace, :project, :environment, :gate],
        description: "State writes refused by the plan gate or a policy violation"
      ),
      counter("lynx.tf.plan_checks.total",
        event_name: [:lynx, :tf, :plan_check],
        tags: [:workspace, :project, :environment, :outcome],
        description: "Plan checks evaluated, by outcome"
      )
    ]
  end

  @doc """
  Map Terraform's client-supplied `Operation` to a bounded label value.
  """
  def operation_label(operation), do: Map.get(@operations, operation, "other")

  def path_metadata(w_slug, p_slug, e_slug, sub_path) do
    %{workspace: w_slug, project: p_slug, environment: e_slug, unit: sub_path}
  end

  def emit(event, measurements \\ %{}, metadata) do
    :telemetry.execute([:lynx, :tf, event], measurements, metadata)
  end
end

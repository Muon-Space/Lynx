# Copyright 2023 Clivern. All rights reserved.
# Use of this source code is governed by the MIT
# license that can be found in the LICENSE file.

defmodule Lynx.Worker.SnapshotWorker do
  use GenServer

  require Logger
  require OpenTelemetry.Tracer, as: Tracer

  def start_link(state) do
    GenServer.start_link(__MODULE__, state, name: __MODULE__)
  end

  ## Callbacks
  @impl true
  def init(state) do
    Logger.info("Snapshot Worker Started")

    schedule_work()

    {:ok, state}
  end

  @impl true
  def handle_info(:fire, state) do
    # Process any create snapshot request
    create_snapshots()

    # Process any restore request
    restore_snapshots()

    # Reschedule once more
    schedule_work()

    {:noreply, state}
  end

  # Spans wrap the entry points even though the bodies are stubs today —
  # when the real long-running work lands the trace is already in place.
  defp create_snapshots do
    Tracer.with_span "lynx.snapshot_worker.create_snapshots" do
      Logger.info("Create any Outstanding Snapshot")
    end
  end

  defp restore_snapshots do
    Tracer.with_span "lynx.snapshot_worker.restore_snapshots" do
      Logger.info("Restore any Outstanding Snapshot")
    end
  end

  defp schedule_work do
    # We schedule the work to happen in 10 seconds
    Process.send_after(self(), :fire, 60 * 1000)
  end
end

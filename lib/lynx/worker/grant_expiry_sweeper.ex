defmodule Lynx.Worker.GrantExpirySweeper do
  @moduledoc """
  Periodic sweeper that deletes expired role grants from `project_teams` and
  `user_projects` and emits an audit event for each.

  Lookup-time filtering in `Lynx.Context.RoleContext` already prevents
  expired grants from being honored — this worker exists to keep the table
  clean and to emit the audit trail. Runs every minute by default.

  No external scheduler dependency: uses `Process.send_after/3` for the
  next tick. Survives crashes via the supervision tree.
  """
  use GenServer
  require Logger

  import Ecto.Query

  alias Lynx.Context.AuditContext
  alias Lynx.Model.{ProjectTeam, UserProject}
  alias Lynx.Repo

  @default_interval :timer.minutes(1)

  # -- Client --

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Run a sweep right now (mainly for tests and manual ops).
  Returns `{deleted_pt, deleted_up}`.
  """
  def sweep_now do
    GenServer.call(__MODULE__, :sweep)
  end

  # -- Server --

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval, @default_interval)
    schedule(interval)
    {:ok, %{interval: interval}}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep()
    schedule(state.interval)
    {:noreply, state}
  end

  @impl true
  def handle_call(:sweep, _from, state) do
    {:reply, sweep(), state}
  end

  defp schedule(interval) when interval > 0 do
    Process.send_after(self(), :sweep, interval)
  end

  defp schedule(_), do: :ok

  # -- Sweep impl --

  defp sweep do
    now = DateTime.utc_now()

    {pt_count, pts} = expired_project_teams(now)
    {up_count, ups} = expired_user_projects(now)

    if pt_count > 0 or up_count > 0 do
      Logger.info(
        "Grant sweeper deleted #{pt_count} project_team(s) + #{up_count} user_project(s)"
      )
    end

    Enum.each(pts || [], fn pt ->
      AuditContext.log_system("expired", "project_team", pt.uuid)
    end)

    Enum.each(ups || [], fn up ->
      AuditContext.log_system("expired", "user_project", up.uuid)
    end)

    {pt_count, up_count}
  end

  defp expired_project_teams(now) do
    expired =
      from(pt in ProjectTeam,
        where: not is_nil(pt.expires_at) and pt.expires_at <= ^now
      )
      |> Repo.all()

    if expired != [] do
      ids = Enum.map(expired, & &1.id)

      {count, _} =
        from(pt in ProjectTeam, where: pt.id in ^ids)
        |> Repo.delete_all()

      {count, expired}
    else
      {0, []}
    end
  end

  defp expired_user_projects(now) do
    expired =
      from(up in UserProject,
        where: not is_nil(up.expires_at) and up.expires_at <= ^now
      )
      |> Repo.all()

    if expired != [] do
      ids = Enum.map(expired, & &1.id)

      {count, _} =
        from(up in UserProject, where: up.id in ^ids)
        |> Repo.delete_all()

      {count, expired}
    else
      {0, []}
    end
  end
end

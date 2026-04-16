defmodule LynxWeb.SnapshotsLive do
  use LynxWeb, :live_view

  alias Lynx.Module.SnapshotModule
  alias Lynx.Module.ProjectModule
  alias Lynx.Module.TeamModule
  alias Lynx.Module.AuditModule

  on_mount {LynxWeb.LiveAuth, :require_auth}

  @per_page 10

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    all_teams =
      if user.role == "super",
        do: TeamModule.get_teams(0, 10000),
        else: TeamModule.get_user_teams(user.id, 0, 10000)

    all_projects =
      if user.role == "super",
        do: ProjectModule.get_projects(0, 10000),
        else: ProjectModule.get_projects(user.id, 0, 10000)

    socket =
      socket
      |> assign(:page, 1)
      |> assign(:show_add, false)
      |> assign(:all_teams, all_teams)
      |> assign(:all_projects, all_projects)
      |> assign(:confirm, nil)
      |> load_snapshots()

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.confirm_dialog :if={@confirm} message={@confirm.message} confirm_event={@confirm.event} confirm_value={@confirm.value} />
    <.nav current_user={@current_user} active="snapshots" />
    <div class="max-w-7xl mx-auto px-6">
      <.page_header title="Snapshots" subtitle="Back up and restore project state" />

      <div class="flex justify-end mb-4">
        <.button phx-click="show_add" variant="primary">+ Create Snapshot</.button>
      </div>

      <.modal :if={@show_add} id="add-snapshot" show on_close="hide_add">
        <h3 class="text-lg font-semibold mb-4">Create Snapshot</h3>
        <form phx-submit="create_snapshot" class="space-y-4">
          <.input name="title" label="Title" value="" required />
          <.input name="description" label="Description" type="textarea" value="" required />
          <.input name="team_id" label="Team" type="select" prompt="Select team" options={Enum.map(@all_teams, &{&1.name, &1.uuid})} value="" required />
          <.input name="record_type" label="Scope" type="select" options={[{"Project (all environments)", "project"}, {"Single Environment", "environment"}]} value="project" />
          <.input name="record_uuid" label="Project" type="select" prompt="Select project" options={Enum.map(@all_projects, &{&1.name, &1.uuid})} value="" required />
          <div class="flex gap-3 pt-2">
            <.button type="submit" variant="primary">Create</.button>
            <.button phx-click="hide_add" variant="secondary">Cancel</.button>
          </div>
        </form>
      </.modal>

      <.card>
        <.table rows={@snapshots}>
          <:col :let={s} label="Title">{s.title}</:col>
          <:col :let={s} label="Type">
            <.badge color={if s.record_type == "project", do: "blue", else: "purple"}>{s.record_type}</.badge>
          </:col>
          <:col :let={s} label="Status">
            <.badge color={if s.status == "success", do: "green", else: "yellow"}>{s.status}</.badge>
          </:col>
          <:col :let={s} label="Created">
            <span class="text-xs text-gray-500">{Calendar.strftime(s.inserted_at, "%Y-%m-%d %H:%M")}</span>
          </:col>
          <:action :let={s}>
            <.button phx-click="confirm_action" phx-value-event="restore_snapshot" phx-value-message="Restore this snapshot? This will overwrite current environments." phx-value-uuid={s.uuid} variant="ghost" size="sm">Restore</.button>
            <.button phx-click="confirm_action" phx-value-event="delete_snapshot" phx-value-message="Delete this snapshot?" phx-value-uuid={s.uuid} variant="ghost" size="sm">Delete</.button>
          </:action>
        </.table>
        <.pagination page={@page} total_pages={@total_pages} />
      </.card>
    </div>
    """
  end

  @impl true
  def handle_event("confirm_action", params, socket) do
    {:noreply,
     assign(socket, :confirm, %{
       message: params["message"],
       event: params["event"],
       value: %{uuid: params["uuid"]}
     })}
  end

  def handle_event("cancel_confirm", _, socket), do: {:noreply, assign(socket, :confirm, nil)}

  def handle_event("show_add", _, socket), do: {:noreply, assign(socket, :show_add, true)}
  def handle_event("hide_add", _, socket), do: {:noreply, assign(socket, :show_add, false)}

  def handle_event("create_snapshot", params, socket) do
    case SnapshotModule.take_snapshot(params["record_type"], params["record_uuid"]) do
      {:ok, data} ->
        case SnapshotModule.create_snapshot(%{
               title: params["title"],
               description: params["description"],
               record_type: params["record_type"],
               record_uuid: params["record_uuid"],
               status: "success",
               data: data,
               team_id: params["team_id"]
             }) do
          {:ok, snapshot} ->
            AuditModule.log_system("created", "snapshot", snapshot.uuid, snapshot.title)

            {:noreply,
             socket
             |> assign(:show_add, false)
             |> put_flash(:info, "Snapshot created")
             |> load_snapshots()}

          {:error, msg} ->
            {:noreply, put_flash(socket, :error, msg)}
        end

      {:error, msg} ->
        {:noreply, put_flash(socket, :error, msg)}
    end
  end

  def handle_event("restore_snapshot", %{"uuid" => uuid}, socket) do
    socket = assign(socket, :confirm, nil)

    case SnapshotModule.restore_snapshot(uuid) do
      {:ok, _} -> {:noreply, put_flash(socket, :info, "Snapshot restored successfully")}
      {:error, msg} -> {:noreply, put_flash(socket, :error, msg)}
    end
  end

  def handle_event("delete_snapshot", %{"uuid" => uuid}, socket) do
    socket = assign(socket, :confirm, nil)

    case SnapshotModule.delete_snapshot_by_uuid(uuid) do
      {:ok, _} -> {:noreply, socket |> put_flash(:info, "Snapshot deleted") |> load_snapshots()}
      _ -> {:noreply, put_flash(socket, :error, "Failed to delete")}
    end
  end

  def handle_event("next_page", _, socket) do
    if socket.assigns.page < socket.assigns.total_pages,
      do: {:noreply, socket |> assign(:page, socket.assigns.page + 1) |> load_snapshots()},
      else: {:noreply, socket}
  end

  def handle_event("prev_page", _, socket) do
    if socket.assigns.page > 1,
      do: {:noreply, socket |> assign(:page, socket.assigns.page - 1) |> load_snapshots()},
      else: {:noreply, socket}
  end

  defp load_snapshots(socket) do
    user = socket.assigns.current_user
    offset = (socket.assigns.page - 1) * @per_page

    {snapshots, total} =
      if user.role == "super" do
        {SnapshotModule.get_snapshots(offset, @per_page), SnapshotModule.count_snapshots()}
      else
        {SnapshotModule.get_snapshots(user.id, offset, @per_page),
         SnapshotModule.count_snapshots(user.id)}
      end

    assign(socket, snapshots: snapshots, total_pages: max(ceil(total / @per_page), 1))
  end
end

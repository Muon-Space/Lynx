defmodule LynxWeb.SnapshotsLive do
  use LynxWeb, :live_view

  alias Lynx.Module.SnapshotModule
  alias Lynx.Module.ProjectModule
  alias Lynx.Module.AuditModule

  on_mount {LynxWeb.LiveAuth, :require_auth}

  @per_page 10

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    all_workspaces = Lynx.Context.WorkspaceContext.get_workspaces(0, 10000)

    all_projects =
      if user.role == "super",
        do: ProjectModule.get_projects(0, 10000),
        else: ProjectModule.get_projects(user.id, 0, 10000)

    socket =
      socket
      |> assign(:page, 1)
      |> assign(:show_add, false)
      |> assign(:all_workspaces, all_workspaces)
      |> assign(:all_projects, all_projects)
      |> assign(:filtered_projects, all_projects)
      |> assign(:snapshot_scope, "project")
      |> assign(:snapshot_workspace_id, nil)
      |> assign(:snapshot_project_uuid, nil)
      |> assign(:snapshot_envs, [])
      |> assign(:snapshot_env_uuid, nil)
      |> assign(:snapshot_units, [])
      |> assign(:snapshot_unit_path, nil)
      |> assign(:confirm, nil)
      |> load_snapshots()

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.confirm_dialog :if={@confirm} message={@confirm.message} confirm_event={@confirm.event} confirm_value={@confirm.value} />
    <.nav current_user={@current_user} active="snapshots" />
    <div class="max-w-7xl mx-auto px-6 pb-16">
      <.page_header title="Snapshots" subtitle="Back up and restore project state" />

      <div class="flex justify-end mb-4">
        <.button phx-click="show_add" variant="primary">+ Create Snapshot</.button>
      </div>

      <.modal :if={@show_add} id="add-snapshot" show on_close="hide_add">
        <h3 class="text-lg font-semibold mb-4">Create Snapshot</h3>
        <form phx-submit="create_snapshot" phx-change="snapshot_form_change" class="space-y-4">
          <.input name="title" label="Title" value="" required />
          <.input name="description" label="Description" type="textarea" value="" required />

          <.input name="workspace_id" id="snapshot-workspace" label="Workspace" type="select" prompt="Select workspace" options={Enum.map(@all_workspaces, &{&1.name, to_string(&1.id)})} value={@snapshot_workspace_id || ""} required />

          <div :if={@snapshot_workspace_id && @snapshot_workspace_id != ""}>
            <.input name="project_uuid" id={"snapshot-project-#{@snapshot_workspace_id}"} label="Project" type="select" prompt="Select project" options={Enum.map(@filtered_projects, &{&1.name, &1.uuid})} value={@snapshot_project_uuid || ""} required />
          </div>

          <div :if={@snapshot_project_uuid && @snapshot_project_uuid != ""}>
            <.input name="env_uuid" id={"snapshot-env-#{@snapshot_project_uuid}"} label="Environment" type="select" prompt="All Environments" options={Enum.map(@snapshot_envs, &{&1.name, &1.uuid})} value={@snapshot_env_uuid || ""} />
          </div>

          <div :if={@snapshot_project_uuid && @snapshot_project_uuid != "" && @snapshot_env_uuid && @snapshot_env_uuid != ""}>
            <.input name="unit_path" id={"snapshot-unit-#{@snapshot_env_uuid}"} label="Unit" type="select" prompt="All Units" options={Enum.map(@snapshot_units, &{if(&1.sub_path == "", do: "(root)", else: &1.sub_path), &1.sub_path})} value={@snapshot_unit_path || ""} />
          </div>

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
            <span class="text-xs text-muted">{Calendar.strftime(s.inserted_at, "%Y-%m-%d %H:%M")}</span>
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

  def handle_event("show_add", _, socket) do
    {:noreply,
     assign(socket,
       show_add: true,
       snapshot_workspace_id: nil,
       snapshot_project_uuid: nil,
       filtered_projects: socket.assigns.all_projects,
       snapshot_envs: [],
       snapshot_env_uuid: nil,
       snapshot_units: [],
       snapshot_unit_path: nil
     )}
  end

  def handle_event("hide_add", _, socket), do: {:noreply, assign(socket, :show_add, false)}

  def handle_event("snapshot_form_change", params, socket) do
    workspace_id = params["workspace_id"]
    project_uuid = params["project_uuid"]
    env_uuid = params["env_uuid"]
    unit_path = params["unit_path"]

    filtered_projects =
      if workspace_id && workspace_id != "" do
        ws_id = String.to_integer(workspace_id)
        Enum.filter(socket.assigns.all_projects, &(&1.workspace_id == ws_id))
      else
        socket.assigns.all_projects
      end

    envs =
      if project_uuid && project_uuid != "" do
        case Lynx.Context.ProjectContext.get_project_by_uuid(project_uuid) do
          nil -> []
          project -> Lynx.Context.EnvironmentContext.get_project_envs(project.id, 0, 10000)
        end
      else
        []
      end

    units =
      if env_uuid && env_uuid != "" do
        case Lynx.Context.EnvironmentContext.get_env_by_uuid(env_uuid) do
          nil -> []
          env -> Lynx.Context.StateContext.list_sub_paths(env.id)
        end
      else
        []
      end

    {:noreply,
     socket
     |> assign(:snapshot_workspace_id, workspace_id)
     |> assign(:snapshot_project_uuid, project_uuid)
     |> assign(:filtered_projects, filtered_projects)
     |> assign(:snapshot_envs, envs)
     |> assign(:snapshot_env_uuid, env_uuid)
     |> assign(:snapshot_units, units)
     |> assign(:snapshot_unit_path, unit_path)}
  end

  def handle_event("create_snapshot", params, socket) do
    project_uuid = params["project_uuid"]
    env_uuid = params["env_uuid"]
    unit_path = params["unit_path"]

    {record_type, record_uuid, snapshot_opts} =
      cond do
        unit_path && unit_path != "" ->
          {"unit", env_uuid, %{sub_path: unit_path}}

        env_uuid && env_uuid != "" ->
          {"environment", env_uuid, %{}}

        true ->
          {"project", project_uuid, %{}}
      end

    teams =
      case Lynx.Context.ProjectContext.get_project_by_uuid(project_uuid) do
        nil -> []
        project -> Lynx.Module.ProjectModule.get_project_teams(project.id)
      end

    first_team_uuid = if teams != [], do: hd(teams).uuid, else: nil

    case SnapshotModule.take_snapshot(record_type, record_uuid, snapshot_opts) do
      {:ok, data} ->
        case SnapshotModule.create_snapshot(%{
               title: params["title"],
               description: params["description"],
               record_type: params["record_type"],
               record_uuid: record_uuid,
               status: "success",
               data: data,
               team_id: first_team_uuid
             }) do
          {:ok, snapshot} ->
            AuditModule.log_user(
              socket.assigns.current_user,
              "created",
              "snapshot",
              snapshot.uuid,
              snapshot.title
            )

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

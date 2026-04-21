defmodule LynxWeb.SnapshotsLive do
  use LynxWeb, :live_view

  alias Lynx.Context.SnapshotContext
  alias Lynx.Context.ProjectContext
  alias Lynx.Context.AuditContext
  alias Lynx.Context.RoleContext

  @per_page 10

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:show_add, false)
      |> assign(:workspace_options, workspace_options(""))
      |> assign(:project_options, project_options(socket.assigns.current_user, "", nil))
      |> assign(:snapshot_scope, "project")
      |> assign(:selected_workspace, nil)
      |> assign(:selected_project, nil)
      |> assign(:snapshot_envs, [])
      |> assign(:snapshot_env_uuid, nil)
      |> assign(:snapshot_units, [])
      |> assign(:snapshot_unit_path, nil)
      |> assign(:snapshot_unit_versions, [])
      |> assign(:snapshot_unit_version, nil)
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

          <.combobox id="snapshot-workspace" name="workspace_id" label="Workspace" options={@workspace_options} selected={@selected_workspace} prompt="Select workspace" required />

          <div :if={@selected_workspace}>
            <.combobox id={"snapshot-project-#{workspace_value(@selected_workspace)}"} name="project_uuid" label="Project" options={@project_options} selected={@selected_project} prompt="Select project" required />
          </div>

          <div :if={@selected_project}>
            <.input name="env_uuid" id={"snapshot-env-#{project_value(@selected_project)}"} label="Environment" type="select" prompt="All Environments" options={Enum.map(@snapshot_envs, &{&1.name, &1.uuid})} value={@snapshot_env_uuid || ""} />
          </div>

          <div :if={@selected_project && @snapshot_env_uuid && @snapshot_env_uuid != ""}>
            <.input name="unit_path" id={"snapshot-unit-#{@snapshot_env_uuid}"} label="Unit" type="select" prompt="All Units" options={Enum.map(@snapshot_units, &{if(&1.sub_path == "", do: "(root)", else: &1.sub_path), &1.sub_path})} value={@snapshot_unit_path || ""} />
          </div>

          <div :if={@snapshot_unit_path && @snapshot_unit_path != "" && @snapshot_unit_versions != []}>
            <% max_v = if @snapshot_unit_versions != [], do: elem(hd(@snapshot_unit_versions), 1), else: 0 %>
            <.input name="unit_version" id={"snapshot-version-#{@snapshot_env_uuid}-#{@snapshot_unit_path}"} label="Version" type="select" options={Enum.map(@snapshot_unit_versions, fn {s, idx} -> {"v#{idx}#{if idx == max_v, do: " (Current)", else: ""} — #{Calendar.strftime(s.inserted_at, "%Y-%m-%d %H:%M:%S")}", to_string(idx)} end)} value={to_string(@snapshot_unit_version || max_v)} />
          </div>

          <div class="flex gap-3 pt-2 mb-40">
            <.button type="submit" variant="primary">Create</.button>
            <.button phx-click="hide_add" variant="secondary">Cancel</.button>
          </div>
        </form>
      </.modal>

      <.card>
        <div class="overflow-x-auto">
          <table class="w-full text-sm">
            <thead class="border-b border-border text-left text-secondary font-medium">
              <tr>
                <th class="px-4 py-3">Title</th>
                <th class="px-4 py-3">Scope</th>
                <th class="px-4 py-3">Target</th>
                <th class="px-4 py-3">Status</th>
                <th class="px-4 py-3">Created</th>
                <th class="px-4 py-3">Actions</th>
              </tr>
            </thead>
            <tbody id="snapshots-list" phx-update="stream">
              <tr :for={{dom_id, s} <- @streams.snapshots} id={dom_id} class="border-b border-border hover:bg-surface-secondary cursor-pointer">
                <td class="px-4 py-3" phx-click={JS.push("view_snapshot", value: %{uuid: s.uuid})}>
                  <span class="font-medium text-clickable">{s.title}</span>
                </td>
                <td class="px-4 py-3" phx-click={JS.push("view_snapshot", value: %{uuid: s.uuid})}>
                  <.badge color={snapshot_badge_color(s.record_type)}>{s.record_type}</.badge>
                </td>
                <td class="px-4 py-3" phx-click={JS.push("view_snapshot", value: %{uuid: s.uuid})}>
                  <span class="text-xs">{snapshot_target(s)}</span>
                </td>
                <td class="px-4 py-3" phx-click={JS.push("view_snapshot", value: %{uuid: s.uuid})}>
                  <.badge color={if s.status == "success", do: "green", else: "yellow"}>{s.status}</.badge>
                </td>
                <td class="px-4 py-3" phx-click={JS.push("view_snapshot", value: %{uuid: s.uuid})}>
                  <span class="text-xs text-muted">{Calendar.strftime(s.inserted_at, "%Y-%m-%d %H:%M")}</span>
                </td>
                <td class="px-4 py-3">
                  <div class="flex gap-2">
                    <.button phx-click="confirm_action" phx-value-event="restore_snapshot" phx-value-message="Restore this snapshot? This will overwrite current state." phx-value-uuid={s.uuid} variant="ghost" size="sm">Restore</.button>
                    <.button phx-click="confirm_action" phx-value-event="delete_snapshot" phx-value-message="Delete this snapshot?" phx-value-uuid={s.uuid} variant="ghost" size="sm">Delete</.button>
                  </div>
                </td>
              </tr>
            </tbody>
          </table>
          <div :if={@empty?} class="px-4 py-8 text-center text-muted">No records found.</div>
        </div>

        <div :if={@has_more?} class="flex justify-center mt-4">
          <button phx-click="load_more" class="px-4 py-2 text-sm rounded-lg border border-border-input text-secondary hover:bg-surface-secondary">
            Load more
          </button>
        </div>
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
       selected_workspace: nil,
       selected_project: nil,
       workspace_options: workspace_options(""),
       project_options: project_options(socket.assigns.current_user, "", nil),
       snapshot_envs: [],
       snapshot_env_uuid: nil,
       snapshot_units: [],
       snapshot_unit_path: nil,
       snapshot_unit_versions: [],
       snapshot_unit_version: nil
     )}
  end

  def handle_event("hide_add", _, socket), do: {:noreply, assign(socket, :show_add, false)}

  def handle_event("view_snapshot", %{"uuid" => uuid}, socket) do
    {:noreply, push_navigate(socket, to: "/admin/snapshots/#{uuid}")}
  end

  def handle_event("snapshot_form_change", params, socket) do
    user = socket.assigns.current_user
    workspace_id = params["workspace_id"]
    project_uuid = params["project_uuid"]
    env_uuid = params["env_uuid"]

    workspace_changed = workspace_id != workspace_value(socket.assigns.selected_workspace)
    project_changed = project_uuid != project_value(socket.assigns.selected_project)
    env_changed = env_uuid != socket.assigns.snapshot_env_uuid

    project_uuid = if workspace_changed, do: nil, else: project_uuid
    env_uuid = if workspace_changed or project_changed, do: nil, else: env_uuid
    unit_path = if env_changed, do: nil, else: params["unit_path"]

    selected_workspace = lookup_workspace(workspace_id, socket.assigns.selected_workspace)
    workspace_db_id = selected_workspace && elem(selected_workspace, 1)

    selected_project =
      if project_uuid && project_uuid != "" do
        case ProjectContext.get_project_by_uuid(project_uuid) do
          nil -> nil
          p -> {p.name, p.uuid}
        end
      else
        nil
      end

    workspace_query = params["_q_workspace_id"] || ""
    project_query = params["_q_project_uuid"] || ""

    workspace_options = workspace_options(workspace_query)
    project_options = project_options(user, project_query, workspace_db_id)

    envs =
      if project_uuid && project_uuid != "" do
        case ProjectContext.get_project_by_uuid(project_uuid) do
          nil ->
            []

          project ->
            Lynx.Context.EnvironmentContext.get_project_envs(
              project.id,
              0,
              LynxWeb.Limits.child_collection_max()
            )
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

    unit_versions =
      if unit_path && unit_path != "" && env_uuid && env_uuid != "" do
        case Lynx.Context.EnvironmentContext.get_env_by_uuid(env_uuid) do
          nil ->
            []

          env ->
            Lynx.Context.StateContext.get_states_by_environment_id(env.id)
            |> Enum.filter(&(Map.get(&1, :sub_path, "") == unit_path))
            |> Enum.sort_by(& &1.id)
            |> Enum.with_index(1)
            |> Enum.reverse()
        end
      else
        []
      end

    unit_version = params["unit_version"]

    {:noreply,
     socket
     |> assign(:selected_workspace, selected_workspace)
     |> assign(:selected_project, selected_project)
     |> assign(:workspace_options, workspace_options)
     |> assign(:project_options, project_options)
     |> assign(:snapshot_envs, envs)
     |> assign(:snapshot_env_uuid, env_uuid)
     |> assign(:snapshot_units, units)
     |> assign(:snapshot_unit_path, unit_path)
     |> assign(:snapshot_unit_versions, unit_versions)
     |> assign(:snapshot_unit_version, unit_version)}
  end

  def handle_event("create_snapshot", params, socket) do
    project_uuid = params["project_uuid"]
    env_uuid = params["env_uuid"]
    unit_path = params["unit_path"]
    unit_version = params["unit_version"]

    {record_type, record_uuid, snapshot_opts} =
      cond do
        unit_path && unit_path != "" ->
          opts = %{sub_path: unit_path}

          opts =
            if unit_version && unit_version != "" do
              version_idx = String.to_integer(unit_version)

              version_state =
                Enum.find(socket.assigns.snapshot_unit_versions, fn {_s, idx} ->
                  idx == version_idx
                end)

              case version_state do
                {state, _} -> Map.put(opts, :version_id, state.id)
                _ -> opts
              end
            else
              opts
            end

          {"unit", env_uuid, opts}

        env_uuid && env_uuid != "" ->
          {"environment", env_uuid, %{}}

        true ->
          {"project", project_uuid, %{}}
      end

    teams =
      case Lynx.Context.ProjectContext.get_project_by_uuid(project_uuid) do
        nil -> []
        project -> Lynx.Context.ProjectContext.get_project_teams(project.id)
      end

    first_team_uuid = if teams != [], do: hd(teams).uuid, else: nil

    case SnapshotContext.take_snapshot(record_type, record_uuid, snapshot_opts) do
      {:ok, data} ->
        case SnapshotContext.create_snapshot_from_data(%{
               title: params["title"],
               description: params["description"],
               record_type: record_type,
               record_uuid: record_uuid,
               status: "success",
               data: data,
               team_id: first_team_uuid
             }) do
          {:ok, snapshot} ->
            AuditContext.log_user(
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
    user = socket.assigns.current_user

    with {:snapshot, %{} = snapshot} <-
           {:snapshot, SnapshotContext.get_snapshot_by_uuid(uuid)},
         {:project, %{} = project} <-
           {:project, SnapshotContext.get_project_for_snapshot(snapshot)},
         true <- RoleContext.can?(user, project, "snapshot:restore") do
      case SnapshotContext.restore_snapshot(uuid) do
        {:ok, _} -> {:noreply, put_flash(socket, :info, "Snapshot restored successfully")}
        {:error, msg} -> {:noreply, put_flash(socket, :error, msg)}
      end
    else
      false ->
        {:noreply,
         put_flash(socket, :error, "You do not have permission to restore this snapshot")}

      {:snapshot, nil} ->
        {:noreply, put_flash(socket, :error, "Snapshot not found")}

      {:project, nil} ->
        {:noreply, put_flash(socket, :error, "Project for snapshot not found")}
    end
  end

  def handle_event("delete_snapshot", %{"uuid" => uuid}, socket) do
    socket = assign(socket, :confirm, nil)

    case SnapshotContext.delete_snapshot_by_uuid(uuid) do
      {:ok, _} -> {:noreply, socket |> put_flash(:info, "Snapshot deleted") |> load_snapshots()}
      _ -> {:noreply, put_flash(socket, :error, "Failed to delete")}
    end
  end

  def handle_event("load_more", _, socket) do
    {snapshots, total} = fetch_snapshots(socket, socket.assigns.next_offset)
    new_offset = socket.assigns.next_offset + length(snapshots)

    {:noreply,
     socket
     |> stream(:snapshots, snapshots)
     |> assign(:next_offset, new_offset)
     |> assign(:has_more?, new_offset < total)}
  end

  defp workspace_value(nil), do: ""
  defp workspace_value({_label, id}), do: to_string(id)

  defp project_value(nil), do: ""
  defp project_value({_label, uuid}), do: uuid

  defp lookup_workspace("", _), do: nil
  defp lookup_workspace(nil, _), do: nil

  defp lookup_workspace(id_str, current) do
    cond do
      current && to_string(elem(current, 1)) == id_str ->
        current

      true ->
        case Integer.parse(id_str) do
          {id, _} ->
            case Lynx.Context.WorkspaceContext.get_workspace_by_id(id) do
              nil -> nil
              ws -> {ws.name, ws.id}
            end

          _ ->
            nil
        end
    end
  end

  defp workspace_options(query) do
    Lynx.Context.WorkspaceContext.search_workspaces(query)
    |> Enum.map(&{&1.name, to_string(&1.id)})
  end

  defp project_options(user, query, workspace_db_id) do
    matches =
      cond do
        user.role == "super" -> ProjectContext.search_projects(query)
        true -> ProjectContext.search_projects_for_user(user.id, query)
      end

    matches =
      if workspace_db_id,
        do: Enum.filter(matches, &(&1.workspace_id == workspace_db_id)),
        else: matches

    Enum.map(matches, &{&1.name, &1.uuid})
  end

  defp load_snapshots(socket) do
    {snapshots, total} = fetch_snapshots(socket, 0)

    socket
    |> stream(:snapshots, snapshots, reset: true)
    |> assign(:next_offset, length(snapshots))
    |> assign(:has_more?, length(snapshots) < total)
    |> assign(:empty?, snapshots == [])
  end

  defp fetch_snapshots(socket, offset) do
    user = socket.assigns.current_user

    if user.role == "super" do
      {SnapshotContext.get_snapshots(offset, @per_page), SnapshotContext.count_snapshots()}
    else
      {SnapshotContext.get_snapshots_for_user(user.id, offset, @per_page),
       SnapshotContext.count_snapshots_for_user(user.id)}
    end
  end

  defp snapshot_badge_color("project"), do: "blue"
  defp snapshot_badge_color("environment"), do: "purple"
  defp snapshot_badge_color("unit"), do: "yellow"
  defp snapshot_badge_color(_), do: "gray"

  defp snapshot_target(snapshot) do
    case Jason.decode(snapshot.data || "{}") do
      {:ok, parsed} ->
        project_name = parsed["name"] || ""
        envs = parsed["environments"] || []
        env_names = Enum.map(envs, & &1["name"]) |> Enum.join(", ")

        case snapshot.record_type do
          "project" ->
            project_name

          "environment" ->
            "#{project_name} / #{env_names}"

          "unit" ->
            unit_path =
              case envs do
                [env | _] ->
                  (env["states"] || [])
                  |> Enum.map(& &1["sub_path"])
                  |> Enum.uniq()
                  |> Enum.reject(&(&1 == "" || is_nil(&1)))
                  |> Enum.join(", ")

                _ ->
                  ""
              end

            path_label = if unit_path == "", do: "(root)", else: unit_path
            "#{project_name} / #{env_names} / #{path_label}"

          _ ->
            ""
        end

      _ ->
        ""
    end
  end
end

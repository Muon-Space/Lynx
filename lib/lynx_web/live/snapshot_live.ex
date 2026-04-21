defmodule LynxWeb.SnapshotLive do
  use LynxWeb, :live_view

  alias Lynx.Context.SnapshotContext
  alias Lynx.Context.AuditContext

  @impl true
  def mount(%{"uuid" => uuid}, _session, socket) do
    case SnapshotContext.fetch_snapshot_by_uuid(uuid) do
      {:not_found, _} ->
        {:ok, redirect(socket, to: "/admin/snapshots")}

      {:ok, snapshot} ->
        parsed = Jason.decode!(snapshot.data || "{}")

        environments = parsed["environments"] || []

        env_details =
          Enum.map(environments, fn env ->
            states = env["states"] || []

            units_with_versions =
              states
              |> Enum.group_by(& &1["sub_path"])
              |> Enum.map(fn {path, unit_states} ->
                latest = List.last(unit_states)

                %{
                  sub_path: path,
                  version_count: length(unit_states),
                  state_uuid: latest && latest["uuid"]
                }
              end)
              |> Enum.sort_by(& &1.sub_path)

            %{
              name: env["name"],
              slug: env["slug"],
              uuid: env["uuid"],
              units: units_with_versions
            }
          end)

        socket =
          socket
          |> assign(:snapshot, snapshot)
          |> assign(:project_name, parsed["name"] || "")
          |> assign(:project_slug, parsed["slug"] || "")
          |> assign(:project_uuid, parsed["uuid"] || "")
          |> assign(:environments, env_details)
          |> assign(:confirm, nil)
          |> assign(:viewing_state, nil)

        {:ok, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.confirm_dialog :if={@confirm} message={@confirm.message} confirm_event={@confirm.event} confirm_value={@confirm.value} />
    <.nav current_user={@current_user} active="snapshots" />
    <div class="max-w-7xl mx-auto px-6 pb-16">
      <.page_header title={@snapshot.title} subtitle={@snapshot.description} />

      <div class="flex items-center justify-between mb-4">
        <nav class="flex items-center gap-2 text-sm text-secondary">
          <a href="/admin/snapshots" class="hover:text-foreground">Snapshots</a>
          <span>/</span>
          <span class="text-foreground font-medium">{@snapshot.title}</span>
        </nav>
        <div class="flex gap-2">
          <.button phx-click="confirm_action" phx-value-event="restore_snapshot" phx-value-message="Restore this snapshot? This will overwrite current state." phx-value-uuid={@snapshot.uuid} variant="primary" size="sm">Restore</.button>
          <.button phx-click="confirm_action" phx-value-event="delete_snapshot" phx-value-message="Delete this snapshot permanently?" phx-value-uuid={@snapshot.uuid} variant="danger" size="sm">Delete</.button>
        </div>
      </div>

      <%!-- Overview --%>
      <.card class="mb-6">
        <div class="grid grid-cols-2 gap-6 text-sm">
          <div>
            <span class="text-xs uppercase tracking-wide text-muted">Scope</span>
            <div class="mt-2"><.badge color={scope_color(@snapshot.record_type)}>{@snapshot.record_type}</.badge></div>
          </div>
          <div>
            <span class="text-xs uppercase tracking-wide text-muted">Status</span>
            <div class="mt-2"><.badge color={if @snapshot.status == "success", do: "green", else: "yellow"}>{@snapshot.status}</.badge></div>
          </div>
          <div>
            <span class="text-xs uppercase tracking-wide text-muted">Project</span>
            <div class="mt-2 text-foreground font-medium">{@project_name}</div>
          </div>
          <div>
            <span class="text-xs uppercase tracking-wide text-muted">Created</span>
            <div class="mt-2 text-foreground">{Calendar.strftime(@snapshot.inserted_at, "%Y-%m-%d %H:%M:%S")}</div>
          </div>
        </div>
      </.card>

      <%!-- Environments & Units --%>
      <div :for={env <- @environments} class="mb-4">
        <.card>
          <div class="flex items-center gap-3 mb-4">
            <span class="font-medium text-foreground">{env.name}</span>
            <code class="text-xs bg-inset px-1.5 py-0.5 rounded">{env.slug}</code>
          </div>
          <div :if={env.units != []} class="space-y-2">
            <div :for={unit <- env.units}>
              <div class="flex items-center justify-between bg-inset hover:bg-surface-secondary rounded-lg px-4 py-2 cursor-pointer transition-colors"
                phx-click={JS.navigate("#{state_explorer_path(@project_uuid, env.uuid, unit.sub_path)}?snapshot=#{unit.state_uuid}")}>
                <div class="flex items-center gap-3">
                  <span class="text-sm text-clickable font-medium">
                    {if unit.sub_path == "" || is_nil(unit.sub_path), do: "(root)", else: unit.sub_path}
                  </span>
                  <span class="text-xs text-muted">v{unit.version_count}</span>
                </div>
                <div class="flex items-center gap-2" onclick="event.stopPropagation();">
                  <button phx-click="toggle_state_view" phx-value-env={env.uuid} phx-value-unit={unit.sub_path} class="text-xs text-clickable hover:text-clickable-hover cursor-pointer">
                    {if @viewing_state == "#{env.uuid}:#{unit.sub_path}", do: "Hide", else: "Preview"}
                  </button>
                  <a href={unit_download_href(@snapshot, env, unit.sub_path)} download={"snapshot-#{env.slug}-#{if unit.sub_path == "" || is_nil(unit.sub_path), do: "root", else: String.replace(unit.sub_path, "/", "-")}.json"} class="text-xs text-clickable hover:text-clickable-hover cursor-pointer">
                    Download
                  </a>
                </div>
              </div>
              <div :if={@viewing_state == "#{env.uuid}:#{unit.sub_path}"} class="mt-1">
                <div class="flex justify-end mb-1">
                  <.copy_button id={"copy-snap-#{env.uuid}-#{unit.sub_path}"} target={"#state-#{env.uuid}-#{unit.sub_path}"} class="text-xs text-clickable hover:text-clickable-hover cursor-pointer">Copy</.copy_button>
                </div>
                <div class="bg-state-viewer rounded-lg p-4 max-h-96 overflow-auto border border-border">
                  <.json_viewer id={"state-#{env.uuid}-#{unit.sub_path}"}>{format_unit_state(@snapshot, env, unit.sub_path)}</.json_viewer>
                </div>
              </div>
            </div>
          </div>
          <div :if={env.units == []} class="text-xs text-muted">No state versions</div>
        </.card>
      </div>
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

  def handle_event("toggle_state_view", %{"env" => env_uuid, "unit" => unit_path}, socket) do
    key = "#{env_uuid}:#{unit_path}"

    if socket.assigns.viewing_state == key do
      {:noreply, assign(socket, :viewing_state, nil)}
    else
      {:noreply, assign(socket, :viewing_state, key)}
    end
  end

  def handle_event("restore_snapshot", %{"uuid" => uuid}, socket) do
    socket = assign(socket, :confirm, nil)

    case SnapshotContext.restore_snapshot(uuid) do
      {:ok, _} ->
        AuditContext.log_user(
          socket.assigns.current_user,
          "restored",
          "snapshot",
          uuid,
          socket.assigns.snapshot.title
        )

        {:noreply, put_flash(socket, :info, "Snapshot restored successfully")}

      {:error, msg} ->
        {:noreply, put_flash(socket, :error, msg)}
    end
  end

  def handle_event("delete_snapshot", %{"uuid" => uuid}, socket) do
    socket = assign(socket, :confirm, nil)

    case SnapshotContext.delete_snapshot_by_uuid(uuid) do
      {:ok, _} ->
        AuditContext.log_user(socket.assigns.current_user, "deleted", "snapshot", uuid)
        {:noreply, redirect(socket, to: "/admin/snapshots")}

      _ ->
        {:noreply, put_flash(socket, :error, "Failed to delete")}
    end
  end

  defp state_explorer_path(project_uuid, env_uuid, sub_path) do
    base = "/admin/projects/#{project_uuid}/environments/#{env_uuid}/state"
    if sub_path == "" || is_nil(sub_path), do: base, else: "#{base}/#{sub_path}"
  end

  defp format_unit_state(snapshot, env, unit_path) do
    parsed = Jason.decode!(snapshot.data || "{}")
    envs = parsed["environments"] || []

    case Enum.find(envs, &(&1["uuid"] == env.uuid)) do
      nil ->
        "{}"

      e ->
        states = (e["states"] || []) |> Enum.filter(&(&1["sub_path"] == unit_path))
        latest = List.last(states)

        if latest do
          case Jason.decode(latest["value"] || "{}") do
            {:ok, decoded} -> Jason.encode!(decoded, pretty: true)
            _ -> latest["value"] || "{}"
          end
        else
          "{}"
        end
    end
  end

  defp unit_download_href(snapshot, env, unit_path) do
    parsed = Jason.decode!(snapshot.data || "{}")
    envs = parsed["environments"] || []

    states =
      case Enum.find(envs, &(&1["uuid"] == env.uuid)) do
        nil -> []
        e -> (e["states"] || []) |> Enum.filter(&(&1["sub_path"] == unit_path))
      end

    latest = List.last(states)
    value = if latest, do: latest["value"] || "{}", else: "{}"
    "data:application/octet-stream;base64,#{Base.encode64(value)}"
  end

  defp scope_color("project"), do: "blue"
  defp scope_color("environment"), do: "purple"
  defp scope_color("unit"), do: "yellow"
  defp scope_color(_), do: "gray"
end

defmodule LynxWeb.StateExplorerLive do
  use LynxWeb, :live_view

  alias Lynx.Module.ProjectModule
  alias Lynx.Context.EnvironmentContext
  alias Lynx.Context.StateContext

  @impl true
  def mount(%{"project_uuid" => project_uuid, "env_uuid" => env_uuid} = params, _session, socket) do
    sub_path = params["sub_path"] || ""

    case ProjectModule.get_project_by_uuid(project_uuid) do
      {:not_found, _} ->
        {:ok, redirect(socket, to: "/admin/workspaces")}

      {:ok, project} ->
        case EnvironmentContext.get_env_by_uuid(env_uuid) do
          nil ->
            {:ok, redirect(socket, to: "/admin/projects/#{project_uuid}")}

          env ->
            workspace =
              if project.workspace_id,
                do: Lynx.Context.WorkspaceContext.get_workspace_by_id(project.workspace_id)

            states =
              StateContext.get_states_by_environment_id(env.id)
              |> Enum.filter(&(Map.get(&1, :sub_path, "") == sub_path))
              |> Enum.sort_by(& &1.id)

            versions =
              Enum.with_index(states, 1)
              |> Enum.reverse()

            max_version = if versions != [], do: elem(hd(versions), 1), else: 0

            selected = max_version

            is_locked =
              Lynx.Context.LockContext.get_active_lock_by_environment_and_path(env.id, sub_path) !=
                nil

            socket =
              socket
              |> assign(:project, project)
              |> assign(:workspace, workspace)
              |> assign(:env, env)
              |> assign(:sub_path, sub_path)
              |> assign(:versions, versions)
              |> assign(:max_version, max_version)
              |> assign(:selected_version, selected)
              |> assign(:compare_version, nil)
              |> assign(:is_locked, is_locked)
              |> assign(:confirm, nil)
              |> assign(:snapshot_version, nil)

            {:ok, socket}
        end
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    case params["snapshot"] do
      nil ->
        {:noreply, socket}

      snapshot_uuid ->
        sv = find_version_by_uuid(socket.assigns.versions, snapshot_uuid)

        if sv do
          {:noreply, socket |> assign(:selected_version, sv) |> assign(:snapshot_version, sv)}
        else
          {:noreply, socket}
        end
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.confirm_dialog :if={@confirm} message={@confirm.message} confirm_event={@confirm.event} confirm_value={@confirm.value} />
    <.nav current_user={@current_user} active="workspaces" />
    <div class="max-w-7xl mx-auto px-6 pb-16">
      <.page_header
        title={if @sub_path == "", do: "(root)", else: @sub_path}
        subtitle={"State history — #{@env.name} / #{@project.name}"}
      />

      <div class="flex items-center justify-between mb-4">
        <nav class="flex items-center gap-2 text-sm text-secondary">
          <a href="/admin/workspaces" class="hover:text-foreground">Workspaces</a>
          <span :if={@workspace}>/</span>
          <a :if={@workspace} href={"/admin/workspaces/#{@workspace.uuid}"} class="hover:text-foreground">{@workspace.name}</a>
          <span>/</span>
          <a href={"/admin/projects/#{@project.uuid}"} class="hover:text-foreground">{@project.name}</a>
          <span>/</span>
          <a href={"/admin/projects/#{@project.uuid}/environments/#{@env.uuid}"} class="hover:text-foreground">{@env.name}</a>
          <span>/</span>
          <span class="text-foreground font-medium">{if @sub_path == "", do: "(root)", else: @sub_path}</span>
        </nav>
        <span
          class="cursor-pointer"
          phx-click="confirm_action"
          phx-value-event={if @is_locked, do: "unlock_unit", else: "lock_unit"}
          phx-value-uuid={@sub_path}
          phx-value-message={if @is_locked, do: "Force unlock this unit?", else: "Lock this unit?"}
        >
          <.badge color={if @is_locked, do: "red", else: "green"}>
            {if @is_locked, do: "Unit Locked", else: "Unit Unlocked"}
          </.badge>
        </span>
      </div>

      <.card class="mb-6">
        <form phx-change="version_change" class="flex items-center gap-4 mb-4">
          <div class="flex-1">
            <.input
              name="version"
              label="Version"
              type="select"
              value={to_string(@selected_version || "")}
              options={Enum.map(@versions, fn {s, idx} -> {"v#{idx}#{version_label(idx, @max_version, @snapshot_version)} — #{Calendar.strftime(s.inserted_at, "%Y-%m-%d %H:%M:%S")}", to_string(idx)} end)}
            />
          </div>
          <div :if={length(@versions) > 1} class="flex-1">
            <.input
              name="compare"
              label="Compare with"
              type="select"
              prompt="None"
              value={to_string(@compare_version || "")}
              options={Enum.map(@versions, fn {s, idx} -> {"v#{idx}#{version_label(idx, @max_version, @snapshot_version)} — #{Calendar.strftime(s.inserted_at, "%Y-%m-%d %H:%M:%S")}", to_string(idx)} end)}
            />
          </div>
        </form>

        <div :if={@compare_version && @compare_version != @selected_version} id={"diff-#{@selected_version}-#{@compare_version}"} phx-hook=".DiffHighlight" class="grid grid-cols-2 gap-4">
          <div>
            <div class="flex items-center justify-between mb-1">
              <span class="text-xs text-muted font-medium">v{@selected_version}{if @selected_version == @max_version, do: " (Current)", else: ""}</span>
              <.copy_button id={"copy-left-#{@selected_version}"} target={"#state-left-#{@selected_version}"} class="text-xs text-clickable hover:text-clickable-hover cursor-pointer">Copy</.copy_button>
            </div>
            <div class="bg-state-viewer rounded-lg p-4 max-h-[600px] overflow-auto border border-border">
              <pre id={"state-left-#{@selected_version}"} data-diff="left" class="text-xs font-mono whitespace-pre-wrap text-state-viewer-text">{get_version_state(@versions, @selected_version)}</pre>
            </div>
          </div>
          <div>
            <div class="flex items-center justify-between mb-1">
              <span class="text-xs text-muted font-medium">v{@compare_version}{if @compare_version == @max_version, do: " (Current)", else: ""}</span>
              <.copy_button id={"copy-right-#{@compare_version}"} target={"#state-right-raw-#{@compare_version}"} class="text-xs text-clickable hover:text-clickable-hover cursor-pointer">Copy</.copy_button>
            </div>
            <div class="bg-state-viewer rounded-lg p-4 max-h-[600px] overflow-auto border border-border">
              <pre id={"state-right-#{@compare_version}"} data-diff="right" class="text-xs font-mono whitespace-pre-wrap text-state-viewer-text">{get_version_state(@versions, @compare_version)}</pre>
              <pre id={"state-right-raw-#{@compare_version}"} class="hidden">{get_version_state(@versions, @compare_version)}</pre>
            </div>
          </div>
        </div>
        <script :type={Phoenix.LiveView.ColocatedHook} name=".DiffHighlight">
          import {diffLines} from "diff"
          export default {
            mounted() { this.diff() },
            updated() { this.diff() },
            diff() {
              let leftEl = document.querySelector('[data-diff="left"]')
              let rightEl = document.querySelector('[data-diff="right"]')
              if (!leftEl || !rightEl) return

              let leftText = leftEl.textContent
              let rightText = rightEl.textContent
              let s = getComputedStyle(document.documentElement)
              let addBg = s.getPropertyValue('--diff-highlight').trim() || 'rgba(239,68,68,0.15)'
              let removeBg = 'rgba(34,197,94,0.12)'

              let changes = diffLines(leftText, rightText)

              let leftHtml = []
              let rightHtml = []

              changes.forEach(part => {
                let lines = part.value.replace(/\n$/, '').split('\n')
                lines.forEach(line => {
                  let escaped = line.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;')
                  if (part.added) {
                    rightHtml.push(`<span style="background:${addBg};display:inline-block;width:100%">${escaped}</span>`)
                  } else if (part.removed) {
                    leftHtml.push(`<span style="background:${removeBg};display:inline-block;width:100%">${escaped}</span>`)
                  } else {
                    leftHtml.push(escaped)
                    rightHtml.push(escaped)
                  }
                })
              })

              leftEl.innerHTML = leftHtml.join('\n')
              rightEl.innerHTML = rightHtml.join('\n')
            }
          }
        </script>

        <div :if={!@compare_version || @compare_version == @selected_version}>
          <div class="flex items-center justify-between mb-1">
            <span class="text-xs text-muted font-medium">v{@selected_version}{if @selected_version == @max_version, do: " (Current)", else: ""}</span>
            <.copy_button id={"copy-single-#{@selected_version}"} target={"#state-viewer-#{@selected_version}"} class="text-xs text-clickable hover:text-clickable-hover cursor-pointer">Copy</.copy_button>
          </div>
          <div class="bg-state-viewer rounded-lg p-4 max-h-[600px] overflow-auto border border-border">
            <.json_viewer id={"state-viewer-#{@selected_version}"}>{get_version_state(@versions, @selected_version)}</.json_viewer>
          </div>
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

  def handle_event("lock_unit", _, socket) do
    socket = assign(socket, :confirm, nil)
    env = socket.assigns.env
    sub_path = socket.assigns.sub_path

    Lynx.Context.LockContext.create_lock(
      Lynx.Context.LockContext.new_lock(%{
        environment_id: env.id,
        operation: "manual",
        info: "Locked via UI",
        who: socket.assigns.current_user.name,
        version: "",
        path: "",
        sub_path: sub_path,
        uuid: Ecto.UUID.generate(),
        is_active: true
      })
    )

    label = if sub_path == "", do: env.name, else: "#{env.name}/#{sub_path}"

    Lynx.Module.AuditModule.log_user(
      socket.assigns.current_user,
      "locked",
      "unit",
      env.uuid,
      label
    )

    {:noreply, socket |> assign(:is_locked, true) |> put_flash(:info, "Unit locked")}
  end

  def handle_event("unlock_unit", _, socket) do
    socket = assign(socket, :confirm, nil)
    env = socket.assigns.env
    sub_path = socket.assigns.sub_path

    case Lynx.Context.LockContext.get_active_lock_by_environment_and_path(env.id, sub_path) do
      nil -> :ok
      lock -> Lynx.Context.LockContext.update_lock(lock, %{is_active: false})
    end

    label = if sub_path == "", do: env.name, else: "#{env.name}/#{sub_path}"

    Lynx.Module.AuditModule.log_user(
      socket.assigns.current_user,
      "unlocked",
      "unit",
      env.uuid,
      label
    )

    {:noreply, socket |> assign(:is_locked, false) |> put_flash(:info, "Unit unlocked")}
  end

  def handle_event("version_change", params, socket) do
    version =
      case params["version"] do
        nil -> socket.assigns.selected_version
        "" -> socket.assigns.selected_version
        v -> String.to_integer(v)
      end

    compare =
      case params["compare"] do
        nil -> nil
        "" -> nil
        v -> String.to_integer(v)
      end

    {:noreply, socket |> assign(:selected_version, version) |> assign(:compare_version, compare)}
  end

  defp get_version_state(versions, version_num) when is_integer(version_num) do
    case Enum.find(versions, fn {_state, idx} -> idx == version_num end) do
      {state, _} ->
        case Jason.decode(state.value || "{}") do
          {:ok, decoded} -> Jason.encode!(decoded, pretty: true)
          _ -> state.value || "{}"
        end

      nil ->
        "{}"
    end
  end

  defp get_version_state(_, _), do: "{}"

  defp find_version_by_uuid(_versions, nil), do: nil

  defp find_version_by_uuid(versions, uuid) do
    case Enum.find(versions, fn {state, _idx} -> state.uuid == uuid end) do
      {_, idx} -> idx
      nil -> nil
    end
  end

  defp version_label(idx, max, snapshot) do
    cond do
      idx == max && idx == snapshot -> " (Current, Snapshot)"
      idx == max -> " (Current)"
      idx == snapshot -> " (Snapshot)"
      true -> ""
    end
  end
end

defmodule LynxWeb.EnvironmentLive do
  use LynxWeb, :live_view

  alias Lynx.Module.ProjectModule
  alias Lynx.Module.LockModule
  alias Lynx.Module.SettingsModule
  alias Lynx.Module.AuditModule
  alias Lynx.Context.EnvironmentContext
  alias Lynx.Context.StateContext
  alias Lynx.Context.LockContext

  on_mount {LynxWeb.LiveAuth, :require_auth}

  @impl true
  def mount(%{"project_uuid" => project_uuid, "env_uuid" => env_uuid}, _session, socket) do
    case ProjectModule.get_project_by_uuid(project_uuid) do
      {:not_found, _} ->
        {:ok, redirect(socket, to: "/admin/projects")}

      {:ok, project} ->
        case EnvironmentContext.get_env_by_uuid(env_uuid) do
          nil ->
            {:ok, redirect(socket, to: "/admin/projects/#{project_uuid}")}

          env ->
            app_url =
              SettingsModule.get_config("app_url", "http://localhost:4000")
              |> String.trim_trailing("/")

            socket =
              socket
              |> assign(:project, project)
              |> assign(:env, env)
              |> assign(:app_url, app_url)
              |> assign(:env_locked, LockContext.is_environment_locked(env.id))
              |> assign(:confirm, nil)
              |> load_units()

            {:ok, socket}
        end
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.confirm_dialog :if={@confirm} message={@confirm.message} confirm_event={@confirm.event} confirm_value={@confirm.value} />
    <.nav current_user={@current_user} active="projects" />
    <div class="max-w-7xl mx-auto px-6">
      <.page_header title={@env.name} subtitle={"Environment in #{@project.name}"} />

      <div class="flex items-center justify-between mb-4">
        <nav class="flex items-center gap-2 text-sm text-gray-500">
          <a href="/admin/projects" class="hover:text-gray-700">Projects</a>
          <span>/</span>
          <a href={"/admin/projects/#{@project.uuid}"} class="hover:text-gray-700">{@project.name}</a>
          <span>/</span>
          <span class="text-gray-900 font-medium">{@env.name}</span>
        </nav>
        <div class="flex items-center gap-3">
          <span
            class="cursor-pointer"
            phx-click="confirm_action"
            phx-value-event={if @env_locked, do: "env_force_unlock", else: "env_force_lock"}
            phx-value-uuid={@env.uuid}
            phx-value-message={if @env_locked, do: "Unlock all units in this environment?", else: "Lock all units in this environment? This blocks all Terraform operations."}
          >
            <.badge color={if @env_locked, do: "red", else: "green"}>
              {if @env_locked, do: "Environment Locked", else: "Environment Unlocked"}
            </.badge>
          </span>
        </div>
      </div>

      <%!-- Backend Config --%>
      <.card class="mb-6">
        <h3 class="text-sm font-semibold text-gray-700 mb-3">Backend Configuration</h3>
        <div class="bg-gray-900 text-gray-100 rounded-lg p-4">
          <pre class="text-xs font-mono whitespace-pre-wrap">{backend_config(@app_url, @project.slug, @env)}</pre>
        </div>
        <p class="mt-2 text-xs text-gray-500">
          For Terragrunt units, append the unit path before /state, /lock, /unlock (e.g. /tf/{@project.slug}/{@env.slug}/dns/state).
        </p>
      </.card>

      <%!-- Units Table --%>
      <.card>
        <div class="flex items-center justify-between mb-4">
          <h3 class="text-sm font-semibold text-gray-700">Units</h3>
          <a href={"/admin/environment/download/#{@env.uuid}"} class="text-sm text-blue-600 hover:text-blue-800">
            Download Root State
          </a>
        </div>
        <.table rows={@units} empty_message="No units yet. State will appear here after your first Terraform apply.">
          <:col :let={unit} label="Path">
            <code class="text-xs bg-gray-100 px-1.5 py-0.5 rounded">{if unit.sub_path == "", do: "(root)", else: unit.sub_path}</code>
          </:col>
          <:col :let={unit} label="Lock Status">
            <span
              class="cursor-pointer"
              phx-click="confirm_action"
              phx-value-event={if unit.is_locked, do: "unlock_unit", else: "lock_unit"}
              phx-value-uuid={unit.sub_path}
              phx-value-message={if unit.is_locked, do: "Force unlock this unit?", else: "Lock this unit?"}
            >
              <.badge color={if unit.is_locked, do: "red", else: "green"}>
                {if unit.is_locked, do: "Locked", else: "Not Locked"}
              </.badge>
            </span>
          </:col>
          <:col :let={unit} label="State">v{unit.count}</:col>
          <:col :let={unit} label="Last Updated">
            <span class="text-xs text-gray-500">{Calendar.strftime(unit.latest, "%Y-%m-%d %H:%M")}</span>
          </:col>
          <:action :let={unit}>
            <a href={"/admin/environment/download/#{@env.uuid}?sub_path=#{unit.sub_path}"} class="text-gray-600 hover:text-gray-800 text-xs px-3 py-1.5">
              Download
            </a>
          </:action>
        </.table>
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

  def handle_event("env_force_lock", _, socket) do
    socket = assign(socket, :confirm, nil)
    env = socket.assigns.env
    LockModule.force_lock(env.id, socket.assigns.current_user.name)
    AuditModule.log_user(socket.assigns.current_user, "locked", "environment", env.uuid, env.name)

    {:noreply,
     socket |> assign(:env_locked, true) |> put_flash(:info, "Environment locked") |> load_units()}
  end

  def handle_event("env_force_unlock", _, socket) do
    socket = assign(socket, :confirm, nil)
    env = socket.assigns.env
    LockModule.force_unlock(env.id)

    AuditModule.log_user(
      socket.assigns.current_user,
      "unlocked",
      "environment",
      env.uuid,
      env.name
    )

    {:noreply,
     socket
     |> assign(:env_locked, false)
     |> put_flash(:info, "Environment unlocked")
     |> load_units()}
  end

  def handle_event("lock_unit", %{"uuid" => sub_path}, socket) do
    socket = assign(socket, :confirm, nil)
    env = socket.assigns.env

    lock =
      LockContext.new_lock(%{
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

    LockContext.create_lock(lock)
    label = if sub_path == "", do: env.name, else: "#{env.name}/#{sub_path}"
    AuditModule.log_user(socket.assigns.current_user, "locked", "environment", env.uuid, label)
    {:noreply, socket |> put_flash(:info, "Unit locked") |> load_units()}
  end

  def handle_event("unlock_unit", %{"uuid" => sub_path}, socket) do
    socket = assign(socket, :confirm, nil)
    env = socket.assigns.env

    case LockContext.get_active_lock_by_environment_and_path(env.id, sub_path) do
      nil -> :ok
      lock -> LockContext.update_lock(lock, %{is_active: false})
    end

    label = if sub_path == "", do: env.name, else: "#{env.name}/#{sub_path}"
    AuditModule.log_user(socket.assigns.current_user, "unlocked", "environment", env.uuid, label)
    {:noreply, socket |> put_flash(:info, "Unit unlocked") |> load_units()}
  end

  defp load_units(socket) do
    env = socket.assigns.env
    sub_paths = StateContext.list_sub_paths(env.id)

    units =
      Enum.map(sub_paths, fn sp ->
        is_locked =
          LockContext.get_active_lock_by_environment_and_path(env.id, sp.sub_path) != nil

        %{
          sub_path: sp.sub_path,
          count: sp.count,
          latest: sp.latest,
          is_locked: is_locked
        }
      end)

    assign(socket, :units, units)
  end

  defp backend_config(app_url, project_slug, env) do
    """
    terraform {
      backend "http" {
        username       = "#{env.username}"
        password       = "#{env.secret}"
        address        = "#{app_url}/tf/#{project_slug}/#{env.slug}/state"
        lock_address   = "#{app_url}/tf/#{project_slug}/#{env.slug}/lock"
        unlock_address = "#{app_url}/tf/#{project_slug}/#{env.slug}/unlock"
        lock_method    = "POST"
        unlock_method  = "POST"
      }
    }\
    """
  end
end

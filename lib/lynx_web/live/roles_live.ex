defmodule LynxWeb.RolesLive do
  @moduledoc """
  Admin UI for managing custom roles.

  System roles (`planner`, `applier`, `admin`) are seeded by migration and
  carry `is_system: true` — they're listed for visibility but cannot be
  edited or deleted (the buttons are disabled with a tooltip).

  Custom roles can be created, edited, or deleted. Delete is blocked if any
  `project_teams` / `user_projects` / `oidc_access_rules` row references the
  role (DB-level `:restrict` foreign key + a friendlier "in use" UI guard).
  """
  use LynxWeb, :live_view

  alias Lynx.Context.{AuditContext, RoleContext}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:show_add, false)
     |> assign(:editing_role, nil)
     |> assign(:editing_permissions, MapSet.new())
     |> assign(:confirm, nil)
     |> assign(:all_permissions, RoleContext.permissions())
     |> load_roles()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.confirm_dialog :if={@confirm} message={@confirm.message} confirm_event={@confirm.event} confirm_value={@confirm.value} />
    <.nav current_user={@current_user} active="roles" />
    <div class="max-w-7xl mx-auto px-6 pb-16">
      <.page_header title="Roles" subtitle="Custom permission bundles. System roles can't be edited." />

      <div class="flex justify-end mb-4">
        <.button phx-click="show_add" variant="primary">+ Add Role</.button>
      </div>

      <.modal :if={@show_add} id="add-role" show on_close="hide_add">
        <h3 class="text-lg font-semibold mb-4">Add Role</h3>
        <form phx-submit="create_role" phx-change="form_change" class="space-y-4">
          <.input name="name" label="Name" value="" required />
          <.input name="description" label="Description" type="textarea" value="" />
          <.permission_grid all={@all_permissions} selected={@editing_permissions} />
          <div class="flex gap-3 pt-2">
            <.button type="submit" variant="primary">Create</.button>
            <.button phx-click="hide_add" variant="secondary">Cancel</.button>
          </div>
        </form>
      </.modal>

      <.modal :if={@editing_role} id="edit-role" show on_close="hide_edit">
        <h3 class="text-lg font-semibold mb-4">Edit Role</h3>
        <form phx-submit="update_role" phx-change="form_change" class="space-y-4">
          <.input name="name" label="Name" value={@editing_role.name} required />
          <.input name="description" label="Description" type="textarea" value={@editing_role.description || ""} />
          <.permission_grid all={@all_permissions} selected={@editing_permissions} />
          <div class="flex gap-3 pt-2">
            <.button type="submit" variant="primary">Update</.button>
            <.button phx-click="hide_edit" variant="secondary">Cancel</.button>
          </div>
        </form>
      </.modal>

      <.card>
        <.table rows={@roles}>
          <:col :let={r} label="Name">
            <a href={"/admin/roles/#{r.uuid}"} class="font-medium text-clickable hover:text-clickable-hover">
              {String.capitalize(r.name)}
            </a>
            <.badge :if={r.is_system} color="gray" class="ml-2">system</.badge>
          </:col>
          <:col :let={r} label="Description">
            <span class="text-sm text-secondary">{r.description || "—"}</span>
          </:col>
          <:col :let={r} label="Permissions">
            <span class="text-xs text-muted">{length(r.permissions)} of {length(@all_permissions)}</span>
          </:col>
          <:col :let={r} label="In use">
            <.badge :if={r.usage > 0} color="blue">{r.usage} grant(s)</.badge>
            <span :if={r.usage == 0} class="text-xs text-muted">unused</span>
          </:col>
          <:action :let={r}>
            <.button :if={not r.is_system} phx-click="edit_role" phx-value-uuid={r.uuid} variant="ghost" size="sm">Edit</.button>
            <span :if={r.is_system} title="System roles can't be edited" class="text-xs text-muted px-3 py-1.5">Edit</span>
            <.button :if={not r.is_system and r.usage == 0} phx-click="confirm_action" phx-value-event="delete_role" phx-value-message={"Delete role " <> r.name <> "?"} phx-value-uuid={r.uuid} variant="ghost" size="sm">Delete</.button>
            <span :if={r.is_system or r.usage > 0} title={if(r.is_system, do: "System roles can't be deleted", else: "Role is in use — remove all grants first")} class="text-xs text-muted px-3 py-1.5">Delete</span>
          </:action>
        </.table>
      </.card>
    </div>
    """
  end

  attr :all, :list, required: true
  attr :selected, :any, required: true

  defp permission_grid(assigns) do
    ~H"""
    <div>
      <label class="block text-sm font-medium text-secondary mb-2">Permissions</label>
      <div class="grid grid-cols-1 md:grid-cols-2 gap-3">
        <label :for={perm <- @all} class="flex items-start gap-2 text-sm cursor-pointer p-2 rounded hover:bg-surface-secondary">
          <input
            type="checkbox"
            name="permissions[]"
            value={perm}
            checked={MapSet.member?(@selected, perm)}
            class="rounded border-border-input text-accent focus:ring-accent mt-0.5 shrink-0"
          />
          <div class="flex-1 min-w-0">
            <code class="text-xs font-mono">{perm}</code>
            <p class="text-xs text-muted mt-0.5 leading-snug">
              {Lynx.Context.RoleContext.permission_description(perm)}
            </p>
          </div>
        </label>
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

  def handle_event("show_add", _, socket) do
    {:noreply, assign(socket, show_add: true, editing_permissions: MapSet.new())}
  end

  def handle_event("hide_add", _, socket), do: {:noreply, assign(socket, :show_add, false)}
  def handle_event("hide_edit", _, socket), do: {:noreply, assign(socket, :editing_role, nil)}

  def handle_event("form_change", params, socket) do
    {:noreply, assign(socket, :editing_permissions, MapSet.new(params["permissions"] || []))}
  end

  def handle_event("edit_role", %{"uuid" => uuid}, socket) do
    case RoleContext.get_role_by_uuid(uuid) do
      nil ->
        {:noreply, put_flash(socket, :error, "Role not found")}

      role ->
        perms = RoleContext.permissions_for(role.id)
        {:noreply, assign(socket, editing_role: role, editing_permissions: perms)}
    end
  end

  def handle_event("create_role", params, socket) do
    permissions = MapSet.to_list(socket.assigns.editing_permissions)

    case RoleContext.create_role(%{
           name: params["name"],
           description: params["description"],
           permissions: permissions
         }) do
      {:ok, role} ->
        AuditContext.log_user(
          socket.assigns.current_user,
          "created",
          "role",
          role.uuid,
          role.name
        )

        {:noreply,
         socket |> assign(:show_add, false) |> put_flash(:info, "Role created") |> load_roles()}

      {:error, msg} when is_binary(msg) ->
        {:noreply, put_flash(socket, :error, msg)}
    end
  end

  def handle_event("update_role", params, socket) do
    permissions = MapSet.to_list(socket.assigns.editing_permissions)
    role = socket.assigns.editing_role

    case RoleContext.update_role(role, %{
           name: params["name"],
           description: params["description"],
           permissions: permissions
         }) do
      {:ok, _} ->
        AuditContext.log_user(
          socket.assigns.current_user,
          "updated",
          "role",
          role.uuid,
          role.name
        )

        {:noreply,
         socket |> assign(:editing_role, nil) |> put_flash(:info, "Role updated") |> load_roles()}

      {:error, :system_role} ->
        {:noreply, put_flash(socket, :error, "System roles can't be edited")}

      {:error, msg} when is_binary(msg) ->
        {:noreply, put_flash(socket, :error, msg)}
    end
  end

  def handle_event("delete_role", %{"uuid" => uuid}, socket) do
    socket = assign(socket, :confirm, nil)

    case RoleContext.get_role_by_uuid(uuid) do
      nil ->
        {:noreply, put_flash(socket, :error, "Role not found")}

      role ->
        case RoleContext.delete_role(role) do
          :ok ->
            AuditContext.log_user(
              socket.assigns.current_user,
              "deleted",
              "role",
              role.uuid,
              role.name
            )

            {:noreply, socket |> put_flash(:info, "Role deleted") |> load_roles()}

          {:error, :system_role} ->
            {:noreply, put_flash(socket, :error, "System roles can't be deleted")}

          {:error, msg} when is_binary(msg) ->
            {:noreply, put_flash(socket, :error, msg)}
        end
    end
  end

  defp load_roles(socket) do
    roles =
      RoleContext.list_roles()
      |> Enum.map(fn role ->
        %{
          uuid: role.uuid,
          name: role.name,
          description: role.description,
          is_system: role.is_system,
          permissions: RoleContext.permissions_for(role.id) |> MapSet.to_list(),
          usage: RoleContext.count_role_usage(role.id)
        }
      end)

    assign(socket, :roles, roles)
  end
end

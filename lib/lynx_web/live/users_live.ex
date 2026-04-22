defmodule LynxWeb.UsersLive do
  use LynxWeb, :live_view

  alias Lynx.Context.UserContext
  alias Lynx.Context.AuditContext
  alias Lynx.Context.RoleContext

  @per_page 10

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page, 1)
      |> assign(:per_page, @per_page)
      |> assign(:show_add, false)
      |> assign(:editing_user, nil)
      |> assign(:confirm, nil)
      |> load_users()

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.confirm_dialog :if={@confirm} message={@confirm.message} confirm_event={@confirm.event} confirm_value={@confirm.value} />
    <.nav current_user={@current_user} active="users" />
    <div class="max-w-7xl mx-auto px-6 pb-16">
      <.page_header title="Users" subtitle="Manage user accounts and roles" />

      <div class="flex justify-end mb-4">
        <.button phx-click="show_add" variant="primary">+ Add User</.button>
      </div>

      <%!-- Add User Modal --%>
      <.modal :if={@show_add} id="add-user-modal" show on_close="hide_add">
        <h3 class="text-lg font-semibold mb-4">Add New User</h3>
        <form phx-submit="create_user" class="space-y-4">
          <.input name="name" label="Name" value="" required />
          <.input name="email" label="Email" type="email" value="" required />
          <.input name="password" label="Password" type="password" value="" required />
          <.input name="role" label="Role" type="select" value="regular" options={[{"Regular", "regular"}, {"Super Admin", "super"}]} />
          <div class="flex gap-3 pt-2">
            <.button type="submit" variant="primary">Create</.button>
            <.button phx-click="hide_add" variant="secondary">Cancel</.button>
          </div>
        </form>
      </.modal>

      <%!-- Edit User Modal --%>
      <.modal :if={@editing_user} id="edit-user-modal" show on_close="hide_edit">
        <h3 class="text-lg font-semibold mb-4">Edit User</h3>
        <form phx-submit="update_user" class="space-y-4">
          <.input name="name" label="Name" value={@editing_user.name} required />
          <.input name="email" label="Email" type="email" value={@editing_user.email} required />
          <.input name="password" label="Password (leave blank to keep)" type="password" value="" />
          <.input name="role" label="Role" type="select" value={@editing_user.role} options={[{"Regular", "regular"}, {"Super Admin", "super"}]} />
          <div class="flex gap-3 pt-2">
            <.button type="submit" variant="primary">Update</.button>
            <.button phx-click="hide_edit" variant="secondary">Cancel</.button>
          </div>
        </form>
      </.modal>

      <.card>
        <.table rows={@users}>
          <:col :let={user} label="Name">{user.name}</:col>
          <:col :let={user} label="Email">{user.email}</:col>
          <:col :let={user} label="Role">
            <.badge color={if user.role == "super", do: "purple", else: "gray"}>{user.role}</.badge>
          </:col>
          <:col :let={user} label="Projects & Roles">
            <.role_assignments_summary
              assignments={user.assignments}
              all_label={if user.role == "super", do: "All projects (super)"}
            />
          </:col>
          <:col :let={user} label="Status">
            <.badge color={if user.is_active, do: "green", else: "gray"}>
              {if user.is_active, do: "Active", else: "Inactive"}
            </.badge>
          </:col>
          <:col :let={user} label="Created">
            <span class="text-xs text-muted">{format_datetime(user.inserted_at)}</span>
          </:col>
          <:action :let={user}>
            <.button phx-click="edit_user" phx-value-uuid={user.uuid} variant="ghost" size="sm">Edit</.button>
            <.button phx-click="confirm_action" phx-value-event="delete_user" phx-value-message="Delete this user?" phx-value-uuid={user.uuid} variant="ghost" size="sm">Delete</.button>
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
  def handle_event("hide_edit", _, socket), do: {:noreply, assign(socket, :editing_user, nil)}

  def handle_event("create_user", params, socket) do
    case UserContext.create_user_from_data(%{
           name: params["name"],
           email: params["email"],
           password: params["password"],
           role: params["role"],
           api_key: Ecto.UUID.generate()
         }) do
      {:ok, user} ->
        AuditContext.log_user(
          socket.assigns.current_user,
          "created",
          "user",
          user.uuid,
          user.name
        )

        {:noreply,
         socket
         |> assign(:show_add, false)
         |> put_flash(:info, "User created")
         |> load_users()}

      {:error, msg} ->
        {:noreply, put_flash(socket, :error, msg)}
    end
  end

  def handle_event("edit_user", %{"uuid" => uuid}, socket) do
    case UserContext.fetch_user_by_uuid(uuid) do
      {:ok, user} -> {:noreply, assign(socket, :editing_user, user)}
      _ -> {:noreply, put_flash(socket, :error, "User not found")}
    end
  end

  def handle_event("update_user", params, socket) do
    # Capture before-state so we can emit a distinct audit event when the
    # system role flips (super ↔ regular) — that's a much higher-impact
    # change than a name/email tweak and deserves its own row in the log.
    old = socket.assigns.editing_user

    case UserContext.update_user_from_data(%{
           uuid: old.uuid,
           name: params["name"],
           email: params["email"],
           password: params["password"],
           role: params["role"]
         }) do
      {:ok, updated} ->
        AuditContext.log_user(
          socket.assigns.current_user,
          "updated",
          "user",
          updated.uuid,
          updated.email,
          %{name: updated.name, email: updated.email, role: updated.role}
        )

        if old.role != updated.role do
          AuditContext.log_user(
            socket.assigns.current_user,
            "role_changed",
            "user",
            updated.uuid,
            updated.email,
            %{from: old.role, to: updated.role}
          )
        end

        {:noreply,
         socket
         |> assign(:editing_user, nil)
         |> put_flash(:info, "User updated")
         |> load_users()}

      {:error, msg} ->
        {:noreply, put_flash(socket, :error, msg)}
    end
  end

  def handle_event("delete_user", %{"uuid" => uuid}, socket) do
    socket = assign(socket, :confirm, nil)

    case UserContext.delete_user_by_uuid(uuid) do
      {:ok, _} ->
        AuditContext.log_user(socket.assigns.current_user, "deleted", "user", uuid)
        {:noreply, socket |> put_flash(:info, "User deleted") |> load_users()}

      _ ->
        {:noreply, put_flash(socket, :error, "Failed to delete user")}
    end
  end

  def handle_event("next_page", _, socket) do
    if socket.assigns.page < socket.assigns.total_pages do
      {:noreply, socket |> assign(:page, socket.assigns.page + 1) |> load_users()}
    else
      {:noreply, socket}
    end
  end

  def handle_event("prev_page", _, socket) do
    if socket.assigns.page > 1 do
      {:noreply, socket |> assign(:page, socket.assigns.page - 1) |> load_users()}
    else
      {:noreply, socket}
    end
  end

  defp load_users(socket) do
    offset = (socket.assigns.page - 1) * socket.assigns.per_page

    users =
      UserContext.get_users(offset, socket.assigns.per_page)
      |> Enum.map(fn user ->
        Map.put(user, :assignments, RoleContext.list_user_project_access(user))
      end)

    total = UserContext.count_users()
    total_pages = max(ceil(total / socket.assigns.per_page), 1)

    socket
    |> assign(:users, users)
    |> assign(:total_pages, total_pages)
  end

  defp format_datetime(nil), do: "-"
  defp format_datetime(dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")
end

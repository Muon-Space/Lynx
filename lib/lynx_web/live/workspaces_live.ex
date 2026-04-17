defmodule LynxWeb.WorkspacesLive do
  use LynxWeb, :live_view

  alias Lynx.Context.WorkspaceContext
  alias Lynx.Context.ProjectContext
  alias Lynx.Module.AuditModule

  on_mount {LynxWeb.LiveAuth, :require_auth}

  @per_page 10

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page, 1)
      |> assign(:show_add, false)
      |> assign(:add_slug, "")
      |> assign(:editing_workspace, nil)
      |> assign(:confirm, nil)
      |> load_workspaces()

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.confirm_dialog :if={@confirm} message={@confirm.message} confirm_event={@confirm.event} confirm_value={@confirm.value} />
    <.nav current_user={@current_user} active="workspaces" />
    <div class="max-w-7xl mx-auto px-6">
      <.page_header title="Workspaces" subtitle="Organize projects into workspaces" />

      <div class="flex items-center justify-between mb-4">
        <nav class="flex items-center gap-2 text-sm text-gray-500 dark:text-gray-400">
          <span class="text-gray-900 dark:text-white font-medium">Workspaces</span>
        </nav>
        <.button :if={@current_user.role == "super"} phx-click="show_add" variant="primary">+ Add Workspace</.button>
      </div>

      <.modal :if={@show_add} id="add-workspace" show on_close="hide_add">
        <h3 class="text-lg font-semibold mb-4">Add Workspace</h3>
        <form phx-submit="create_workspace" phx-change="form_change" class="space-y-4">
          <.input name="name" label="Name" value="" required />
          <.input name="slug" label="Slug" value={@add_slug} required />
          <.input name="description" label="Description" type="textarea" value="" />
          <div class="flex gap-3 pt-2">
            <.button type="submit" variant="primary">Create</.button>
            <.button phx-click="hide_add" variant="secondary">Cancel</.button>
          </div>
        </form>
      </.modal>

      <.modal :if={@editing_workspace} id="edit-workspace" show on_close="hide_edit">
        <h3 class="text-lg font-semibold mb-4">Edit Workspace</h3>
        <form phx-submit="update_workspace" class="space-y-4">
          <.input name="name" label="Name" value={@editing_workspace.name} required />
          <.input name="slug" label="Slug" value={@editing_workspace.slug} required />
          <.input name="description" label="Description" type="textarea" value={@editing_workspace.description || ""} />
          <div class="flex gap-3 pt-2">
            <.button type="submit" variant="primary">Update</.button>
            <.button phx-click="hide_edit" variant="secondary">Cancel</.button>
          </div>
        </form>
      </.modal>

      <.card>
        <.table rows={@workspaces} row_click={fn ws -> JS.push("view_workspace", value: %{uuid: ws.uuid}) end}>
          <:col :let={ws} label="Name"><span class="font-medium text-blue-600">{ws.name}</span></:col>
          <:col :let={ws} label="Slug"><code class="text-xs bg-gray-100 dark:bg-gray-800 px-1.5 py-0.5 rounded">{ws.slug}</code></:col>
          <:col :let={ws} label="Projects">{ws.project_count}</:col>
          <:col :let={ws} label="Created">
            <span class="text-xs text-gray-500">{Calendar.strftime(ws.inserted_at, "%Y-%m-%d %H:%M")}</span>
          </:col>
          <:action :let={ws}>
            <.button :if={@current_user.role == "super"} phx-click="edit_workspace" phx-value-uuid={ws.uuid} variant="ghost" size="sm">Edit</.button>
            <.button :if={@current_user.role == "super"} phx-click="confirm_action" phx-value-event="delete_workspace" phx-value-message="Delete this workspace? Projects will become unassigned." phx-value-uuid={ws.uuid} variant="ghost" size="sm">Delete</.button>
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

  def handle_event("show_add", _, socket),
    do: {:noreply, assign(socket, show_add: true, add_slug: "")}

  def handle_event("hide_add", _, socket), do: {:noreply, assign(socket, :show_add, false)}

  def handle_event("hide_edit", _, socket),
    do: {:noreply, assign(socket, :editing_workspace, nil)}

  def handle_event("form_change", %{"name" => name}, socket) do
    slug =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]/, "-")
      |> String.replace(~r/-+/, "-")
      |> String.trim("-")

    {:noreply, assign(socket, :add_slug, slug)}
  end

  def handle_event("view_workspace", %{"uuid" => uuid}, socket) do
    {:noreply, push_navigate(socket, to: "/admin/workspaces/#{uuid}")}
  end

  def handle_event("create_workspace", params, socket) do
    ws =
      WorkspaceContext.new_workspace(%{
        name: params["name"],
        slug: params["slug"],
        description: params["description"]
      })

    case WorkspaceContext.create_workspace(ws) do
      {:ok, workspace} ->
        AuditModule.log_user(
          socket.assigns.current_user,
          "created",
          "workspace",
          workspace.uuid,
          workspace.name
        )

        {:noreply,
         socket
         |> assign(:show_add, false)
         |> put_flash(:info, "Workspace created")
         |> load_workspaces()}

      {:error, changeset} ->
        msg = changeset.errors |> Enum.map(fn {f, {m, _}} -> "#{f}: #{m}" end) |> Enum.at(0)
        {:noreply, put_flash(socket, :error, msg)}
    end
  end

  def handle_event("edit_workspace", %{"uuid" => uuid}, socket) do
    case WorkspaceContext.get_workspace_by_uuid(uuid) do
      nil -> {:noreply, put_flash(socket, :error, "Workspace not found")}
      ws -> {:noreply, assign(socket, :editing_workspace, ws)}
    end
  end

  def handle_event("update_workspace", params, socket) do
    ws = socket.assigns.editing_workspace

    case WorkspaceContext.update_workspace(ws, %{
           name: params["name"],
           slug: params["slug"],
           description: params["description"]
         }) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:editing_workspace, nil)
         |> put_flash(:info, "Workspace updated")
         |> load_workspaces()}

      {:error, changeset} ->
        msg = changeset.errors |> Enum.map(fn {f, {m, _}} -> "#{f}: #{m}" end) |> Enum.at(0)
        {:noreply, put_flash(socket, :error, msg)}
    end
  end

  def handle_event("delete_workspace", %{"uuid" => uuid}, socket) do
    socket = assign(socket, :confirm, nil)

    case WorkspaceContext.get_workspace_by_uuid(uuid) do
      nil ->
        {:noreply, put_flash(socket, :error, "Workspace not found")}

      ws ->
        ProjectContext.get_projects_by_workspace(ws.id, 0, 10000)
        |> Enum.each(fn p ->
          ProjectContext.update_project(p, %{workspace_id: nil})
        end)

        WorkspaceContext.delete_workspace(ws)
        {:noreply, socket |> put_flash(:info, "Workspace deleted") |> load_workspaces()}
    end
  end

  def handle_event("next_page", _, socket) do
    if socket.assigns.page < socket.assigns.total_pages,
      do: {:noreply, socket |> assign(:page, socket.assigns.page + 1) |> load_workspaces()},
      else: {:noreply, socket}
  end

  def handle_event("prev_page", _, socket) do
    if socket.assigns.page > 1,
      do: {:noreply, socket |> assign(:page, socket.assigns.page - 1) |> load_workspaces()},
      else: {:noreply, socket}
  end

  defp load_workspaces(socket) do
    user = socket.assigns.current_user
    offset = (socket.assigns.page - 1) * @per_page

    all_workspaces = WorkspaceContext.get_workspaces(offset, @per_page)
    total = WorkspaceContext.count_workspaces()

    workspaces =
      all_workspaces
      |> Enum.map(fn ws ->
        project_count =
          if user.role == "super" do
            ProjectContext.count_projects_by_workspace(ws.id)
          else
            user_teams = Lynx.Module.TeamModule.get_user_teams(user.id)
            team_ids = Enum.map(user_teams, & &1.id)
            ProjectContext.count_projects_by_workspace_and_teams(ws.id, team_ids)
          end

        Map.put(ws, :project_count, project_count)
      end)
      |> Enum.filter(fn ws -> user.role == "super" || ws.project_count > 0 end)

    assign(socket, workspaces: workspaces, total_pages: max(ceil(total / @per_page), 1))
  end
end

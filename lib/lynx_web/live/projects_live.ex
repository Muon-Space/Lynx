defmodule LynxWeb.ProjectsLive do
  use LynxWeb, :live_view

  alias Lynx.Module.ProjectModule
  alias Lynx.Module.TeamModule
  alias Lynx.Module.AuditModule

  on_mount {LynxWeb.LiveAuth, :require_auth}

  @per_page 10

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user
    all_teams = if user.role == "super", do: TeamModule.get_teams(0, 10000), else: TeamModule.get_user_teams(user.id, 0, 10000)

    socket =
      socket
      |> assign(:page, 1)
      |> assign(:show_add, false)
      |> assign(:editing_project, nil)
      |> assign(:editing_teams, [])
      |> assign(:all_teams, all_teams)
      |> load_projects()

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.nav current_user={@current_user} active="projects" />
    <div class="max-w-7xl mx-auto px-6">
      <.page_header title="Projects" />

      <div class="flex justify-end mb-4">
        <.button phx-click="show_add" variant="primary">+ Add Project</.button>
      </div>

      <.modal :if={@show_add} id="add-project" show on_cancel={JS.push("hide_add")}>
        <h3 class="text-lg font-semibold mb-4">Add New Project</h3>
        <form phx-submit="create_project" class="space-y-4">
          <.input name="name" label="Name" value="" required />
          <.input name="slug" label="Slug" value="" required />
          <.input name="description" label="Description" type="textarea" value="" required />
          <.input name="team_ids" label="Teams" type="select" multiple options={Enum.map(@all_teams, &{&1.name, &1.uuid})} value={[]} hint="Hold Ctrl/Cmd to select multiple" />
          <div class="flex gap-3 pt-2">
            <.button type="submit" variant="primary">Create</.button>
            <.button phx-click="hide_add" variant="secondary">Cancel</.button>
          </div>
        </form>
      </.modal>

      <.modal :if={@editing_project} id="edit-project" show on_cancel={JS.push("hide_edit")}>
        <h3 class="text-lg font-semibold mb-4">Edit Project</h3>
        <form phx-submit="update_project" class="space-y-4">
          <.input name="name" label="Name" value={@editing_project.name} required />
          <.input name="slug" label="Slug" value={@editing_project.slug} required />
          <.input name="description" label="Description" type="textarea" value={@editing_project.description} required />
          <.input name="team_ids" label="Teams" type="select" multiple options={Enum.map(@all_teams, &{&1.name, &1.uuid})} value={@editing_teams} hint="Hold Ctrl/Cmd to select multiple" />
          <div class="flex gap-3 pt-2">
            <.button type="submit" variant="primary">Update</.button>
            <.button phx-click="hide_edit" variant="secondary">Cancel</.button>
          </div>
        </form>
      </.modal>

      <.card>
        <.table rows={@projects}>
          <:col :let={project} label="Name">{project.name}</:col>
          <:col :let={project} label="Environments">{Lynx.Module.EnvironmentModule.count_project_envs(project.id)}</:col>
          <:col :let={project} label="Teams">
            <%= for team <- ProjectModule.get_project_teams(project.id) do %>
              <.badge color="blue">{team.name}</.badge>
            <% end %>
          </:col>
          <:col :let={project} label="Created">
            <span class="text-xs text-gray-500">{Calendar.strftime(project.inserted_at, "%Y-%m-%d %H:%M")}</span>
          </:col>
          <:action :let={project}>
            <.button phx-click="view_project" phx-value-uuid={project.uuid} variant="ghost" size="sm">View</.button>
            <.button phx-click="edit_project" phx-value-uuid={project.uuid} variant="ghost" size="sm">Edit</.button>
            <.button phx-click="delete_project" phx-value-uuid={project.uuid} variant="ghost" size="sm" data-confirm="Delete this project and all its environments?">Delete</.button>
          </:action>
        </.table>
        <.pagination page={@page} total_pages={@total_pages} />
      </.card>
    </div>
    """
  end

  @impl true
  def handle_event("show_add", _, socket), do: {:noreply, assign(socket, :show_add, true)}
  def handle_event("hide_add", _, socket), do: {:noreply, assign(socket, :show_add, false)}
  def handle_event("hide_edit", _, socket), do: {:noreply, assign(socket, :editing_project, nil)}

  def handle_event("view_project", %{"uuid" => uuid}, socket) do
    {:noreply, push_navigate(socket, to: "/admin/projects/#{uuid}")}
  end

  def handle_event("create_project", params, socket) do
    case ProjectModule.create_project(%{
           name: params["name"],
           slug: params["slug"],
           description: params["description"],
           team_ids: List.wrap(params["team_ids"])
         }) do
      {:ok, project} ->
        AuditModule.log_system("created", "project", project.uuid, project.name)
        {:noreply, socket |> assign(:show_add, false) |> put_flash(:info, "Project created") |> load_projects()}
      {:error, msg} ->
        {:noreply, put_flash(socket, :error, msg)}
    end
  end

  def handle_event("edit_project", %{"uuid" => uuid}, socket) do
    case ProjectModule.get_project_by_uuid(uuid) do
      {:ok, project} ->
        teams = ProjectModule.get_project_team_uuids(project.id)
        {:noreply, assign(socket, editing_project: project, editing_teams: teams)}
      _ -> {:noreply, put_flash(socket, :error, "Project not found")}
    end
  end

  def handle_event("update_project", params, socket) do
    case ProjectModule.update_project(%{
           uuid: socket.assigns.editing_project.uuid,
           name: params["name"],
           slug: params["slug"],
           description: params["description"],
           team_ids: List.wrap(params["team_ids"])
         }) do
      {:ok, _} ->
        {:noreply, socket |> assign(:editing_project, nil) |> put_flash(:info, "Project updated") |> load_projects()}
      {:error, msg} ->
        {:noreply, put_flash(socket, :error, msg)}
    end
  end

  def handle_event("delete_project", %{"uuid" => uuid}, socket) do
    case ProjectModule.delete_project_by_uuid(uuid) do
      {:ok, _} -> {:noreply, socket |> put_flash(:info, "Project deleted") |> load_projects()}
      _ -> {:noreply, put_flash(socket, :error, "Failed to delete")}
    end
  end

  def handle_event("next_page", _, socket) do
    if socket.assigns.page < socket.assigns.total_pages,
      do: {:noreply, socket |> assign(:page, socket.assigns.page + 1) |> load_projects()},
      else: {:noreply, socket}
  end

  def handle_event("prev_page", _, socket) do
    if socket.assigns.page > 1,
      do: {:noreply, socket |> assign(:page, socket.assigns.page - 1) |> load_projects()},
      else: {:noreply, socket}
  end

  defp load_projects(socket) do
    user = socket.assigns.current_user
    offset = (socket.assigns.page - 1) * @per_page

    {projects, total} =
      if user.role == "super" do
        {ProjectModule.get_projects(offset, @per_page), ProjectModule.count_projects()}
      else
        {ProjectModule.get_projects(user.id, offset, @per_page), ProjectModule.count_projects(user.id)}
      end

    assign(socket, projects: projects, total_pages: max(ceil(total / @per_page), 1))
  end
end

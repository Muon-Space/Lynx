defmodule LynxWeb.ProjectsLive do
  use LynxWeb, :live_view

  alias Lynx.Context.ProjectContext
  alias Lynx.Context.TeamContext
  alias Lynx.Context.AuditContext
  alias Lynx.Context.WorkspaceContext

  @per_page 10

  @impl true
  def mount(%{"workspace_uuid" => ws_uuid}, _session, socket) do
    case WorkspaceContext.get_workspace_by_uuid(ws_uuid) do
      nil ->
        {:ok, redirect(socket, to: "/admin/workspaces")}

      workspace ->
        user = socket.assigns.current_user

        socket =
          socket
          |> assign(:workspace, workspace)
          |> assign(:page, 1)
          |> assign(:show_add, false)
          |> assign(:add_slug, "")
          |> assign(:editing_project, nil)
          |> assign(:editing_teams, [])
          |> assign(:add_team_options, team_options(user, ""))
          |> assign(:editing_team_options, [])
          |> assign(:confirm, nil)
          |> load_projects()

        {:ok, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.nav current_user={@current_user} active="workspaces" />
    <div class="max-w-7xl mx-auto px-6 pb-16">
      <.page_header title={@workspace.name} subtitle={@workspace.description} />
      <div class="flex items-center justify-between mb-4">
        <nav class="flex items-center gap-2 text-sm text-secondary">
          <a href="/admin/workspaces" class="hover:text-foreground">Workspaces</a>
          <span>/</span>
          <span class="text-foreground font-medium">{@workspace.name}</span>
        </nav>
        <div class="flex items-center gap-2">
          <a
            :if={@current_user.role == "super"}
            href={"/admin/workspaces/#{@workspace.uuid}/policies"}
            class="text-xs px-3 py-1.5 rounded-lg border border-border-input text-secondary hover:bg-surface-secondary"
          >
            Policies
          </a>
          <.button phx-click="show_add" variant="primary">+ Add Project</.button>
        </div>
      </div>

      <.modal :if={@show_add} id="add-project" show on_close="hide_add">
        <h3 class="text-lg font-semibold mb-4">Add New Project</h3>
        <form phx-submit="create_project" phx-change="add_form_change" class="space-y-4">
          <.input name="name" label="Name" value="" required />
          <.input name="slug" label="Slug" value={@add_slug} required />
          <.input name="description" label="Description" type="textarea" value="" required />
          <.combobox id="add-project-teams" name="team_ids" label="Teams" multiple options={@add_team_options} selected={[]} hint="Type to search; click to select multiple" />
          <div class="flex gap-3 pt-2">
            <.button type="submit" variant="primary">Create</.button>
            <.button phx-click="hide_add" variant="secondary">Cancel</.button>
          </div>
        </form>
      </.modal>

      <.modal :if={@editing_project} id="edit-project" show on_close="hide_edit">
        <h3 class="text-lg font-semibold mb-4">Edit Project</h3>
        <form phx-submit="update_project" phx-change="edit_form_change" class="space-y-4">
          <.input name="name" label="Name" value={@editing_project.name} required />
          <.input name="slug" label="Slug" value={@editing_project.slug} required />
          <.input name="description" label="Description" type="textarea" value={@editing_project.description} required />
          <.combobox id={"edit-project-teams-#{@editing_project.uuid}"} name="team_ids" label="Teams" multiple options={@editing_team_options} selected={@editing_teams} hint="Type to search; click to add or remove" />
          <div class="flex gap-3 pt-2">
            <.button type="submit" variant="primary">Update</.button>
            <.button phx-click="hide_edit" variant="secondary">Cancel</.button>
          </div>
        </form>
      </.modal>

      <.confirm_dialog :if={@confirm} message={@confirm.message} confirm_event={@confirm.event} confirm_value={@confirm.value} />

      <.card>
        <.table rows={@projects} row_click={fn project -> JS.navigate("/admin/projects/#{project.uuid}") end}>
          <:col :let={project} label="Name"><span class="font-medium text-clickable">{project.name}</span></:col>
          <:col :let={project} label="Slug"><code class="text-xs bg-inset px-1.5 py-0.5 rounded">{project.slug}</code></:col>
          <:col :let={project} label="Environments">{Lynx.Context.EnvironmentContext.count_project_envs(project.id)}</:col>
          <:col :let={project} label="Teams">
            <%= for team <- ProjectContext.get_project_teams(project.id) do %>
              <.badge color="blue">{team.name}</.badge>
            <% end %>
          </:col>
          <:col :let={project} label="Created">
            <span class="text-xs text-muted">{Calendar.strftime(project.inserted_at, "%Y-%m-%d %H:%M")}</span>
          </:col>
          <:action :let={project}>
            <.button phx-click="edit_project" phx-value-uuid={project.uuid} variant="ghost" size="sm">Edit</.button>
            <.button phx-click="confirm_delete" phx-value-uuid={project.uuid} variant="ghost" size="sm">Delete</.button>
          </:action>
        </.table>
        <.pagination page={@page} total_pages={@total_pages} />
      </.card>
    </div>
    """
  end

  @impl true
  def handle_event("show_add", _, socket) do
    {:noreply,
     assign(socket,
       show_add: true,
       add_slug: "",
       add_team_options: team_options(socket.assigns.current_user, "")
     )}
  end

  def handle_event("hide_add", _, socket), do: {:noreply, assign(socket, :show_add, false)}
  def handle_event("hide_edit", _, socket), do: {:noreply, assign(socket, :editing_project, nil)}

  def handle_event("add_form_change", params, socket) do
    slug =
      (params["name"] || "")
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]/, "-")
      |> String.replace(~r/-+/, "-")
      |> String.trim("-")

    options = team_options(socket.assigns.current_user, params["_q_team_ids"] || "")

    {:noreply, socket |> assign(:add_slug, slug) |> assign(:add_team_options, options)}
  end

  def handle_event("edit_form_change", params, socket) do
    options = team_options(socket.assigns.current_user, params["_q_team_ids"] || "")
    {:noreply, assign(socket, :editing_team_options, options)}
  end

  def handle_event("view_project", %{"uuid" => uuid}, socket) do
    {:noreply, push_navigate(socket, to: "/admin/projects/#{uuid}")}
  end

  def handle_event("create_project", params, socket) do
    case ProjectContext.create_project_from_data(%{
           name: params["name"],
           slug: params["slug"],
           description: params["description"],
           team_ids: List.wrap(params["team_ids"]),
           workspace_id: socket.assigns.workspace.id
         }) do
      {:ok, project} ->
        AuditContext.log_user(
          socket.assigns.current_user,
          "created",
          "project",
          project.uuid,
          project.name
        )

        {:noreply,
         socket
         |> assign(:show_add, false)
         |> put_flash(:info, "Project created")
         |> load_projects()}

      {:error, msg} ->
        {:noreply, put_flash(socket, :error, msg)}
    end
  end

  def handle_event("edit_project", %{"uuid" => uuid}, socket) do
    case ProjectContext.fetch_project_by_uuid(uuid) do
      {:ok, project} ->
        teams = ProjectContext.get_project_team_options(project.id)

        {:noreply,
         assign(socket,
           editing_project: project,
           editing_teams: teams,
           editing_team_options: team_options(socket.assigns.current_user, "")
         )}

      _ ->
        {:noreply, put_flash(socket, :error, "Project not found")}
    end
  end

  def handle_event("update_project", params, socket) do
    case ProjectContext.update_project_from_data(%{
           uuid: socket.assigns.editing_project.uuid,
           name: params["name"],
           slug: params["slug"],
           description: params["description"],
           team_ids: List.wrap(params["team_ids"])
         }) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:editing_project, nil)
         |> put_flash(:info, "Project updated")
         |> load_projects()}

      {:error, msg} ->
        {:noreply, put_flash(socket, :error, msg)}
    end
  end

  def handle_event("confirm_delete", %{"uuid" => uuid}, socket) do
    {:noreply,
     assign(socket, :confirm, %{
       message: "Delete this project and all its environments?",
       event: "delete_project",
       value: %{uuid: uuid}
     })}
  end

  def handle_event("cancel_confirm", _, socket), do: {:noreply, assign(socket, :confirm, nil)}

  def handle_event("delete_project", %{"uuid" => uuid}, socket) do
    socket = assign(socket, :confirm, nil)

    case ProjectContext.delete_project_by_uuid(uuid) do
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

  defp team_options(%{role: "super"}, query),
    do: TeamContext.search_teams(query) |> Enum.map(&{&1.name, &1.uuid})

  defp team_options(user, query),
    do: TeamContext.search_user_teams(user.id, query) |> Enum.map(&{&1.name, &1.uuid})

  defp load_projects(socket) do
    user = socket.assigns.current_user
    workspace = socket.assigns.workspace
    offset = (socket.assigns.page - 1) * @per_page

    {projects, total} =
      if user.role == "super" do
        {Lynx.Context.ProjectContext.get_projects_by_workspace(workspace.id, offset, @per_page),
         Lynx.Context.ProjectContext.count_projects_by_workspace(workspace.id)}
      else
        user_teams = TeamContext.get_user_teams(user.id)
        team_ids = Enum.map(user_teams, & &1.id)

        {Lynx.Context.ProjectContext.get_projects_by_workspace_and_teams(
           workspace.id,
           team_ids,
           offset,
           @per_page
         ),
         Lynx.Context.ProjectContext.count_projects_by_workspace_and_teams(workspace.id, team_ids)}
      end

    assign(socket, projects: projects, total_pages: max(ceil(total / @per_page), 1))
  end
end

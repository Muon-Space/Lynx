defmodule LynxWeb.TeamsLive do
  use LynxWeb, :live_view

  alias Lynx.Context.TeamContext
  alias Lynx.Context.UserContext
  alias Lynx.Context.AuditContext
  alias Lynx.Context.ProjectContext
  alias Lynx.Context.RoleContext

  @per_page 10

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page, 1)
      |> assign(:show_add, false)
      |> assign(:add_slug, "")
      |> assign(:editing_team, nil)
      |> assign(:editing_members, [])
      |> assign(:editing_member_options, [])
      |> assign(:add_member_options, user_options(""))
      |> assign(:roles, RoleContext.list_roles())
      |> assign(:confirm, nil)
      |> load_teams()

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.confirm_dialog :if={@confirm} message={@confirm.message} confirm_event={@confirm.event} confirm_value={@confirm.value} />
    <.nav current_user={@current_user} active="teams" />
    <div class="max-w-7xl mx-auto px-6 pb-16">
      <.page_header title="Teams" subtitle="Organize users into teams for project access control" />

      <div class="flex justify-end mb-4">
        <.button phx-click="show_add" variant="primary">+ Add Team</.button>
      </div>

      <.modal :if={@show_add} id="add-team" show on_close="hide_add">
        <h3 class="text-lg font-semibold mb-4">Add New Team</h3>
        <form phx-submit="create_team" phx-change="add_form_change" class="space-y-4">
          <.input name="name" label="Name" value="" required />
          <.input name="slug" label="Slug" value={@add_slug} required />
          <.input name="description" label="Description" type="textarea" value="" required />
          <.combobox id="add-team-members" name="members" label="Members" multiple options={@add_member_options} selected={[]} hint="Type to search; click to select multiple" />
          <div class="flex gap-3 pt-2">
            <.button type="submit" variant="primary">Create</.button>
            <.button phx-click="hide_add" variant="secondary">Cancel</.button>
          </div>
        </form>
      </.modal>

      <.modal :if={@editing_team} id="edit-team" show on_close="hide_edit">
        <h3 class="text-lg font-semibold mb-4">Edit Team</h3>
        <form phx-submit="update_team" phx-change="edit_form_change" class="space-y-4">
          <.input name="name" label="Name" value={@editing_team.name} required />
          <.input name="slug" label="Slug" value={@editing_team.slug} required />
          <.input name="description" label="Description" type="textarea" value={@editing_team.description} required />
          <.combobox id={"edit-team-members-#{@editing_team.uuid}"} name="members" label="Members" multiple options={@editing_member_options} selected={@editing_members} hint="Type to search; click to add or remove" />
          <div class="flex gap-3 pt-2">
            <.button type="submit" variant="primary">Update</.button>
            <.button phx-click="hide_edit" variant="secondary">Cancel</.button>
          </div>
        </form>
      </.modal>

      <.card>
        <.table rows={@teams}>
          <:col :let={team} label="Name">{team.name}</:col>
          <:col :let={team} label="Slug"><code class="text-xs bg-inset px-1.5 py-0.5 rounded">{team.slug}</code></:col>
          <:col :let={team} label="Members">{UserContext.count_team_users(team.id)}</:col>
          <:col :let={team} label="Projects & Roles">
            <.role_assignments_summary assignments={team.assignments} />
          </:col>
          <:col :let={team} label="Created">
            <span class="text-xs text-muted">{Calendar.strftime(team.inserted_at, "%Y-%m-%d %H:%M")}</span>
          </:col>
          <:action :let={team}>
            <.button phx-click="edit_team" phx-value-uuid={team.uuid} variant="ghost" size="sm">Edit</.button>
            <.button phx-click="confirm_action" phx-value-event="delete_team" phx-value-message="Delete this team?" phx-value-uuid={team.uuid} variant="ghost" size="sm">Delete</.button>
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
    do:
      {:noreply,
       assign(socket, show_add: true, add_slug: "", add_member_options: user_options(""))}

  def handle_event("hide_add", _, socket), do: {:noreply, assign(socket, :show_add, false)}

  def handle_event("add_form_change", params, socket) do
    slug =
      (params["name"] || "")
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]/, "-")
      |> String.replace(~r/-+/, "-")
      |> String.trim("-")

    options = user_options(params["_q_members"] || "")

    {:noreply, socket |> assign(:add_slug, slug) |> assign(:add_member_options, options)}
  end

  def handle_event("edit_form_change", params, socket) do
    options = user_options(params["_q_members"] || "")
    {:noreply, assign(socket, :editing_member_options, options)}
  end

  def handle_event("hide_edit", _, socket), do: {:noreply, assign(socket, :editing_team, nil)}

  def handle_event("create_team", params, socket) do
    case TeamContext.create_team_from_data(%{
           name: params["name"],
           slug: params["slug"],
           description: params["description"]
         }) do
      {:ok, team} ->
        TeamContext.sync_team_members(team.id, List.wrap(params["members"]))

        AuditContext.log_user(
          socket.assigns.current_user,
          "created",
          "team",
          team.uuid,
          team.name
        )

        {:noreply,
         socket |> assign(:show_add, false) |> put_flash(:info, "Team created") |> load_teams()}

      {:error, msg} ->
        {:noreply, put_flash(socket, :error, msg)}
    end
  end

  def handle_event("edit_team", %{"uuid" => uuid}, socket) do
    case TeamContext.fetch_team_by_uuid(uuid) do
      {:ok, team} ->
        members = TeamContext.get_team_member_options(team.id)

        {:noreply,
         assign(socket,
           editing_team: team,
           editing_members: members,
           editing_member_options: user_options("")
         )}

      _ ->
        {:noreply, put_flash(socket, :error, "Team not found")}
    end
  end

  def handle_event("update_team", params, socket) do
    case TeamContext.update_team_from_data(%{
           uuid: socket.assigns.editing_team.uuid,
           name: params["name"],
           slug: params["slug"],
           description: params["description"]
         }) do
      {:ok, team} ->
        TeamContext.sync_team_members(team.id, List.wrap(params["members"]))

        {:noreply,
         socket |> assign(:editing_team, nil) |> put_flash(:info, "Team updated") |> load_teams()}

      {:error, msg} ->
        {:noreply, put_flash(socket, :error, msg)}
    end
  end

  def handle_event("delete_team", %{"uuid" => uuid}, socket) do
    socket = assign(socket, :confirm, nil)

    case TeamContext.delete_team_by_uuid(uuid) do
      {:ok, _} -> {:noreply, socket |> put_flash(:info, "Team deleted") |> load_teams()}
      _ -> {:noreply, put_flash(socket, :error, "Failed to delete")}
    end
  end

  def handle_event("next_page", _, socket) do
    if socket.assigns.page < socket.assigns.total_pages,
      do: {:noreply, socket |> assign(:page, socket.assigns.page + 1) |> load_teams()},
      else: {:noreply, socket}
  end

  def handle_event("prev_page", _, socket) do
    if socket.assigns.page > 1,
      do: {:noreply, socket |> assign(:page, socket.assigns.page - 1) |> load_teams()},
      else: {:noreply, socket}
  end

  defp user_options(query) do
    UserContext.search_users(query || "") |> Enum.map(&{&1.name, &1.uuid})
  end

  defp load_teams(socket) do
    offset = (socket.assigns.page - 1) * @per_page
    teams = TeamContext.get_teams(offset, @per_page)
    roles_by_id = Map.new(socket.assigns[:roles] || RoleContext.list_roles(), &{&1.id, &1.name})

    teams =
      Enum.map(teams, fn team ->
        assignments =
          team.id
          |> ProjectContext.list_team_project_assignments()
          |> Enum.map(fn {project, pt} ->
            %{project: project, role_name: Map.get(roles_by_id, pt.role_id, "unknown")}
          end)

        Map.put(team, :assignments, assignments)
      end)

    total = TeamContext.count_teams()
    assign(socket, teams: teams, total_pages: max(ceil(total / @per_page), 1))
  end
end

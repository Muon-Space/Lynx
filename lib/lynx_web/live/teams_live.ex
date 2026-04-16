defmodule LynxWeb.TeamsLive do
  use LynxWeb, :live_view

  alias Lynx.Module.TeamModule
  alias Lynx.Module.UserModule
  alias Lynx.Module.AuditModule

  on_mount {LynxWeb.LiveAuth, :require_super}

  @per_page 10

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page, 1)
      |> assign(:show_add, false)
      |> assign(:editing_team, nil)
      |> assign(:editing_members, [])
      |> assign(:all_users, UserModule.get_users(0, 10000))
      |> load_teams()

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.nav current_user={@current_user} active="teams" />
    <div class="max-w-7xl mx-auto px-6">
      <.page_header title="Teams" />

      <div class="flex justify-end mb-4">
        <.button phx-click="show_add" variant="primary">+ Add Team</.button>
      </div>

      <.modal :if={@show_add} id="add-team" show on_cancel={JS.push("hide_add")}>
        <h3 class="text-lg font-semibold mb-4">Add New Team</h3>
        <form phx-submit="create_team" class="space-y-4">
          <.input name="name" label="Name" value="" required phx-keyup="slugify_name" phx-target={@myself || ""} />
          <.input name="slug" label="Slug" value="" required />
          <.input name="description" label="Description" type="textarea" value="" required />
          <.input name="members" label="Members" type="select" multiple options={Enum.map(@all_users, &{&1.name, &1.uuid})} value={[]} hint="Hold Ctrl/Cmd to select multiple" />
          <div class="flex gap-3 pt-2">
            <.button type="submit" variant="primary">Create</.button>
            <.button phx-click="hide_add" variant="secondary">Cancel</.button>
          </div>
        </form>
      </.modal>

      <.modal :if={@editing_team} id="edit-team" show on_cancel={JS.push("hide_edit")}>
        <h3 class="text-lg font-semibold mb-4">Edit Team</h3>
        <form phx-submit="update_team" class="space-y-4">
          <.input name="name" label="Name" value={@editing_team.name} required />
          <.input name="slug" label="Slug" value={@editing_team.slug} required />
          <.input name="description" label="Description" type="textarea" value={@editing_team.description} required />
          <.input name="members" label="Members" type="select" multiple options={Enum.map(@all_users, &{&1.name, &1.uuid})} value={@editing_members} hint="Hold Ctrl/Cmd to select multiple" />
          <div class="flex gap-3 pt-2">
            <.button type="submit" variant="primary">Update</.button>
            <.button phx-click="hide_edit" variant="secondary">Cancel</.button>
          </div>
        </form>
      </.modal>

      <.card>
        <.table rows={@teams}>
          <:col :let={team} label="Name">{team.name}</:col>
          <:col :let={team} label="Slug"><code class="text-xs bg-gray-100 px-1.5 py-0.5 rounded">{team.slug}</code></:col>
          <:col :let={team} label="Members">{UserModule.count_team_users(team.id)}</:col>
          <:col :let={team} label="Projects">{Lynx.Module.ProjectModule.count_projects_by_team(team.id)}</:col>
          <:col :let={team} label="Created">
            <span class="text-xs text-gray-500">{Calendar.strftime(team.inserted_at, "%Y-%m-%d %H:%M")}</span>
          </:col>
          <:action :let={team}>
            <.button phx-click="edit_team" phx-value-uuid={team.uuid} variant="ghost" size="sm">Edit</.button>
            <.button phx-click="delete_team" phx-value-uuid={team.uuid} variant="ghost" size="sm" data-confirm="Delete this team?">Delete</.button>
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
  def handle_event("hide_edit", _, socket), do: {:noreply, assign(socket, :editing_team, nil)}

  def handle_event("create_team", params, socket) do
    case TeamModule.create_team(%{name: params["name"], slug: params["slug"], description: params["description"]}) do
      {:ok, team} ->
        TeamModule.sync_team_members(team.id, List.wrap(params["members"]))
        AuditModule.log_system("created", "team", team.uuid, team.name)
        {:noreply, socket |> assign(:show_add, false) |> put_flash(:info, "Team created") |> load_teams()}
      {:error, msg} ->
        {:noreply, put_flash(socket, :error, msg)}
    end
  end

  def handle_event("edit_team", %{"uuid" => uuid}, socket) do
    case TeamModule.get_team_by_uuid(uuid) do
      {:ok, team} ->
        members = TeamModule.get_team_members(team.id)
        {:noreply, assign(socket, editing_team: team, editing_members: members)}
      _ -> {:noreply, put_flash(socket, :error, "Team not found")}
    end
  end

  def handle_event("update_team", params, socket) do
    case TeamModule.update_team(%{uuid: socket.assigns.editing_team.uuid, name: params["name"], slug: params["slug"], description: params["description"]}) do
      {:ok, team} ->
        TeamModule.sync_team_members(team.id, List.wrap(params["members"]))
        {:noreply, socket |> assign(:editing_team, nil) |> put_flash(:info, "Team updated") |> load_teams()}
      {:error, msg} ->
        {:noreply, put_flash(socket, :error, msg)}
    end
  end

  def handle_event("delete_team", %{"uuid" => uuid}, socket) do
    case TeamModule.delete_team_by_uuid(uuid) do
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

  defp load_teams(socket) do
    offset = (socket.assigns.page - 1) * @per_page
    teams = TeamModule.get_teams(offset, @per_page)
    total = TeamModule.count_teams()
    assign(socket, teams: teams, total_pages: max(ceil(total / @per_page), 1))
  end
end

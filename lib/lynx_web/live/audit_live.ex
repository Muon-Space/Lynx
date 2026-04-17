defmodule LynxWeb.AuditLive do
  use LynxWeb, :live_view

  alias Lynx.Module.AuditModule

  on_mount {LynxWeb.LiveAuth, :require_super}

  @per_page 50

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page, 1)
      |> assign(:per_page, @per_page)
      |> assign(:filter_action, "")
      |> assign(:filter_resource, "")
      |> load_events()

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.nav current_user={@current_user} active="audit" />
    <div class="max-w-7xl mx-auto px-6 pb-16">
      <.page_header title="Audit Log" subtitle="Track who did what and when" />

      <.card>
        <div class="flex gap-4 mb-6">
          <form phx-change="filter" class="flex gap-4">
            <div class="w-48">
              <.input name="action" type="select" value={@filter_action} prompt="All Actions" options={[
                {"Created", "created"}, {"Updated", "updated"}, {"Deleted", "deleted"},
                {"Locked", "locked"}, {"Unlocked", "unlocked"}, {"State Pushed", "state_pushed"},
                {"Login", "login"}, {"SSO Login", "sso_login"}, {"Generated", "generated"}, {"Revoked", "revoked"}
              ]} />
            </div>
            <div class="w-48">
              <.input name="resource_type" type="select" value={@filter_resource} prompt="All Resources" options={[
                {"Project", "project"}, {"Environment", "environment"}, {"Team", "team"},
                {"User", "user"}, {"Snapshot", "snapshot"}, {"Settings", "settings"},
                {"SCIM Token", "scim_token"}, {"OIDC Provider", "oidc_provider"}
              ]} />
            </div>
          </form>
        </div>

        <.table rows={@events}>
          <:col :let={event} label="Time">
            <span class="text-muted text-xs">{format_datetime(event.inserted_at)}</span>
          </:col>
          <:col :let={event} label="Actor">
            <.badge color={if event.actor_type == "system", do: "gray", else: "blue"}>
              {event.actor_name || "system"}
            </.badge>
          </:col>
          <:col :let={event} label="Action">
            <.badge color={action_color(event.action)}>{event.action}</.badge>
          </:col>
          <:col :let={event} label="Resource">
            <code class="text-xs bg-inset px-1.5 py-0.5 rounded">{event.resource_type}</code>
          </:col>
          <:col :let={event} label="Name">
            {event.resource_name || event.resource_id || "-"}
          </:col>
        </.table>

        <.pagination page={@page} total_pages={@total_pages} />
      </.card>
    </div>
    """
  end

  @impl true
  def handle_event("filter", params, socket) do
    socket =
      socket
      |> assign(:filter_action, params["action"] || "")
      |> assign(:filter_resource, params["resource_type"] || "")
      |> assign(:page, 1)
      |> load_events()

    {:noreply, socket}
  end

  @impl true
  def handle_event("next_page", _, socket) do
    if socket.assigns.page < socket.assigns.total_pages do
      {:noreply, socket |> assign(:page, socket.assigns.page + 1) |> load_events()}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("prev_page", _, socket) do
    if socket.assigns.page > 1 do
      {:noreply, socket |> assign(:page, socket.assigns.page - 1) |> load_events()}
    else
      {:noreply, socket}
    end
  end

  defp load_events(socket) do
    offset = (socket.assigns.page - 1) * socket.assigns.per_page

    opts = %{
      offset: offset,
      limit: socket.assigns.per_page,
      action: non_empty(socket.assigns.filter_action),
      resource_type: non_empty(socket.assigns.filter_resource)
    }

    {events, total} = AuditModule.list_events(opts)
    total_pages = max(ceil(total / socket.assigns.per_page), 1)

    socket
    |> assign(:events, events)
    |> assign(:total_count, total)
    |> assign(:total_pages, total_pages)
  end

  defp non_empty(""), do: nil
  defp non_empty(v), do: v

  defp action_color("created"), do: "green"
  defp action_color("updated"), do: "blue"
  defp action_color("deleted"), do: "red"
  defp action_color("locked"), do: "yellow"
  defp action_color("unlocked"), do: "yellow"
  defp action_color("state_pushed"), do: "purple"
  defp action_color("login"), do: "blue"
  defp action_color("sso_login"), do: "blue"
  defp action_color(_), do: "gray"

  defp format_datetime(nil), do: "-"

  defp format_datetime(dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
  end
end

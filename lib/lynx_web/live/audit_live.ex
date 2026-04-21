defmodule LynxWeb.AuditLive do
  use LynxWeb, :live_view

  alias Lynx.Context.AuditContext

  @per_page 50

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:filter_action, "")
      |> assign(:filter_resource, "")
      |> reset_stream()

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

        <div class="overflow-x-auto">
          <table class="w-full text-sm">
            <thead class="border-b border-border text-left text-secondary font-medium">
              <tr>
                <th class="px-4 py-3">Time</th>
                <th class="px-4 py-3">Actor</th>
                <th class="px-4 py-3">Action</th>
                <th class="px-4 py-3">Resource</th>
                <th class="px-4 py-3">Name</th>
              </tr>
            </thead>
            <tbody id="audit-events" phx-update="stream">
              <tr :for={{dom_id, event} <- @streams.events} id={dom_id} class="border-b border-border hover:bg-surface-secondary">
                <td class="px-4 py-3">
                  <span class="text-muted text-xs">{format_datetime(event.inserted_at)}</span>
                </td>
                <td class="px-4 py-3">
                  <.badge color={if event.actor_type == "system", do: "gray", else: "blue"}>
                    {event.actor_name || "system"}
                  </.badge>
                </td>
                <td class="px-4 py-3">
                  <.badge color={action_color(event.action)}>{event.action}</.badge>
                </td>
                <td class="px-4 py-3">
                  <code class="text-xs bg-inset px-1.5 py-0.5 rounded">{event.resource_type}</code>
                </td>
                <td class="px-4 py-3">
                  {event.resource_name || event.resource_id || "-"}
                </td>
              </tr>
            </tbody>
          </table>
          <div :if={@empty?} class="px-4 py-8 text-center text-muted">No records found.</div>
        </div>

        <div :if={@has_more?} class="flex justify-center mt-4">
          <button phx-click="load_more" class="px-4 py-2 text-sm rounded-lg border border-border-input text-secondary hover:bg-surface-secondary">
            Load more
          </button>
        </div>
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
      |> reset_stream()

    {:noreply, socket}
  end

  def handle_event("load_more", _, socket) do
    {events, total} = fetch_events(socket, socket.assigns.next_offset)
    new_offset = socket.assigns.next_offset + length(events)

    {:noreply,
     socket
     |> stream(:events, events)
     |> assign(:next_offset, new_offset)
     |> assign(:has_more?, new_offset < total)}
  end

  defp reset_stream(socket) do
    {events, total} = fetch_events(socket, 0)

    socket
    |> stream(:events, events, reset: true)
    |> assign(:next_offset, length(events))
    |> assign(:has_more?, length(events) < total)
    |> assign(:empty?, events == [])
  end

  defp fetch_events(socket, offset) do
    opts = %{
      offset: offset,
      limit: @per_page,
      action: non_empty(socket.assigns.filter_action),
      resource_type: non_empty(socket.assigns.filter_resource)
    }

    AuditContext.list_events(opts)
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

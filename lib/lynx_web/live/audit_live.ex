defmodule LynxWeb.AuditLive do
  use LynxWeb, :live_view

  alias Lynx.Context.{AuditContext, EnvironmentContext, ProjectContext}

  @per_page 50

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(:filters, default_filters()) |> assign(:link_index, %{})}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filters = filters_from_params(params)

    socket =
      socket
      |> assign(:filters, filters)
      |> reset_stream()

    {:noreply, socket}
  end

  defp default_filters do
    %{
      action: "",
      resource_type: "",
      resource_id: "",
      actor: "",
      from: "",
      to: "",
      # When true + (resource_type, resource_id) is set on a project or env,
      # the AuditContext query expands to include child resources (env+unit
      # under a project; unit under an env). Set by the "Audit history" links
      # on project / env pages.
      include_children: false
    }
  end

  # URL-driven filter state — `<.link patch=...>` carries `?action=...&...`,
  # the LV's `handle_params/3` decodes them, and `phx-change="filter"`
  # navigates to a new URL with the same shape. Means an admin can copy/paste
  # a filtered view, refresh, or hit the CSV export endpoint with the same
  # query string.
  defp filters_from_params(params) do
    %{
      action: params["action"] || "",
      resource_type: params["resource_type"] || "",
      resource_id: params["resource_id"] || "",
      # Back-compat with bookmarked URLs from the previous `actor_email` name.
      actor: params["actor"] || params["actor_email"] || "",
      from: params["from"] || "",
      to: params["to"] || "",
      include_children: params["include_children"] in ["1", "true", true]
    }
  end

  defp non_empty_params(filters) do
    filters
    |> Enum.reject(fn {_k, v} -> v in [nil, "", false] end)
    |> Enum.map(fn
      {k, true} -> {to_string(k), "1"}
      {k, v} -> {to_string(k), to_string(v)}
    end)
    |> Enum.into(%{})
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.nav current_user={@current_user} active="audit" />
    <div class="max-w-7xl mx-auto px-6 pb-16">
      <.page_header title="Audit Log" subtitle="Track who did what and when" />

      <.card>
        <form phx-change="filter" phx-submit="filter" class="grid grid-cols-1 md:grid-cols-3 gap-3 mb-4">
          <.input name="action" type="select" label="Action" value={@filters.action} prompt="All Actions" options={[
            {"Created", "created"}, {"Updated", "updated"}, {"Deleted", "deleted"},
            {"Locked", "locked"}, {"Unlocked", "unlocked"}, {"State Pushed", "state_pushed"},
            {"Login", "login"}, {"SSO Login", "sso_login"}, {"Generated", "generated"}, {"Revoked", "revoked"}
          ]} />
          <.input name="resource_type" type="select" label="Resource type" value={@filters.resource_type} prompt="All Resources" options={[
            {"Project", "project"}, {"Environment", "environment"}, {"Team", "team"},
            {"User", "user"}, {"Snapshot", "snapshot"}, {"Settings", "settings"},
            {"SCIM Token", "scim_token"}, {"OIDC Provider", "oidc_provider"}
          ]} />
          <.input name="resource_id" type="text" label="Resource ID" value={@filters.resource_id} placeholder="UUID or path" />
          <.input name="actor" type="text" label="Actor" value={@filters.actor} placeholder="Name, email, or 'system'…" phx-debounce="300" />
          <.date_input id="audit-filter-from" name="from" label="From (UTC)" value={@filters.from} />
          <.date_input id="audit-filter-to" name="to" label="To (UTC)" value={@filters.to} />
        </form>

        <div class="flex justify-between items-center mb-3">
          <div class="flex items-center gap-4">
            <a href={"/admin/audit"} class="text-xs underline text-muted hover:text-foreground" :if={any_filters?(@filters)}>Clear filters</a>
            <%!-- include_children only meaningful when scoping by project / env --%>
            <label :if={@filters.resource_type in ["project", "environment"] and @filters.resource_id != ""} class="flex items-center gap-2 text-xs text-secondary cursor-pointer">
              <input
                type="checkbox"
                name="include_children"
                checked={@filters.include_children}
                phx-click="toggle_include_children"
                class="rounded border-border-input text-accent focus:ring-accent"
              />
              {if @filters.resource_type == "project",
                do: "Include env + unit + snapshot events",
                else: "Include unit events"}
            </label>
          </div>
          <a href={export_url(@filters)} class="text-sm rounded-lg border border-border-input px-3 py-1.5 text-secondary hover:bg-surface-secondary">
            Export CSV
          </a>
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
                  <%= case Map.get(@link_index, event.uuid) do %>
                    <% nil -> %>
                      {event.resource_name || event.resource_id || "-"}
                    <% path -> %>
                      <.link navigate={path} class="text-clickable hover:text-clickable-hover">
                        {event.resource_name || event.resource_id || "-"}
                      </.link>
                  <% end %>
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
    filters = Map.merge(socket.assigns.filters, filters_from_params(params))
    {:noreply, push_patch(socket, to: ~p"/admin/audit?#{non_empty_params(filters)}")}
  end

  def handle_event("toggle_include_children", _, socket) do
    filters = %{
      socket.assigns.filters
      | include_children: !socket.assigns.filters.include_children
    }

    {:noreply, push_patch(socket, to: ~p"/admin/audit?#{non_empty_params(filters)}")}
  end

  def handle_event("load_more", _, socket) do
    {events, total} = fetch_events(socket, socket.assigns.next_offset)
    new_offset = socket.assigns.next_offset + length(events)

    {:noreply,
     socket
     |> stream(:events, events)
     |> assign(:next_offset, new_offset)
     |> assign(:has_more?, new_offset < total)
     |> assign(:link_index, Map.merge(socket.assigns.link_index, build_link_index(events)))}
  end

  defp reset_stream(socket) do
    {events, total} = fetch_events(socket, 0)

    socket
    |> stream(:events, events, reset: true)
    |> assign(:next_offset, length(events))
    |> assign(:has_more?, length(events) < total)
    |> assign(:empty?, events == [])
    |> assign(:link_index, build_link_index(events))
  end

  defp fetch_events(socket, offset) do
    f = socket.assigns.filters

    opts = %{
      offset: offset,
      limit: @per_page,
      action: non_empty(f.action),
      resource_type: non_empty(f.resource_type),
      resource_id: non_empty(f.resource_id),
      actor: non_empty(f.actor),
      date_from: parse_date(f.from, :start_of_day),
      date_to: parse_date(f.to, :end_of_day),
      include_children: f.include_children
    }

    AuditContext.list_events(opts)
  end

  defp parse_date(nil, _), do: nil
  defp parse_date("", _), do: nil

  defp parse_date(value, bound) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date_to_bound(date, bound)
      _ -> nil
    end
  end

  defp date_to_bound(date, :start_of_day), do: DateTime.new!(date, ~T[00:00:00])
  defp date_to_bound(date, :end_of_day), do: DateTime.new!(date, ~T[23:59:59])

  defp any_filters?(filters), do: filters |> Map.values() |> Enum.any?(&(&1 not in [nil, ""]))

  defp export_url(filters) do
    qs = filters |> non_empty_params() |> URI.encode_query()
    if qs == "", do: "/admin/audit/export.csv", else: "/admin/audit/export.csv?#{qs}"
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

  # Build `%{event_uuid => path | nil}` for the page so the Name cell can
  # render as a deep link. Two batched lookups cover env/unit (env_uuid →
  # project.uuid via env.project_id); grant rows already carry project_uuid
  # in `metadata` (no DB hit). Resources without a detail page (team, user,
  # oidc_rule) get nil and render as plain text.
  #
  # `resource_id` for `state_pushed` / `locked` / `unlocked` events from
  # `tf_controller.log_tf_event` is a `ws/proj/env[/unit]` *path*, not a UUID.
  # Filter to UUID-shaped values before sending to the SQL `WHERE uuid IN`,
  # otherwise Postgres rejects the cast (22P02) and 400s the LV mount.
  defp build_link_index(events) do
    env_uuids =
      events
      |> Enum.filter(&(&1.resource_type in ["environment", "unit"] and uuid?(&1.resource_id)))
      |> Enum.map(& &1.resource_id)
      |> Enum.uniq()

    env_to_project_id = EnvironmentContext.get_project_ids_by_env_uuids(env_uuids)

    project_uuids =
      ProjectContext.get_uuids_by_ids(env_to_project_id |> Map.values() |> Enum.uniq())

    Enum.into(events, %{}, fn ev ->
      {ev.uuid, resource_link(ev, env_to_project_id, project_uuids)}
    end)
  end

  defp uuid?(s) when is_binary(s), do: match?({:ok, _}, Ecto.UUID.cast(s))
  defp uuid?(_), do: false

  defp resource_link(%{resource_type: "project", resource_id: id}, _, _) when is_binary(id),
    do: "/admin/projects/#{id}"

  defp resource_link(%{resource_type: "snapshot", resource_id: id}, _, _) when is_binary(id),
    do: "/admin/snapshots/#{id}"

  defp resource_link(%{resource_type: "role", resource_id: id}, _, _) when is_binary(id),
    do: "/admin/roles/#{id}"

  defp resource_link(%{resource_type: type, resource_id: env_uuid}, env_to_pid, pid_to_uuid)
       when type in ["environment", "unit"] and is_binary(env_uuid) do
    with project_id when not is_nil(project_id) <- Map.get(env_to_pid, env_uuid),
         project_uuid when not is_nil(project_uuid) <- Map.get(pid_to_uuid, project_id) do
      "/admin/projects/#{project_uuid}/environments/#{env_uuid}"
    else
      _ -> nil
    end
  end

  defp resource_link(%{resource_type: type} = ev, _, _)
       when type in ["project_team", "user_project"] do
    case metadata_get(ev, "project_uuid") do
      nil -> nil
      project_uuid -> "/admin/projects/#{project_uuid}"
    end
  end

  defp resource_link(%{resource_type: "team", resource_id: id}, _, _) when is_binary(id),
    do: "/admin/teams?edit=#{id}"

  defp resource_link(%{resource_type: "user", resource_id: id}, _, _) when is_binary(id),
    do: "/admin/users?edit=#{id}"

  # Settings page exposes its sections via `?tab=`. Land on the right one
  # so the audit row jumps the user straight to the relevant card.
  defp resource_link(%{resource_type: type}, _, _) do
    case settings_tab_for(type) do
      nil -> nil
      tab -> "/admin/settings?tab=#{tab}"
    end
  end

  defp settings_tab_for("scim_token"), do: "scim"
  defp settings_tab_for("scim"), do: "scim"
  defp settings_tab_for("sso_scim"), do: "scim"
  defp settings_tab_for("saml_certificate"), do: "sso"
  defp settings_tab_for("oidc_provider"), do: "oidc"
  defp settings_tab_for("settings"), do: "general"
  defp settings_tab_for("email"), do: "general"
  defp settings_tab_for("general"), do: "general"
  defp settings_tab_for(_), do: nil

  defp metadata_get(%{metadata: nil}, _), do: nil
  defp metadata_get(%{metadata: ""}, _), do: nil

  defp metadata_get(%{metadata: json}, key) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, map} when is_map(map) -> Map.get(map, key)
      _ -> nil
    end
  end

  defp metadata_get(_, _), do: nil
end

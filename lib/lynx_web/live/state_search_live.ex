defmodule LynxWeb.StateSearchLive do
  @moduledoc """
  Cross-workspace full-text search over Terraform state files (issue #37).

  Backed by `Lynx.Context.StateContext.search_states_for_user/3`, which
  applies RBAC scoping per (project, env). A regular user only sees hits
  from envs they have `state:read` on; super sees every workspace.

  URL pattern is `/admin/state-search?q=<term>` so a result list is
  copy-pasteable / linkable.
  """
  use LynxWeb, :live_view

  alias Lynx.Context.StateContext

  @per_search 50

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(:query, "") |> assign(:results, []) |> assign(:searched?, false)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    query = params["q"] || ""
    {:noreply, run_search(socket, query)}
  end

  @impl true
  def handle_event("search", %{"q" => query}, socket) do
    path =
      case String.trim(query) do
        "" -> ~p"/admin/state-search"
        trimmed -> ~p"/admin/state-search?#{%{q: trimmed}}"
      end

    {:noreply, push_patch(socket, to: path)}
  end

  defp run_search(socket, query) do
    trimmed = String.trim(query)

    cond do
      trimmed == "" ->
        socket
        |> assign(:query, "")
        |> assign(:results, [])
        |> assign(:searched?, false)

      true ->
        results =
          StateContext.search_states_for_user(trimmed, socket.assigns.current_user,
            limit: @per_search
          )

        socket
        |> assign(:query, trimmed)
        |> assign(:results, results)
        |> assign(:searched?, true)
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.nav current_user={@current_user} active="state-search" />
    <div class="max-w-7xl mx-auto px-6 pb-16">
      <.page_header
        title="State Search"
        subtitle="Find which environments reference a Terraform resource."
      />

      <.card>
        <form phx-change="search" phx-submit="search" class="mb-4">
          <.input
            name="q"
            type="text"
            label="Search term"
            value={@query}
            placeholder="e.g. aws_iam_role.deploy_bot"
            phx-debounce="300"
            autocomplete="off"
          />
          <p class="text-xs text-muted mt-2">
            Searches the latest state per environment / unit. Only environments you have <code>state:read</code> on are shown.
          </p>
        </form>

        <%= cond do %>
          <% not @searched? -> %>
            <div class="px-4 py-12 text-center text-muted">
              Type a resource name, attribute, or any token from a state file to search.
            </div>
          <% @results == [] -> %>
            <div class="px-4 py-12 text-center text-muted">
              No matching state files. Either the term doesn't appear, or you don't have <code>state:read</code> on the envs that contain it.
            </div>
          <% true -> %>
            <ul class="divide-y divide-border">
              <li :for={result <- @results} class="py-4">
                <.result_row result={result} />
              </li>
            </ul>
        <% end %>
      </.card>
    </div>
    """
  end

  attr :result, :map, required: true

  defp result_row(assigns) do
    ~H"""
    <div class="flex items-baseline justify-between gap-4">
      <.link
        navigate={~p"/admin/projects/#{@result.project.uuid}/environments/#{@result.environment.uuid}"}
        class="text-clickable hover:text-clickable-hover text-sm font-medium"
      >
        {@result.workspace.name} › {@result.project.name} › {@result.environment.name}<%= if @result.sub_path != "" do %> / {@result.sub_path}<% end %>
      </.link>
      <span class="text-xs text-muted whitespace-nowrap">{format_datetime(@result.inserted_at)}</span>
    </div>
    <pre class="mt-2 text-xs bg-inset rounded-lg p-3 overflow-x-auto whitespace-pre-wrap break-words"><code>{render_snippet(@result.snippet)}</code></pre>
    """
  end

  # Snippet comes back from Postgres with `⟦MARK⟧...⟦/MARK⟧` sentinel markers
  # around the matched terms. We escape the snippet so any literal HTML in
  # the JSON body can't inject markup, then swap our sentinels for `<mark>`
  # tags. Returns a `Phoenix.HTML.safe()` tuple so the template renders the
  # `<mark>` as real markup instead of escaped text.
  defp render_snippet(snippet) when is_binary(snippet) do
    snippet
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
    |> String.replace(
      "⟦MARK⟧",
      ~s(<mark class="bg-badge-warning-bg text-badge-warning-text rounded px-0.5">)
    )
    |> String.replace("⟦/MARK⟧", "</mark>")
    |> Phoenix.HTML.raw()
  end

  defp render_snippet(_), do: ""

  defp format_datetime(nil), do: "-"
  defp format_datetime(dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")
end

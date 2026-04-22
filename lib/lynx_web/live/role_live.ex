defmodule LynxWeb.RoleLive do
  @moduledoc """
  Single-role detail view at `/admin/roles/:uuid` (super only).

  Shows the role's metadata + permission set + every grant currently using
  it (team grants, user grants, OIDC rules) with deep links into the
  Project Access card / env page that owns each grant. The recovery path
  when an admin needs to remove a role: jump straight to the place each
  grant lives instead of scrolling through every project.
  """
  use LynxWeb, :live_view

  alias Lynx.Context.RoleContext

  @impl true
  def mount(%{"uuid" => uuid}, _session, socket) do
    case RoleContext.get_role_by_uuid(uuid) do
      nil ->
        {:ok, redirect(socket, to: "/admin/roles")}

      role ->
        permissions =
          role.id
          |> RoleContext.permissions_for()
          |> Enum.sort()

        grants = RoleContext.list_role_grants(role.id)

        {:ok,
         socket
         |> assign(:role, role)
         |> assign(:permissions, permissions)
         |> assign(:grants, grants)
         |> assign(
           :total_grants,
           length(grants.teams) + length(grants.users) + length(grants.oidc_rules)
         )}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.nav current_user={@current_user} active="roles" />
    <div class="max-w-7xl mx-auto px-6 pb-16">
      <.page_header title={String.capitalize(@role.name)} subtitle={@role.description || "Custom role"} />

      <div class="flex items-center gap-2 mb-6 text-sm text-secondary">
        <a href="/admin/roles" class="hover:text-foreground">Roles</a>
        <span>/</span>
        <span class="text-foreground font-medium">{@role.name}</span>
        <.badge :if={@role.is_system} color="gray" class="ml-2">system</.badge>
      </div>

      <%!-- Permissions --%>
      <.card class="mb-6">
        <h3 class="text-base font-semibold mb-1">Permissions</h3>
        <p class="text-sm text-muted mb-4">{length(@permissions)} of {length(RoleContext.permissions())}</p>
        <div :if={@permissions == []} class="text-sm text-muted">
          No permissions assigned. This role grants nothing.
        </div>
        <div class="grid grid-cols-1 md:grid-cols-2 gap-3">
          <div :for={perm <- @permissions} class="text-sm">
            <code class="text-xs font-mono">{perm}</code>
            <p class="text-xs text-muted mt-0.5 leading-snug">
              {RoleContext.permission_description(perm)}
            </p>
          </div>
        </div>
      </.card>

      <%!-- Grants --%>
      <.card>
        <h3 class="text-base font-semibold mb-1">Grants</h3>
        <p class="text-sm text-muted mb-4">
          {grant_summary(@grants, @total_grants)}
        </p>

        <%= if @total_grants == 0 do %>
          <div class="text-sm text-muted py-8 text-center">
            This role isn't granted anywhere yet — safe to delete.
          </div>
        <% end %>

        <div :if={@grants.teams != []} class="mb-6">
          <h4 class="text-sm font-medium mb-2">Team grants ({length(@grants.teams)})</h4>
          <.table rows={@grants.teams}>
            <:col :let={g} label="Team">{g.team.name}</:col>
            <:col :let={g} label="Project">
              <a href={"/admin/projects/#{g.project.uuid}"} class="text-clickable hover:text-clickable-hover">
                {g.project.name}
              </a>
            </:col>
            <:col :let={g} label="Scope">
              <span :if={g.env}>
                <.badge color="blue">{g.env.name}</.badge>
              </span>
              <span :if={is_nil(g.env)} class="text-xs text-muted">All envs</span>
            </:col>
            <:col :let={g} label="Expires">
              <span :if={g.expires_at} class="text-xs">{format_expiry(g.expires_at)}</span>
              <span :if={is_nil(g.expires_at)} class="text-xs text-muted">permanent</span>
            </:col>
            <:action :let={g}>
              <a href={"/admin/projects/#{g.project.uuid}"} class="text-secondary hover:text-foreground text-xs px-3 py-1.5">
                Manage
              </a>
            </:action>
          </.table>
        </div>

        <div :if={@grants.users != []} class="mb-6">
          <h4 class="text-sm font-medium mb-2">Individual user grants ({length(@grants.users)})</h4>
          <.table rows={@grants.users}>
            <:col :let={g} label="User">
              {g.user.name} <span class="text-xs text-muted">({g.user.email})</span>
            </:col>
            <:col :let={g} label="Project">
              <a href={"/admin/projects/#{g.project.uuid}"} class="text-clickable hover:text-clickable-hover">
                {g.project.name}
              </a>
            </:col>
            <:col :let={g} label="Scope">
              <span :if={g.env}>
                <.badge color="blue">{g.env.name}</.badge>
              </span>
              <span :if={is_nil(g.env)} class="text-xs text-muted">All envs</span>
            </:col>
            <:col :let={g} label="Expires">
              <span :if={g.expires_at} class="text-xs">{format_expiry(g.expires_at)}</span>
              <span :if={is_nil(g.expires_at)} class="text-xs text-muted">permanent</span>
            </:col>
            <:action :let={g}>
              <a href={"/admin/projects/#{g.project.uuid}"} class="text-secondary hover:text-foreground text-xs px-3 py-1.5">
                Manage
              </a>
            </:action>
          </.table>
        </div>

        <div :if={@grants.oidc_rules != []}>
          <h4 class="text-sm font-medium mb-2">OIDC rules ({length(@grants.oidc_rules)})</h4>
          <.table rows={@grants.oidc_rules}>
            <:col :let={g} label="Rule">{g.rule.name}</:col>
            <:col :let={g} label="Provider">{g.provider.name}</:col>
            <:col :let={g} label="Project / Env">
              <a href={"/admin/projects/#{g.project.uuid}/environments/#{g.env.uuid}"} class="text-clickable hover:text-clickable-hover">
                {g.project.name} / {g.env.name}
              </a>
            </:col>
            <:col :let={g} label="Claims">
              <span class="text-xs font-mono">{format_claims(g.claim_rules)}</span>
            </:col>
            <:action :let={g}>
              <a
                href={"/admin/projects/#{g.project.uuid}"}
                title="Open the project page; click OIDC on the env row to manage rules"
                class="text-secondary hover:text-foreground text-xs px-3 py-1.5"
              >
                Manage
              </a>
            </:action>
          </.table>
        </div>
      </.card>
    </div>
    """
  end

  defp grant_summary(_grants, 0), do: "Not currently granted anywhere."

  defp grant_summary(grants, total) do
    parts =
      [
        {length(grants.teams), "team"},
        {length(grants.users), "user"},
        {length(grants.oidc_rules), "OIDC rule"}
      ]
      |> Enum.reject(fn {n, _} -> n == 0 end)
      |> Enum.map(fn
        {1, label} -> "1 #{label}"
        {n, label} -> "#{n} #{label}s"
      end)

    "#{total} active grant#{if total == 1, do: "", else: "s"} — #{Enum.join(parts, ", ")}."
  end

  defp format_expiry(%DateTime{} = dt) do
    delta = DateTime.diff(dt, DateTime.utc_now(), :second)

    cond do
      delta <= 0 -> "expired"
      delta < 3600 -> "in #{div(delta, 60)}m"
      delta < 86_400 -> "in #{div(delta, 3600)}h"
      true -> "in #{div(delta, 86_400)}d"
    end
  end

  defp format_claims(claims) when map_size(claims) == 0, do: "(none)"

  defp format_claims(claims) do
    claims
    |> Enum.map(fn {k, v} -> "#{k}=#{v}" end)
    |> Enum.join(", ")
  end
end

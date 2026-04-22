defmodule LynxWeb.RoleLiveTest do
  @moduledoc """
  Smoke for the role-detail page at `/admin/roles/:uuid`. Asserts the
  three grant tables render with the expected rows + deep links so an
  admin can jump straight to the Project Access card / env page that
  owns each grant.
  """
  use LynxWeb.LiveCase

  alias Lynx.Context.{ProjectContext, RoleContext, TeamContext, UserProjectContext}
  alias Lynx.Service.OIDCBackend

  setup %{conn: conn} do
    user = create_super()
    {:ok, conn: log_in_user(conn, user), user: user}
  end

  describe "mount" do
    test "renders role name + permissions + system badge", %{conn: conn} do
      role = RoleContext.get_role_by_name("planner")
      {:ok, _view, html} = live(conn, "/admin/roles/#{role.uuid}")

      assert html =~ "Planner"
      assert html =~ "system"
      assert html =~ "state:read"
    end

    test "redirects to /admin/roles for an unknown UUID", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/admin/roles"}}} =
               live(conn, "/admin/roles/00000000-0000-0000-0000-000000000000")
    end

    test "non-super redirected to login", %{conn: conn} do
      regular = create_user()
      conn = log_in_user(conn, regular)
      role = RoleContext.get_role_by_name("planner")

      assert {:error, {:redirect, %{to: "/login"}}} =
               live(conn, "/admin/roles/#{role.uuid}")
    end
  end

  describe "grants section" do
    test "renders 'safe to delete' when role has no grants", %{conn: conn} do
      {:ok, role} = RoleContext.create_role(%{name: "ghost", permissions: []})
      {:ok, _view, html} = live(conn, "/admin/roles/#{role.uuid}")

      assert html =~ "safe to delete"
    end

    test "lists team / user / OIDC grants with deep links", %{conn: conn} do
      {:ok, role} = RoleContext.create_role(%{name: "everywhere", permissions: []})

      ws = create_workspace()
      project = create_project(%{workspace_id: ws.id, name: "Backend"})
      env = create_env(project, %{name: "prod", slug: "prod"})

      # Team grant (env-specific so the env badge renders)
      {:ok, team} =
        TeamContext.create_team_from_data(%{
          name: "Platform",
          slug: "platform-#{System.unique_integer([:positive])}",
          description: "x"
        })

      ProjectContext.add_project_to_team(project.id, team.id, role.id, nil, env.id)

      # User grant (project-wide)
      target = create_user(%{email: "alice@example.com"})
      {:ok, _} = UserProjectContext.assign_role(target.id, project.id, role.id)

      # OIDC rule
      {:ok, provider} =
        OIDCBackend.create_provider(%{
          name: "github",
          discovery_url: "https://example.com/.well-known/openid-configuration",
          audience: "lynx"
        })

      {:ok, _} =
        OIDCBackend.create_rule(%{
          name: "deploy",
          claim_rules:
            Jason.encode!([%{"claim" => "repo", "operator" => "eq", "value" => "muon/infra"}]),
          provider_id: provider.id,
          environment_id: env.id,
          role_id: role.id
        })

      {:ok, _view, html} = live(conn, "/admin/roles/#{role.uuid}")

      # Three sections + grant counts
      assert html =~ "Team grants (1)"
      assert html =~ "Individual user grants (1)"
      assert html =~ "OIDC rules (1)"

      # Specific rows
      assert html =~ "Platform"
      assert html =~ "alice@example.com"
      assert html =~ "deploy"
      assert html =~ "github"

      # Claims render — regression for the bug where production list-shape
      # rules silently rendered "(none)" because decode_claim_rules/1 only
      # handled maps.
      assert html =~ "repo eq muon/infra"

      # Deep links
      assert html =~ "/admin/projects/#{project.uuid}"
      assert html =~ "/admin/projects/#{project.uuid}/environments/#{env.uuid}"
    end
  end
end

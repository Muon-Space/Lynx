defmodule Lynx.Context.RoleContextGrantsTest do
  @moduledoc """
  `RoleContext.list_role_grants/1` — joins across the three RBAC tables
  (project_teams, user_projects, oidc_access_rules) so the role-detail
  page can render every grant of a role with deep links.
  """
  use LynxWeb.LiveCase, async: false

  alias Lynx.Context.{ProjectContext, RoleContext, TeamContext, UserContext, UserProjectContext}
  alias Lynx.Service.OIDCBackend

  setup do
    mark_installed()
    :ok
  end

  describe "list_role_grants/1" do
    test "returns empty lists for an unused role" do
      {:ok, role} = RoleContext.create_role(%{name: "unused", permissions: []})

      assert %{teams: [], users: [], oidc_rules: []} =
               RoleContext.list_role_grants(role.id)
    end

    test "lists project-wide team grants with project + nil env" do
      {:ok, role} = RoleContext.create_role(%{name: "auditor", permissions: ["state:read"]})
      ws = create_workspace()
      project = create_project(%{workspace_id: ws.id, name: "Backend"})

      {:ok, team} =
        TeamContext.create_team_from_data(%{
          name: "Platform",
          slug: "platform-#{System.unique_integer([:positive])}",
          description: "x"
        })

      ProjectContext.add_project_to_team(project.id, team.id, role.id)

      %{teams: [grant]} = RoleContext.list_role_grants(role.id)
      assert grant.team.name == "Platform"
      assert grant.project.name == "Backend"
      assert grant.env == nil
      assert grant.expires_at == nil
    end

    test "lists env-specific team grants with the env joined" do
      {:ok, role} = RoleContext.create_role(%{name: "deployer", permissions: ["state:read"]})
      ws = create_workspace()
      project = create_project(%{workspace_id: ws.id})
      env = create_env(project, %{name: "production", slug: "prod"})

      {:ok, team} =
        TeamContext.create_team_from_data(%{
          name: "T",
          slug: "t-#{System.unique_integer([:positive])}",
          description: "x"
        })

      ProjectContext.add_project_to_team(project.id, team.id, role.id, nil, env.id)

      %{teams: [grant]} = RoleContext.list_role_grants(role.id)
      assert grant.env.name == "production"
    end

    test "lists individual user grants with expires_at preserved" do
      {:ok, role} = RoleContext.create_role(%{name: "temp", permissions: []})
      ws = create_workspace()
      project = create_project(%{workspace_id: ws.id})
      user = create_user(%{email: "alice@example.com"})

      future = DateTime.add(DateTime.utc_now(), 3600, :second)
      {:ok, _} = UserProjectContext.assign_role(user.id, project.id, role.id, future)

      %{users: [grant]} = RoleContext.list_role_grants(role.id)
      assert grant.user.email == "alice@example.com"
      assert grant.expires_at != nil
    end

    test "lists OIDC rules with provider + env + project + decoded claims" do
      {:ok, role} = RoleContext.create_role(%{name: "ci_planner", permissions: ["state:read"]})
      ws = create_workspace()
      project = create_project(%{workspace_id: ws.id, name: "Infra"})
      env = create_env(project, %{name: "prod", slug: "prod"})

      {:ok, provider} =
        OIDCBackend.create_provider(%{
          name: "github-actions",
          discovery_url: "https://example.com/.well-known/openid-configuration",
          audience: "lynx"
        })

      {:ok, _} =
        OIDCBackend.create_rule(%{
          name: "deploy",
          claim_rules: Jason.encode!(%{"repository" => "muon/infra"}),
          provider_id: provider.id,
          environment_id: env.id,
          role_id: role.id
        })

      %{oidc_rules: [grant]} = RoleContext.list_role_grants(role.id)
      assert grant.provider.name == "github-actions"
      assert grant.env.name == "prod"
      assert grant.project.name == "Infra"
      assert grant.claim_rules == %{"repository" => "muon/infra"}
    end

    test "all three lists populate when the role is granted across all three" do
      {:ok, role} = RoleContext.create_role(%{name: "everywhere", permissions: ["state:read"]})
      ws = create_workspace()
      project = create_project(%{workspace_id: ws.id})
      env = create_env(project, %{name: "e", slug: "e"})

      {:ok, team} =
        TeamContext.create_team_from_data(%{
          name: "T",
          slug: "t-#{System.unique_integer([:positive])}",
          description: "x"
        })

      ProjectContext.add_project_to_team(project.id, team.id, role.id)

      user = create_user()
      {:ok, _} = UserProjectContext.assign_role(user.id, project.id, role.id)

      {:ok, provider} =
        OIDCBackend.create_provider(%{
          name: "p",
          discovery_url: "https://example.com/.well-known/openid-configuration",
          audience: "lynx"
        })

      {:ok, _} =
        OIDCBackend.create_rule(%{
          name: "r",
          claim_rules: Jason.encode!(%{}),
          provider_id: provider.id,
          environment_id: env.id,
          role_id: role.id
        })

      grants = RoleContext.list_role_grants(role.id)
      assert length(grants.teams) == 1
      assert length(grants.users) == 1
      assert length(grants.oidc_rules) == 1
    end
  end

  # Quiet "imported but unused" if any context isn't referenced.
  _ = UserContext
end

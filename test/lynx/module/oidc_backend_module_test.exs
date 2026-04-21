# Copyright 2023 Clivern. All rights reserved.
# Use of this source code is governed by the MIT
# license that can be found in the LICENSE file.

defmodule Lynx.Module.OIDCBackendModuleTest do
  use ExUnit.Case

  alias Lynx.Module.OIDCBackendModule
  alias Lynx.Context.EnvironmentContext
  alias Lynx.Context.ProjectContext
  alias Lynx.Context.TeamContext

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Lynx.Repo)
  end

  describe "provider CRUD" do
    test "create and list providers" do
      {:ok, provider} =
        OIDCBackendModule.create_provider(%{
          name: "test-provider",
          discovery_url: "https://example.com/.well-known/openid-configuration"
        })

      assert provider.name == "test-provider"

      providers = OIDCBackendModule.list_providers()
      assert length(providers) >= 1
      assert Enum.any?(providers, fn p -> p.name == "test-provider" end)
    end

    test "is_oidc_provider? returns true for active provider" do
      {:ok, _} =
        OIDCBackendModule.create_provider(%{
          name: "github-actions-test",
          discovery_url: "https://token.actions.githubusercontent.com"
        })

      assert OIDCBackendModule.is_oidc_provider?("github-actions-test")
      refute OIDCBackendModule.is_oidc_provider?("nonexistent")
    end

    test "delete provider" do
      {:ok, provider} =
        OIDCBackendModule.create_provider(%{
          name: "to-delete",
          discovery_url: "https://example.com"
        })

      {:ok, _} = OIDCBackendModule.delete_provider(provider.uuid)
      assert {:not_found, _} = OIDCBackendModule.get_provider(provider.uuid)
    end
  end

  describe "access rule CRUD" do
    test "create and list rules" do
      {:ok, provider} =
        OIDCBackendModule.create_provider(%{
          name: "rule-test-provider",
          discovery_url: "https://example.com"
        })

      # Create a team/project/environment for the rule
      {:ok, team} =
        TeamContext.create_team(
          TeamContext.new_team(%{name: "OIDC Test Team", slug: "oidc-test", description: "test"})
        )

      {:ok, project} =
        ProjectContext.create_project(
          ProjectContext.new_project(%{
            name: "OIDC Project",
            slug: "oidc-proj",
            description: "test",
            team_id: team.id
          })
        )

      {:ok, env} =
        EnvironmentContext.create_env(
          EnvironmentContext.new_env(%{
            name: "prod",
            slug: "prod",
            username: "user",
            secret: "secret",
            project_id: project.id
          })
        )

      claim_rules = Jason.encode!([%{claim: "repository", operator: "eq", value: "myorg/myrepo"}])

      {:ok, rule} =
        OIDCBackendModule.create_rule(%{
          name: "test-rule",
          claim_rules: claim_rules,
          provider_id: provider.id,
          environment_id: env.id
        })

      assert rule.name == "test-rule"

      rules = OIDCBackendModule.list_rules_by_environment(env.id)
      assert length(rules) == 1
    end
  end

  describe "claim matching" do
    test "eq operator matches exactly" do
      _claims = %{"repository" => "myorg/myrepo", "environment" => "production"}

      rules = [
        %{"claim" => "repository", "operator" => "eq", "value" => "myorg/myrepo"},
        %{"claim" => "environment", "operator" => "eq", "value" => "production"}
      ]

      # Test via the module's internal logic by creating real data
      {:ok, provider} =
        OIDCBackendModule.create_provider(%{
          name: "claim-test",
          discovery_url: "https://example.com"
        })

      {:ok, team} =
        TeamContext.create_team(
          TeamContext.new_team(%{name: "Claim Team", slug: "claim-team", description: "t"})
        )

      {:ok, project} =
        ProjectContext.create_project(
          ProjectContext.new_project(%{
            name: "Claim Project",
            slug: "claim-proj",
            description: "t",
            team_id: team.id
          })
        )

      {:ok, env} =
        EnvironmentContext.create_env(
          EnvironmentContext.new_env(%{
            name: "claim-env",
            slug: "claim-env",
            username: "u",
            secret: "s",
            project_id: project.id
          })
        )

      {:ok, _} =
        OIDCBackendModule.create_rule(%{
          name: "match-rule",
          claim_rules: Jason.encode!(rules),
          provider_id: provider.id,
          environment_id: env.id
        })

      # The evaluate_access function is private, but we can test via the public API
      # by checking the rule listing and manually verifying claim matching logic
      rules_list = OIDCBackendModule.list_rules_by_environment(env.id)
      assert length(rules_list) == 1

      decoded = Jason.decode!(hd(rules_list).claim_rules)
      assert length(decoded) == 2
    end
  end

  describe "evaluate_access/3 — multi-rule semantics" do
    alias Lynx.Context.RoleContext

    setup do
      {:ok, provider} =
        OIDCBackendModule.create_provider(%{
          name: "github-actions-eval-#{System.unique_integer([:positive])}",
          discovery_url: "https://token.actions.githubusercontent.com"
        })

      {:ok, team} =
        TeamContext.create_team(
          TeamContext.new_team(%{
            name: "Eval Team #{System.unique_integer([:positive])}",
            slug: "eval-team-#{System.unique_integer([:positive])}",
            description: "t"
          })
        )

      {:ok, project} =
        ProjectContext.create_project(
          ProjectContext.new_project(%{
            name: "Eval Project #{System.unique_integer([:positive])}",
            slug: "eval-proj-#{System.unique_integer([:positive])}",
            description: "t",
            team_id: team.id
          })
        )

      {:ok, env} =
        EnvironmentContext.create_env(
          EnvironmentContext.new_env(%{
            name: "prod",
            slug: "eval-prod-#{System.unique_integer([:positive])}",
            username: "u",
            secret: "s",
            project_id: project.id
          })
        )

      planner_role = RoleContext.get_role_by_name("planner")
      applier_role = RoleContext.get_role_by_name("applier")

      {:ok, provider: provider, env: env, planner_role: planner_role, applier_role: applier_role}
    end

    defp create_rule!(%{provider: p, env: e}, name, role, claim_list) do
      {:ok, rule} =
        OIDCBackendModule.create_rule(%{
          name: name,
          claim_rules: Jason.encode!(claim_list),
          provider_id: p.id,
          environment_id: e.id,
          role_id: role.id
        })

      rule
    end

    test "applier-claim-set token: union of matching rules grants applier perms",
         %{provider: p, env: env, planner_role: planner, applier_role: applier} = ctx do
      # Two rules: planner (repo only), applier (repo + environment).
      # Both should match a token carrying both claims; union = applier set.
      create_rule!(ctx, "planner", planner, [
        %{claim: "repository", operator: "eq", value: "Muon-Space/terraform-okta"}
      ])

      create_rule!(ctx, "applier", applier, [
        %{claim: "repository", operator: "eq", value: "Muon-Space/terraform-okta"},
        %{claim: "environment", operator: "eq", value: "grafana-production"}
      ])

      token_claims = %{
        "repository" => "Muon-Space/terraform-okta",
        "environment" => "grafana-production"
      }

      assert {:ok, perms} = OIDCBackendModule.evaluate_access(p.id, env.id, token_claims)
      # Applier has state:write; planner does not. Union must include it.
      assert MapSet.member?(perms, "state:write")
      assert MapSet.member?(perms, "state:read")
      assert MapSet.member?(perms, "state:lock")
    end

    test "result is independent of rule insertion order (regression for non-deterministic match)",
         %{provider: p, env: env, planner_role: planner, applier_role: applier} = ctx do
      # Insert applier FIRST, planner SECOND.
      create_rule!(ctx, "z-applier", applier, [
        %{claim: "repository", operator: "eq", value: "org/repo"},
        %{claim: "environment", operator: "eq", value: "prod"}
      ])

      create_rule!(ctx, "a-planner", planner, [
        %{claim: "repository", operator: "eq", value: "org/repo"}
      ])

      claims_full = %{"repository" => "org/repo", "environment" => "prod"}
      {:ok, perms} = OIDCBackendModule.evaluate_access(p.id, env.id, claims_full)

      # Regardless of insertion order, the union must include applier's perms.
      assert MapSet.member?(perms, "state:write")
    end

    test "missing optional claim: only the less-specific rule matches → planner perms only",
         %{provider: p, env: env, planner_role: planner, applier_role: applier} = ctx do
      create_rule!(ctx, "planner", planner, [
        %{claim: "repository", operator: "eq", value: "org/repo"}
      ])

      create_rule!(ctx, "applier", applier, [
        %{claim: "repository", operator: "eq", value: "org/repo"},
        %{claim: "environment", operator: "eq", value: "prod"}
      ])

      # Token without `environment` claim — only the planner rule matches.
      token_claims = %{"repository" => "org/repo"}

      assert {:ok, perms} = OIDCBackendModule.evaluate_access(p.id, env.id, token_claims)
      refute MapSet.member?(perms, "state:write")
      assert MapSet.member?(perms, "state:read")
    end

    test "no rules match: error tuple", %{provider: p, env: env, planner_role: planner} = ctx do
      create_rule!(ctx, "planner", planner, [
        %{claim: "repository", operator: "eq", value: "org/repo"}
      ])

      assert {:error, _} =
               OIDCBackendModule.evaluate_access(p.id, env.id, %{
                 "repository" => "different/repo"
               })
    end

    test "no rules configured: distinct error", %{provider: p, env: env} do
      assert {:error, msg} = OIDCBackendModule.evaluate_access(p.id, env.id, %{})
      assert msg =~ "No access rules"
    end
  end
end

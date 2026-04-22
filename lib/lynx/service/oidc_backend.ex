# Copyright 2023 Clivern. All rights reserved.
# Use of this source code is governed by the MIT
# license that can be found in the LICENSE file.

defmodule Lynx.Service.OIDCBackend do
  @moduledoc """
  OIDC Backend Module - validates OIDC tokens for Terraform backend access.

  When a Terraform client authenticates with HTTP Basic Auth where the username
  matches an OIDC provider name, the password is treated as a JWT token and
  validated against the provider's JWKS. Access is granted if the token's claims
  match any active access rule for the target environment.
  """

  require Logger

  alias Lynx.Context.OIDCProviderContext
  alias Lynx.Context.OIDCAccessRuleContext
  alias Lynx.Context.RoleContext
  alias Lynx.Service.JWTService

  require OpenTelemetry.Tracer, as: Tracer

  @doc """
  Check if a username matches an active OIDC provider.
  """
  def is_oidc_provider?(username) do
    OIDCProviderContext.get_provider_by_name(username) != nil
  end

  @doc """
  Validate an OIDC token for access to a specific environment.
  Returns `{:ok, permissions :: MapSet.t(String.t())}` on success, or
  `{:error, reason}`. The permission set comes from the matched rule's role.
  """
  def validate_access(provider_name, jwt, environment_id) do
    Tracer.with_span "lynx.oidc.validate_access",
      attributes: %{
        "lynx.oidc.provider_name" => provider_name
      } do
      case OIDCProviderContext.get_provider_by_name(provider_name) do
        nil ->
          Tracer.set_status(:error, "unknown_provider")
          {:error, "Unknown OIDC provider: #{provider_name}"}

        provider ->
          case JWTService.validate_token(provider.discovery_url, jwt, provider.audience) do
            {:ok, claims} ->
              Tracer.set_attribute("lynx.oidc.claim_count", map_size(claims))
              evaluate_access(provider.id, environment_id, claims)

            {:error, reason} ->
              Logger.info("OIDC token validation failed for provider #{provider_name}: #{reason}")
              Tracer.set_status(:error, reason)
              {:error, "Token validation failed: #{reason}"}
          end
      end
    end
  end

  @doc """
  Resolve a token's claims against the rules for `(provider_id, environment_id)`
  and return the union of permissions from every matching rule.

  Why a union: a token can legitimately match multiple rules at once (e.g. a
  permissive `planner` rule matching just `repository=...` AND a more
  specific `applier` rule matching `repository=... AND environment=prod`).
  Picking the "first" was both non-deterministic (the underlying query was
  unordered) and semantically wrong — a less-specific rule could shadow the
  more-permissive one. Unioning means stacking rules is additive and
  predictable, matching how team grants compose in `RoleModule`.

  Public so it's testable end-to-end without going through JWT validation.
  """
  def evaluate_access(provider_id, environment_id, claims) do
    rules =
      OIDCAccessRuleContext.list_rules_by_provider_and_environment(provider_id, environment_id)

    cond do
      rules == [] ->
        {:error, "No access rules configured for this environment"}

      true ->
        matching_rules =
          Enum.filter(rules, fn rule ->
            rule.claim_rules
            |> Jason.decode!()
            |> all_claims_match?(claims)
          end)

        if matching_rules == [] do
          {:error, "Token claims do not match any access rule"}
        else
          permissions =
            Enum.reduce(matching_rules, MapSet.new(), fn rule, acc ->
              MapSet.union(acc, RoleContext.permissions_for(rule.role_id))
            end)

          {:ok, permissions}
        end
    end
  end

  defp all_claims_match?(claim_rules, claims) do
    Enum.all?(claim_rules, fn rule ->
      claim_value = get_nested_claim(claims, rule["claim"])
      match_claim?(rule["operator"], claim_value, rule["value"])
    end)
  end

  defp get_nested_claim(claims, claim_path) do
    String.split(claim_path, ".")
    |> Enum.reduce(claims, fn key, acc ->
      case acc do
        %{} -> Map.get(acc, key)
        _ -> nil
      end
    end)
  end

  defp match_claim?(_operator, nil, _expected), do: false

  defp match_claim?("eq", actual, expected) when is_binary(actual),
    do: actual == expected

  defp match_claim?("contains", actual, expected) when is_binary(actual),
    do: String.contains?(actual, expected)

  defp match_claim?("starts_with", actual, expected) when is_binary(actual),
    do: String.starts_with?(actual, expected)

  defp match_claim?("matches", actual, expected) when is_binary(actual) do
    case Regex.compile(expected) do
      {:ok, regex} -> Regex.match?(regex, actual)
      _ -> false
    end
  end

  defp match_claim?(_, _, _), do: false

  # -- Provider CRUD --

  def create_provider(attrs) do
    provider =
      OIDCProviderContext.new_provider(%{
        name: attrs[:name],
        discovery_url: attrs[:discovery_url],
        audience: attrs[:audience]
      })

    OIDCProviderContext.create_provider(provider)
  end

  def update_provider(uuid, attrs) do
    case OIDCProviderContext.get_provider_by_uuid(uuid) do
      nil ->
        {:not_found, "Provider not found"}

      provider ->
        new_attrs = %{
          name: attrs[:name] || provider.name,
          discovery_url: attrs[:discovery_url] || provider.discovery_url,
          audience: Map.get(attrs, :audience, provider.audience),
          is_active: Map.get(attrs, :is_active, provider.is_active)
        }

        OIDCProviderContext.update_provider(provider, new_attrs)
    end
  end

  def delete_provider(uuid) do
    case OIDCProviderContext.get_provider_by_uuid(uuid) do
      nil -> {:not_found, "Provider not found"}
      provider -> OIDCProviderContext.delete_provider(provider)
    end
  end

  def list_providers, do: OIDCProviderContext.list_providers()

  def get_provider(uuid) do
    case OIDCProviderContext.get_provider_by_uuid(uuid) do
      nil -> {:not_found, "Provider not found"}
      provider -> {:ok, provider}
    end
  end

  # -- Access Rule CRUD --

  def create_rule(attrs) do
    role_id = attrs[:role_id] || default_role_id()

    rule =
      OIDCAccessRuleContext.new_rule(%{
        name: attrs[:name],
        claim_rules: attrs[:claim_rules],
        provider_id: attrs[:provider_id],
        environment_id: attrs[:environment_id],
        role_id: role_id
      })

    OIDCAccessRuleContext.create_rule(rule)
  end

  def update_rule(uuid, attrs) do
    case OIDCAccessRuleContext.get_rule_by_uuid(uuid) do
      nil ->
        {:not_found, "Rule not found"}

      rule ->
        new_attrs = %{
          name: attrs[:name] || rule.name,
          claim_rules: attrs[:claim_rules] || rule.claim_rules,
          is_active: Map.get(attrs, :is_active, rule.is_active),
          role_id: attrs[:role_id] || rule.role_id
        }

        OIDCAccessRuleContext.update_rule(rule, new_attrs)
    end
  end

  defp default_role_id do
    case RoleContext.get_role_by_name("applier") do
      nil -> raise "Seeded 'applier' role not found — run `mix ecto.migrate`"
      role -> role.id
    end
  end

  def delete_rule(uuid) do
    case OIDCAccessRuleContext.get_rule_by_uuid(uuid) do
      nil -> {:not_found, "Rule not found"}
      rule -> OIDCAccessRuleContext.delete_rule(rule)
    end
  end

  def list_rules_by_environment(environment_id) do
    OIDCAccessRuleContext.list_rules_by_environment(environment_id)
  end

  def list_rules_by_provider(provider_id) do
    OIDCAccessRuleContext.list_rules_by_provider(provider_id)
  end
end

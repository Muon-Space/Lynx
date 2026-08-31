# Copyright 2023 Clivern. All rights reserved.
# Use of this source code is governed by the MIT
# license that can be found in the LICENSE file.

defmodule LynxWeb.OIDCProviderController do
  @moduledoc """
  OIDC Provider Controller - manages OIDC providers and access rules
  """

  use LynxWeb, :controller
  use OpenApiSpex.ControllerSpecs

  require Logger

  alias Lynx.Service.OIDCBackend
  alias Lynx.Context.AuditContext
  alias LynxWeb.Schemas

  # Provider CRUD stays super-only — these are global SSO/IdP configs.
  plug :super_user
       when action in [:list_providers, :create_provider, :update_provider, :delete_provider]

  # Rule CRUD widens to anyone with `oidc_rule:manage` on the env's project
  # (admin role grants it by default). Project admins can now manage their
  # own envs' rules without going through a platform super user.
  plug LynxWeb.Plug.RequirePerm,
       [permission: "oidc_rule:manage", from: :oidc_rule_env]
       when action in [:list_rules, :create_rule]

  plug LynxWeb.Plug.RequirePerm,
       [permission: "oidc_rule:manage", from: :oidc_rule_uuid]
       when action == :delete_rule

  tags(["OIDC"])
  security([%{"api_key" => []}])

  operation(:list_providers,
    summary: "List OIDC providers (super only)",
    description:
      "Pass `name` to look a single provider up without paging the whole " <>
        "collection; the response envelope is unchanged and holds zero or one " <>
        "provider.",
    parameters: [
      name: [
        in: :query,
        type: :string,
        description: "Return only the provider with this exact name"
      ]
    ],
    responses: [
      ok: {"Providers", "application/json", Schemas.OIDCProviderList},
      forbidden: {"Forbidden", "application/json", Schemas.Error}
    ]
  )

  operation(:create_provider,
    summary: "Create an OIDC provider (super only)",
    request_body: {"Provider", "application/json", Schemas.OIDCProviderCreate},
    responses: [
      created: {"Created", "application/json", Schemas.OIDCProvider},
      bad_request: {"Validation error", "application/json", Schemas.Error},
      forbidden: {"Forbidden", "application/json", Schemas.Error}
    ]
  )

  operation(:update_provider,
    summary: "Update an OIDC provider (super only)",
    parameters: [uuid: [in: :path, required: true, type: :string]],
    request_body: {"Provider", "application/json", Schemas.OIDCProviderCreate},
    responses: [
      ok: {"Provider", "application/json", Schemas.OIDCProvider},
      bad_request: {"Validation error", "application/json", Schemas.Error},
      not_found: {"Not found", "application/json", Schemas.Error},
      forbidden: {"Forbidden", "application/json", Schemas.Error}
    ]
  )

  operation(:delete_provider,
    summary: "Delete an OIDC provider (super only)",
    parameters: [uuid: [in: :path, required: true, type: :string]],
    responses: [
      ok: {"Deleted", "application/json", Schemas.Success},
      not_found: {"Not found", "application/json", Schemas.Error},
      forbidden: {"Forbidden", "application/json", Schemas.Error}
    ]
  )

  operation(:list_rules,
    summary: "List OIDC access rules for an environment",
    description: "Requires `oidc_rule:manage` (admin) on the env's project.",
    parameters: [
      environment_id: [in: :path, required: true, type: :string, description: "Environment UUID"]
    ],
    responses: [
      ok: {"Rules", "application/json", Schemas.OIDCRuleList},
      forbidden: {"Forbidden", "application/json", Schemas.Error},
      not_found: {"Not found", "application/json", Schemas.Error}
    ]
  )

  operation(:create_rule,
    summary: "Create an OIDC access rule",
    description: "Requires `oidc_rule:manage` (admin) on the env's project.",
    request_body: {"Rule", "application/json", Schemas.OIDCRuleCreate},
    responses: [
      created: {"Created", "application/json", Schemas.OIDCRule},
      bad_request: {"Validation error", "application/json", Schemas.Error},
      forbidden: {"Forbidden", "application/json", Schemas.Error},
      not_found: {"Not found", "application/json", Schemas.Error}
    ]
  )

  operation(:delete_rule,
    summary: "Delete an OIDC access rule",
    description: "Requires `oidc_rule:manage` (admin) on the env's project.",
    parameters: [uuid: [in: :path, required: true, type: :string]],
    responses: [
      ok: {"Deleted", "application/json", Schemas.Success},
      not_found: {"Not found", "application/json", Schemas.Error},
      forbidden: {"Forbidden", "application/json", Schemas.Error}
    ]
  )

  defp super_user(conn, _opts) do
    if not conn.assigns[:is_super] do
      conn
      |> put_status(:forbidden)
      |> json(%{errorMessage: "Forbidden Access"})
      |> halt
    else
      conn
    end
  end

  # -- Providers --

  def list_providers(conn, params) do
    providers = providers_for(params["name"])

    conn
    |> json(%{
      providers:
        Enum.map(providers, fn p ->
          %{
            id: p.uuid,
            name: p.name,
            discoveryUrl: p.discovery_url,
            audience: p.audience,
            isActive: p.is_active,
            createdAt: p.inserted_at
          }
        end)
    })
  end

  # Exact-name lookup, a shortcut for "list everything and filter client-side".
  # The endpoint is already super-only, so there is no per-caller visibility to
  # preserve here. This endpoint has never paginated, so there is no
  # limit/offset to reconcile — the filtered response is the complete result.
  # Filtered from the same list the unfiltered branch returns, rather than via
  # OIDCProviderContext.get_provider_by_name/1: that function is on the OIDC
  # auth path and matches only active providers, which would hide a disabled
  # provider here while the unfiltered list still reports it with isActive false.
  defp providers_for(name) when is_binary(name) and name != "" do
    OIDCBackend.list_providers()
    |> Enum.filter(&(&1.name == name))
  end

  defp providers_for(_), do: OIDCBackend.list_providers()

  def create_provider(conn, params) do
    case OIDCBackend.create_provider(%{
           name: params["name"],
           discovery_url: params["discovery_url"],
           audience: params["audience"]
         }) do
      {:ok, provider} ->
        AuditContext.log(conn, "created", "oidc_provider", provider.uuid, provider.name)

        conn
        |> put_status(:created)
        |> json(%{
          id: provider.uuid,
          name: provider.name,
          discoveryUrl: provider.discovery_url,
          audience: provider.audience,
          successMessage: "Provider created successfully"
        })

      {:error, changeset} ->
        messages =
          changeset.errors
          |> Enum.map(fn {field, {message, _}} -> "#{field}: #{message}" end)

        conn
        |> put_status(:bad_request)
        |> json(%{errorMessage: Enum.at(messages, 0)})
    end
  end

  def update_provider(conn, %{"uuid" => uuid} = params) do
    case OIDCBackend.update_provider(uuid, %{
           name: params["name"],
           discovery_url: params["discovery_url"],
           audience: params["audience"]
         }) do
      {:ok, provider} ->
        conn
        |> json(%{
          id: provider.uuid,
          name: provider.name,
          discoveryUrl: provider.discovery_url,
          audience: provider.audience,
          successMessage: "Provider updated successfully"
        })

      {:not_found, _} ->
        conn |> put_status(:not_found) |> json(%{errorMessage: "Provider not found"})

      {:error, changeset} ->
        messages =
          changeset.errors
          |> Enum.map(fn {field, {message, _}} -> "#{field}: #{message}" end)

        conn
        |> put_status(:bad_request)
        |> json(%{errorMessage: Enum.at(messages, 0)})
    end
  end

  def delete_provider(conn, %{"uuid" => uuid}) do
    case OIDCBackend.delete_provider(uuid) do
      {:ok, _} ->
        AuditContext.log(conn, "deleted", "oidc_provider", uuid)
        conn |> json(%{successMessage: "Provider deleted successfully"})

      {:not_found, _} ->
        conn |> put_status(:not_found) |> json(%{errorMessage: "Provider not found"})
    end
  end

  # -- Access Rules --

  def list_rules(conn, %{"environment_id" => env_id}) do
    case Lynx.Context.EnvironmentContext.get_env_id_with_uuid(env_id) do
      nil ->
        conn |> put_status(:not_found) |> json(%{errorMessage: "Environment not found"})

      environment_id ->
        rules = OIDCBackend.list_rules_by_environment(environment_id)

        # providerId and environmentId are internal integer keys, which callers
        # cannot resolve back to the UUIDs every other endpoint speaks in. Emit
        # the UUIDs alongside them so a rule is round-trippable on its own.
        provider_uuids =
          Lynx.Context.OIDCProviderContext.list_providers()
          |> Map.new(&{&1.id, &1.uuid})

        conn
        |> json(%{
          rules:
            Enum.map(rules, fn r ->
              %{
                id: r.uuid,
                name: r.name,
                claimRules: Jason.decode!(r.claim_rules),
                providerId: r.provider_id,
                providerUuid: Map.get(provider_uuids, r.provider_id),
                environmentId: r.environment_id,
                environmentUuid: env_id,
                role: role_name_for(r.role_id),
                isActive: r.is_active,
                createdAt: r.inserted_at
              }
            end)
        })
    end
  end

  def create_rule(conn, params) do
    provider = Lynx.Context.OIDCProviderContext.get_provider_by_uuid(params["provider_id"])
    env_id = Lynx.Context.EnvironmentContext.get_env_id_with_uuid(params["environment_id"])

    if is_nil(provider) or is_nil(env_id) do
      conn
      |> put_status(:bad_request)
      |> json(%{errorMessage: "Invalid provider or environment"})
    else
      claim_rules =
        if is_binary(params["claim_rules"]) do
          params["claim_rules"]
        else
          Jason.encode!(params["claim_rules"])
        end

      case OIDCBackend.create_rule(%{
             name: params["name"],
             claim_rules: claim_rules,
             provider_id: provider.id,
             environment_id: env_id,
             role_id: resolve_role_id(params)
           }) do
        {:ok, rule} ->
          conn
          |> put_status(:created)
          |> json(%{
            id: rule.uuid,
            name: rule.name,
            claimRules: Jason.decode!(rule.claim_rules),
            successMessage: "Access rule created successfully"
          })

        {:error, changeset} ->
          messages =
            changeset.errors
            |> Enum.map(fn {field, {message, _}} -> "#{field}: #{message}" end)

          conn
          |> put_status(:bad_request)
          |> json(%{errorMessage: Enum.at(messages, 0)})
      end
    end
  end

  def delete_rule(conn, %{"uuid" => uuid}) do
    case OIDCBackend.delete_rule(uuid) do
      {:ok, _} ->
        conn |> json(%{successMessage: "Access rule deleted successfully"})

      {:not_found, _} ->
        conn |> put_status(:not_found) |> json(%{errorMessage: "Rule not found"})
    end
  end

  # Accept either an integer role_id (DB pk) or a string role name
  # ("planner", "applier", "admin"). Returns nil to mean "use the backend
  # default" (which is applier).
  defp resolve_role_id(%{"role_id" => id}) when is_integer(id), do: id

  defp resolve_role_id(%{"role" => name}) when is_binary(name) and name != "" do
    case Lynx.Context.RoleContext.get_role_by_name(name) do
      nil -> nil
      role -> role.id
    end
  end

  defp resolve_role_id(_), do: nil

  defp role_name_for(nil), do: nil

  defp role_name_for(id) do
    case Lynx.Context.RoleContext.get_role_by_id(id) do
      nil -> nil
      role -> role.name
    end
  end
end

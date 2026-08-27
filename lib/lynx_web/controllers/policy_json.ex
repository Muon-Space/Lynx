# Copyright 2023 Clivern. All rights reserved.
# Use of this source code is governed by the MIT
# license that can be found in the LICENSE file.

defmodule LynxWeb.PolicyJSON do
  alias Lynx.Context.PolicyContext
  alias Lynx.Model.Policy

  # Render policies list
  def render("list.json", %{policies: policies, metadata: metadata}) do
    scopes = PolicyContext.scope_uuids_for(policies)

    %{
      policies: Enum.map(policies, &render_policy(&1, Map.fetch!(scopes, &1.id))),
      _metadata: %{
        limit: metadata.limit,
        offset: metadata.offset,
        totalCount: metadata.totalCount
      }
    }
  end

  # Render policy
  def render("index.json", %{policy: policy}) do
    scopes = PolicyContext.scope_uuids_for([policy])

    render_policy(policy, Map.fetch!(scopes, policy.id))
  end

  # Render errors
  def render("error.json", %{message: message}) do
    %{errorMessage: message}
  end

  # Format policy. Scope is reported as UUIDs plus a derived `scope` tag so
  # a client never has to reverse-engineer it from which key is non-null,
  # and never sees the internal integer FKs.
  defp render_policy(policy, scope_uuids) do
    %{
      id: policy.uuid,
      name: policy.name,
      description: policy.description,
      regoSource: policy.rego_source,
      enabled: policy.enabled,
      scope: policy |> Policy.scope() |> scope_name(),
      workspaceId: scope_uuids.workspace_uuid,
      projectId: scope_uuids.project_uuid,
      environmentId: scope_uuids.environment_uuid,
      createdAt: policy.inserted_at,
      updatedAt: policy.updated_at
    }
  end

  # `Policy.scope/1` tags the environment scope `:env`; the API spells it
  # out to match the `environment_uuid` request field.
  defp scope_name(:env), do: "environment"
  defp scope_name(scope), do: Atom.to_string(scope)
end

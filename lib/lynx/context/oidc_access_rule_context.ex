# Copyright 2023 Clivern. All rights reserved.
# Use of this source code is governed by the MIT
# license that can be found in the LICENSE file.

defmodule Lynx.Context.OIDCAccessRuleContext do
  @moduledoc """
  OIDC Access Rule Context Module
  """

  import Ecto.Query

  alias Lynx.Repo
  alias Lynx.Model.OIDCAccessRule

  def new_rule(attrs \\ %{}) do
    %{
      name: attrs.name,
      claim_rules: attrs.claim_rules,
      provider_id: attrs.provider_id,
      environment_id: attrs.environment_id,
      is_active: Map.get(attrs, :is_active, true),
      uuid: Map.get(attrs, :uuid, Ecto.UUID.generate())
    }
  end

  def create_rule(attrs \\ %{}) do
    %OIDCAccessRule{}
    |> OIDCAccessRule.changeset(attrs)
    |> Repo.insert()
  end

  def get_rule_by_uuid(uuid) do
    from(r in OIDCAccessRule, where: r.uuid == ^uuid)
    |> limit(1)
    |> Repo.one()
  end

  def list_rules_by_environment(environment_id) do
    from(r in OIDCAccessRule,
      where: r.environment_id == ^environment_id,
      where: r.is_active == true,
      order_by: [asc: r.name]
    )
    |> Repo.all()
  end

  def list_rules_by_provider_and_environment(provider_id, environment_id) do
    from(r in OIDCAccessRule,
      where: r.provider_id == ^provider_id,
      where: r.environment_id == ^environment_id,
      where: r.is_active == true
    )
    |> Repo.all()
  end

  def list_rules_by_provider(provider_id) do
    from(r in OIDCAccessRule,
      where: r.provider_id == ^provider_id,
      order_by: [asc: r.name]
    )
    |> Repo.all()
  end

  def update_rule(rule, attrs) do
    rule
    |> OIDCAccessRule.changeset(attrs)
    |> Repo.update()
  end

  def delete_rule(rule), do: Repo.delete(rule)
end

# Copyright 2023 Clivern. All rights reserved.
# Use of this source code is governed by the MIT
# license that can be found in the LICENSE file.

defmodule Lynx.Context.OIDCProviderContext do
  @moduledoc """
  OIDC Provider Context Module
  """

  import Ecto.Query

  alias Lynx.Repo
  alias Lynx.Model.OIDCProvider

  def new_provider(attrs \\ %{}) do
    %{
      name: attrs.name,
      discovery_url: attrs.discovery_url,
      audience: Map.get(attrs, :audience),
      is_active: Map.get(attrs, :is_active, true),
      uuid: Map.get(attrs, :uuid, Ecto.UUID.generate())
    }
  end

  def create_provider(attrs \\ %{}) do
    %OIDCProvider{}
    |> OIDCProvider.changeset(attrs)
    |> Repo.insert()
  end

  def get_provider_by_id(id), do: Repo.get(OIDCProvider, id)

  def get_provider_by_uuid(uuid) do
    from(p in OIDCProvider, where: p.uuid == ^uuid)
    |> limit(1)
    |> Repo.one()
  end

  def get_provider_by_name(name) do
    from(p in OIDCProvider, where: p.name == ^name, where: p.is_active == true)
    |> limit(1)
    |> Repo.one()
  end

  def list_providers do
    from(p in OIDCProvider, order_by: [asc: p.name])
    |> Repo.all()
  end

  def update_provider(provider, attrs) do
    provider
    |> OIDCProvider.changeset(attrs)
    |> Repo.update()
  end

  def delete_provider(provider), do: Repo.delete(provider)
end

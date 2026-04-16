# Copyright 2023 Clivern. All rights reserved.
# Use of this source code is governed by the MIT
# license that can be found in the LICENSE file.

defmodule Lynx.Model.OIDCProvider do
  @moduledoc """
  OIDCProvider Model
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "oidc_providers" do
    field :uuid, Ecto.UUID
    field :name, :string
    field :discovery_url, :string
    field :audience, :string
    field :is_active, :boolean, default: true

    timestamps()
  end

  @doc false
  def changeset(provider, attrs) do
    provider
    |> cast(attrs, [:uuid, :name, :discovery_url, :audience, :is_active])
    |> validate_required([:uuid, :name, :discovery_url])
    |> unique_constraint(:name)
  end
end

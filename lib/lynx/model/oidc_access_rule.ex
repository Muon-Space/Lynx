# Copyright 2023 Clivern. All rights reserved.
# Use of this source code is governed by the MIT
# license that can be found in the LICENSE file.

defmodule Lynx.Model.OIDCAccessRule do
  @moduledoc """
  OIDCAccessRule Model
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "oidc_access_rules" do
    field :uuid, Ecto.UUID
    field :name, :string
    field :claim_rules, :string
    field :is_active, :boolean, default: true
    field :provider_id, :id
    field :environment_id, :id

    timestamps()
  end

  @doc false
  def changeset(rule, attrs) do
    rule
    |> cast(attrs, [:uuid, :name, :claim_rules, :is_active, :provider_id, :environment_id])
    |> validate_required([:uuid, :name, :claim_rules, :provider_id, :environment_id])
  end
end

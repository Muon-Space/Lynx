# Copyright 2023 Clivern. All rights reserved.
# Use of this source code is governed by the MIT
# license that can be found in the LICENSE file.

defmodule Lynx.Model.SCIMToken do
  @moduledoc """
  SCIMToken Model
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "scim_tokens" do
    field :uuid, Ecto.UUID
    field :token, :string
    field :description, :string
    field :is_active, :boolean, default: true
    field :last_used_at, :utc_datetime

    timestamps()
  end

  @doc false
  def changeset(scim_token, attrs) do
    scim_token
    |> cast(attrs, [
      :uuid,
      :token,
      :description,
      :is_active,
      :last_used_at
    ])
    |> validate_required([
      :uuid,
      :token
    ])
  end
end

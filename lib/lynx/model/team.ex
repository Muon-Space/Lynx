# Copyright 2023 Clivern. All rights reserved.
# Use of this source code is governed by the MIT
# license that can be found in the LICENSE file.

defmodule Lynx.Model.Team do
  @moduledoc """
  Team Model
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "teams" do
    field :uuid, Ecto.UUID
    field :name, :string
    field :slug, :string
    field :description, :string
    field :external_id, :string

    timestamps()
  end

  @doc false
  def changeset(state, attrs) do
    state
    |> cast(attrs, [
      :uuid,
      :name,
      :slug,
      :description,
      :external_id
    ])
    |> validate_required([
      :uuid,
      :name,
      :slug,
      :description
    ])
    |> unique_constraint(:slug)
  end
end

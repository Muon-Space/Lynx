# Copyright 2023 Clivern. All rights reserved.
# Use of this source code is governed by the MIT
# license that can be found in the LICENSE file.

defmodule Lynx.Model.State do
  @moduledoc """
  State Model
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "states" do
    field :uuid, Ecto.UUID
    field :name, :string
    field :value, :string
    field :sub_path, :string, default: ""
    field :environment_id, :id
    # Postgres-managed (STORED generated column). Skip on every SELECT —
    # it's a tsvector over the full state body, often megabytes.
    field :search_vector, :string, load_in_query: false, read_after_writes: false

    timestamps()
  end

  @doc false
  def changeset(state, attrs) do
    state
    |> cast(attrs, [
      :uuid,
      :name,
      :value,
      :sub_path,
      :environment_id
    ])
    |> validate_required([
      :uuid,
      :name,
      :value,
      :environment_id
    ])
  end
end

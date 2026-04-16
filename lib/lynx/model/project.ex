# Copyright 2023 Clivern. All rights reserved.
# Use of this source code is governed by the MIT
# license that can be found in the LICENSE file.

defmodule Lynx.Model.Project do
  @moduledoc """
  Project Model
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "projects" do
    field :uuid, Ecto.UUID
    field :name, :string
    field :slug, :string
    field :description, :string

    timestamps()
  end

  @doc false
  def changeset(project, attrs) do
    project
    |> cast(attrs, [
      :uuid,
      :name,
      :slug,
      :description
    ])
    |> validate_required([
      :uuid,
      :name,
      :slug,
      :description
    ])
  end
end

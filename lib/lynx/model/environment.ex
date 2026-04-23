# Copyright 2023 Clivern. All rights reserved.
# Use of this source code is governed by the MIT
# license that can be found in the LICENSE file.

defmodule Lynx.Model.Environment do
  @moduledoc """
  Environment Model
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "environments" do
    field :uuid, Ecto.UUID
    field :name, :string
    field :slug, :string
    field :username, :string
    field :secret, :string
    field :project_id, :id

    # Policy enforcement gates (issue #38). Both nullable so they can
    # inherit a global default from `Settings.PolicyGate`. nil = inherit;
    # true / false = explicit override.
    field :require_passing_plan, :boolean
    field :block_violating_apply, :boolean
    field :plan_max_age_seconds, :integer, default: 1800

    timestamps()
  end

  @doc false
  def changeset(state, attrs) do
    state
    |> cast(attrs, [
      :uuid,
      :name,
      :slug,
      :username,
      :secret,
      :project_id,
      :require_passing_plan,
      :block_violating_apply,
      :plan_max_age_seconds
    ])
    |> validate_required([
      :uuid,
      :name,
      :slug,
      :username,
      :secret,
      :project_id
    ])
    |> validate_number(:plan_max_age_seconds, greater_than: 0)
    |> unique_constraint(:slug,
      name: :environments_project_id_slug_index,
      message: "already exists in this project"
    )
  end
end

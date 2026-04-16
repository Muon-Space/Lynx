# Copyright 2023 Clivern. All rights reserved.
# Use of this source code is governed by the MIT
# license that can be found in the LICENSE file.

defmodule Lynx.Model.ProjectTeam do
  @moduledoc """
  ProjectTeam Model - join table for many-to-many project/team relationships
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "project_teams" do
    field :uuid, Ecto.UUID
    field :project_id, :id
    field :team_id, :id

    timestamps()
  end

  @doc false
  def changeset(project_team, attrs) do
    project_team
    |> cast(attrs, [:uuid, :project_id, :team_id])
    |> validate_required([:uuid, :project_id, :team_id])
    |> unique_constraint([:project_id, :team_id])
  end
end

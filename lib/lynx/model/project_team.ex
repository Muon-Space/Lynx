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
    field :role_id, :id
    field :expires_at, :utc_datetime
    # Nullable: NULL = project-wide grant; non-null = env-specific override.
    field :environment_id, :id

    timestamps()
  end

  @doc false
  def changeset(project_team, attrs) do
    project_team
    |> cast(attrs, [:uuid, :project_id, :team_id, :role_id, :expires_at, :environment_id])
    |> validate_required([:uuid, :project_id, :team_id, :role_id])
    |> unique_constraint([:project_id, :team_id, :environment_id],
      name: :project_teams_team_project_env_unique
    )
    |> unique_constraint([:project_id, :team_id],
      name: :project_teams_team_project_no_env_unique
    )
  end
end

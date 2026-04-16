# Copyright 2023 Clivern. All rights reserved.
# Use of this source code is governed by the MIT
# license that can be found in the LICENSE file.

defmodule Lynx.Repo.Migrations.CreateProjectTeams do
  use Ecto.Migration

  def up do
    # Create join table
    create table(:project_teams) do
      add :uuid, :uuid
      add :project_id, references(:projects, on_delete: :delete_all), null: false
      add :team_id, references(:teams, on_delete: :delete_all), null: false

      timestamps()
    end

    create index(:project_teams, [:project_id])
    create index(:project_teams, [:team_id])
    create unique_index(:project_teams, [:project_id, :team_id])

    # Migrate existing team_id relationships into the join table
    execute """
    INSERT INTO project_teams (uuid, project_id, team_id, inserted_at, updated_at)
    SELECT gen_random_uuid(), id, team_id, NOW(), NOW()
    FROM projects
    WHERE team_id IS NOT NULL
    """

    # Drop the old team_id column
    alter table(:projects) do
      remove :team_id
    end
  end

  def down do
    # Re-add team_id column
    alter table(:projects) do
      add :team_id, references(:teams, on_delete: :delete_all)
    end

    # Migrate first team back to team_id
    execute """
    UPDATE projects SET team_id = (
      SELECT team_id FROM project_teams
      WHERE project_teams.project_id = projects.id
      LIMIT 1
    )
    """

    drop table(:project_teams)
  end
end

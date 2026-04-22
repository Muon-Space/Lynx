defmodule Lynx.Repo.Migrations.AddEnvScopeToGrants do
  @moduledoc """
  Per-environment role overrides. Adds nullable `environment_id` to both
  grant tables:

    * `NULL` — project-wide grant. Applies to every env in the project.
      All existing rows get this implicitly via the absence of a backfill,
      preserving today's behavior.
    * Set    — env-specific override. `RoleContext.effective_permissions/3`
      uses env-specific grants when computing perms for that env, falling
      back to project-wide grants when no env-specific grants exist.

  The unique constraint widens from `(team_id, project_id)` to
  `(team_id, project_id, env_id)` so a team can hold both a project-wide
  grant and per-env overrides simultaneously.
  """
  use Ecto.Migration

  def change do
    alter table(:project_teams) do
      add :environment_id, references(:environments, on_delete: :delete_all),
        null: true
    end

    alter table(:user_projects) do
      add :environment_id, references(:environments, on_delete: :delete_all),
        null: true
    end

    # The original migrations created `unique_index(table, [a, b])` which
    # Ecto names `<table>_a_b_index`. Drop both possible orderings so the
    # migration is idempotent across previously-run dev/test DBs.
    drop_if_exists unique_index(:project_teams, [:project_id, :team_id])
    drop_if_exists unique_index(:project_teams, [:team_id, :project_id])

    drop_if_exists unique_index(:user_projects, [:user_id, :project_id])
    drop_if_exists unique_index(:user_projects, [:project_id, :user_id])

    # Postgres treats NULL as distinct in unique indexes, so the same team
    # can have a project-wide row (env_id IS NULL) and N env-specific rows
    # without colliding. Within env_id IS NULL the constraint still prevents
    # duplicate project-wide grants — we add a partial index for that case.
    create unique_index(:project_teams, [:team_id, :project_id, :environment_id],
             where: "environment_id IS NOT NULL",
             name: :project_teams_team_project_env_unique
           )

    create unique_index(:project_teams, [:team_id, :project_id],
             where: "environment_id IS NULL",
             name: :project_teams_team_project_no_env_unique
           )

    create unique_index(:user_projects, [:user_id, :project_id, :environment_id],
             where: "environment_id IS NOT NULL",
             name: :user_projects_user_project_env_unique
           )

    create unique_index(:user_projects, [:user_id, :project_id],
             where: "environment_id IS NULL",
             name: :user_projects_user_project_no_env_unique
           )

    create index(:project_teams, [:environment_id])
    create index(:user_projects, [:environment_id])
  end
end

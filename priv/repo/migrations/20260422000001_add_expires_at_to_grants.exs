defmodule Lynx.Repo.Migrations.AddExpiresAtToGrants do
  @moduledoc """
  Time-bounded role grants. Both `project_teams` and `user_projects` get a
  nullable `expires_at` column:

    * `NULL` — permanent grant (today's behavior, what every existing row
      gets via the absence of a backfill).
    * Non-null — `Lynx.Context.RoleContext.effective_permissions/2` filters
      the row out at lookup time once `now() > expires_at`. A periodic
      sweeper worker also deletes expired rows so the table doesn't bloat.
  """
  use Ecto.Migration

  def change do
    alter table(:project_teams) do
      add :expires_at, :utc_datetime, null: true
    end

    alter table(:user_projects) do
      add :expires_at, :utc_datetime, null: true
    end

    create index(:project_teams, [:expires_at])
    create index(:user_projects, [:expires_at])
  end
end

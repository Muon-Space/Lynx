defmodule Lynx.Repo.Migrations.AddRoleToProjectTeams do
  use Ecto.Migration

  def up do
    alter table(:project_teams) do
      add :role_id, references(:roles, on_delete: :restrict), null: true
    end

    create index(:project_teams, [:role_id])

    flush()

    # Backfill existing rows to the 'applier' role to preserve current full-access behavior.
    execute """
    UPDATE project_teams SET role_id = (SELECT id FROM roles WHERE name = 'applier')
    WHERE role_id IS NULL
    """

    execute "ALTER TABLE project_teams ALTER COLUMN role_id SET NOT NULL"
  end

  def down do
    alter table(:project_teams) do
      remove :role_id
    end
  end
end

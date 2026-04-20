defmodule Lynx.Repo.Migrations.AddRoleToOidcAccessRules do
  use Ecto.Migration

  def up do
    alter table(:oidc_access_rules) do
      add :role_id, references(:roles, on_delete: :restrict), null: true
    end

    create index(:oidc_access_rules, [:role_id])

    flush()

    execute """
    UPDATE oidc_access_rules SET role_id = (SELECT id FROM roles WHERE name = 'applier')
    WHERE role_id IS NULL
    """

    execute "ALTER TABLE oidc_access_rules ALTER COLUMN role_id SET NOT NULL"
  end

  def down do
    alter table(:oidc_access_rules) do
      remove :role_id
    end
  end
end

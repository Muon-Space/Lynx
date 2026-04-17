defmodule Lynx.Repo.Migrations.CreateWorkspaces do
  use Ecto.Migration

  def change do
    create table(:workspaces) do
      add :uuid, :uuid, null: false
      add :name, :string, null: false
      add :slug, :string, null: false
      add :description, :string

      timestamps()
    end

    create unique_index(:workspaces, [:slug])
    create unique_index(:workspaces, [:uuid])

    alter table(:projects) do
      add :workspace_id, references(:workspaces, on_delete: :nothing), null: true
    end

    create index(:projects, [:workspace_id])

    flush()

    execute """
    INSERT INTO workspaces (uuid, name, slug, description, inserted_at, updated_at)
    VALUES (gen_random_uuid(), 'Default', 'default', 'Default workspace', now(), now())
    """, ""

    execute """
    UPDATE projects SET workspace_id = (SELECT id FROM workspaces WHERE slug = 'default')
    WHERE workspace_id IS NULL
    """, ""
  end
end

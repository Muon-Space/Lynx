defmodule Lynx.Repo.Migrations.CreateRoles do
  use Ecto.Migration

  def change do
    create table(:roles) do
      add :uuid, :uuid, null: false
      add :name, :string, null: false
      add :description, :string
      add :is_system, :boolean, null: false, default: false

      timestamps()
    end

    create unique_index(:roles, [:name])
    create unique_index(:roles, [:uuid])

    flush()

    execute """
    INSERT INTO roles (uuid, name, description, is_system, inserted_at, updated_at) VALUES
      (gen_random_uuid(), 'planner', 'Read terraform state', true, now(), now()),
      (gen_random_uuid(), 'applier', 'Read and write terraform state, lock and unlock', true, now(), now()),
      (gen_random_uuid(), 'admin',   'Full project access including settings and access management', true, now(), now())
    """, ""
  end
end

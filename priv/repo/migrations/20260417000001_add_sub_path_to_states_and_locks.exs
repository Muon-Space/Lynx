defmodule Lynx.Repo.Migrations.AddSubPathToStatesAndLocks do
  use Ecto.Migration

  def change do
    alter table(:states) do
      add :sub_path, :string, null: false, default: ""
    end

    alter table(:locks) do
      add :sub_path, :string, null: false, default: ""
    end

    create index(:states, [:environment_id, :sub_path])
    create index(:locks, [:environment_id, :sub_path, :is_active])
    create_if_not_exists unique_index(:projects, [:slug])
  end
end

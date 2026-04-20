defmodule Lynx.Repo.Migrations.CreateUserProjects do
  use Ecto.Migration

  def change do
    create table(:user_projects) do
      add :uuid, :uuid, null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :project_id, references(:projects, on_delete: :delete_all), null: false
      add :role_id, references(:roles, on_delete: :restrict), null: false

      timestamps()
    end

    create index(:user_projects, [:user_id])
    create index(:user_projects, [:project_id])
    create index(:user_projects, [:role_id])
    create unique_index(:user_projects, [:user_id, :project_id])
    create unique_index(:user_projects, [:uuid])
  end
end

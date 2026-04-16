defmodule Lynx.Repo.Migrations.AddUniqueSlugIndexes do
  use Ecto.Migration

  def change do
    create_if_not_exists unique_index(:teams, [:slug])
    create_if_not_exists unique_index(:environments, [:project_id, :slug])
  end
end

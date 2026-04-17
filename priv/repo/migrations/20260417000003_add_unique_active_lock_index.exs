defmodule Lynx.Repo.Migrations.AddUniqueActiveLockIndex do
  use Ecto.Migration

  def change do
    create unique_index(:locks, [:environment_id, :sub_path],
      where: "is_active = true",
      name: :locks_unique_active_per_path
    )
  end
end

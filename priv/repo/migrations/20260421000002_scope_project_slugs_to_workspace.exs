defmodule Lynx.Repo.Migrations.ScopeProjectSlugsToWorkspace do
  use Ecto.Migration

  def change do
    drop_if_exists unique_index(:projects, [:slug])
    create unique_index(:projects, [:workspace_id, :slug])
  end
end

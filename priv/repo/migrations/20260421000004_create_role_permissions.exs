defmodule Lynx.Repo.Migrations.CreateRolePermissions do
  use Ecto.Migration

  def change do
    create table(:role_permissions) do
      add :role_id, references(:roles, on_delete: :delete_all), null: false
      add :permission, :string, null: false

      timestamps()
    end

    create index(:role_permissions, [:role_id])
    create unique_index(:role_permissions, [:role_id, :permission])

    flush()

    # Seed default role->permission bundles. Each role inherits from the previous tier.
    seed_role("planner", ~w(state:read))

    seed_role(
      "applier",
      ~w(state:read state:write state:lock state:unlock snapshot:create)
    )

    seed_role(
      "admin",
      ~w(state:read state:write state:lock state:unlock snapshot:create snapshot:restore env:manage project:manage access:manage oidc_rule:manage)
    )
  end

  defp seed_role(name, permissions) do
    values =
      permissions
      |> Enum.map_join(",\n", fn perm ->
        "((SELECT id FROM roles WHERE name = '#{name}'), '#{perm}', now(), now())"
      end)

    execute """
    INSERT INTO role_permissions (role_id, permission, inserted_at, updated_at) VALUES
    #{values}
    """
  end
end

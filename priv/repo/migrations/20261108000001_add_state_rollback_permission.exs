defmodule Lynx.Repo.Migrations.AddStateRollbackPermission do
  @moduledoc """
  Adds the `state:rollback` permission (roll a state back to an earlier
  stored version) to the `applier` and `admin` system roles. It is a
  separate permission rather than part of `state:write` so a CI
  credential that can push state can't also rewind it.
  """

  use Ecto.Migration

  def up do
    for role <- ~w(applier admin) do
      execute """
      INSERT INTO role_permissions (role_id, permission, inserted_at, updated_at)
      SELECT id, 'state:rollback', now(), now() FROM roles WHERE name = '#{role}'
      ON CONFLICT (role_id, permission) DO NOTHING
      """
    end
  end

  def down do
    execute "DELETE FROM role_permissions WHERE permission = 'state:rollback'"
  end
end

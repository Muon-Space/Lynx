defmodule Lynx.Repo.Migrations.AddForceUnlockPermission do
  use Ecto.Migration

  @moduledoc """
  Splits `state:force_unlock` out from `state:unlock`.

  Before this migration the same permission gated two semantically different
  operations: Terraform's routine post-apply unlock (which planner needs to
  run `plan` at all) and the admin force-unlock button (which clears another
  user's lock and is destructive). The destructive variant is now its own
  permission, granted only to admin.
  """

  def up do
    execute """
    INSERT INTO role_permissions (role_id, permission, inserted_at, updated_at)
    SELECT id, 'state:force_unlock', now(), now()
    FROM roles
    WHERE name = 'admin'
    ON CONFLICT (role_id, permission) DO NOTHING
    """
  end

  def down do
    execute """
    DELETE FROM role_permissions
    WHERE permission = 'state:force_unlock'
    """
  end
end

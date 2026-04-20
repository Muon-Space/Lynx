defmodule Lynx.Repo.Migrations.GrantLockToPlanner do
  @moduledoc """
  Terraform `plan` always tries to acquire a state lock by default
  (`-lock=false` is opt-in). Without `state:lock`/`state:unlock` the planner
  role can't run a plan against a Lynx-backed module, defeating the role's
  whole purpose.

  Applier still differs from planner via `state:write` (mutating state) and
  `snapshot:create`. Admin still owns the management permissions.

  Idempotent: re-running this migration has no effect because of the
  `(role_id, permission)` unique index plus `ON CONFLICT DO NOTHING`.
  """

  use Ecto.Migration

  def up do
    execute """
    INSERT INTO role_permissions (role_id, permission, inserted_at, updated_at)
    SELECT r.id, p.permission, now(), now()
    FROM roles r
    CROSS JOIN (VALUES ('state:lock'), ('state:unlock')) AS p(permission)
    WHERE r.name = 'planner'
    ON CONFLICT (role_id, permission) DO NOTHING
    """
  end

  def down do
    execute """
    DELETE FROM role_permissions
    WHERE role_id = (SELECT id FROM roles WHERE name = 'planner')
      AND permission IN ('state:lock', 'state:unlock')
    """
  end
end

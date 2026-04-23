defmodule Lynx.Repo.Migrations.AddPolicyPermissions do
  @moduledoc """
  Two new permissions for governance separation (issue #38 follow-up):

    * `policy:manage` — CRUD policies at project + env scopes. Lets a
      "compliance" role own policies without inheriting `project:manage`
      (which also grants project rename/delete).
    * `policy_gate:manage` — toggle the per-env plan-gate and block-on-
      violation overrides. Same separation rationale: enforcement
      authority without full env:manage.

  Seeded into `admin` only by default — admins keep their full bundle.
  Operators can attach the perms to custom roles for delegation.
  """

  use Ecto.Migration

  def change do
    for perm <- ["policy:manage", "policy_gate:manage"] do
      execute """
      INSERT INTO role_permissions (role_id, permission, inserted_at, updated_at)
      SELECT id, '#{perm}', now(), now() FROM roles WHERE name = 'admin'
      ON CONFLICT (role_id, permission) DO NOTHING
      """
    end
  end
end

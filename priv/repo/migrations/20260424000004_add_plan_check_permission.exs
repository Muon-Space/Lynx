defmodule Lynx.Repo.Migrations.AddPlanCheckPermission do
  @moduledoc """
  Adds the `plan:check` permission to the three default system roles
  (issue #38). Planner already runs `terraform plan` in CI, so granting
  plan-check uniformly across planner/applier/admin keeps the existing
  CI permission model intact — no role uplift needed for plan upload.
  """

  use Ecto.Migration

  def change do
    for role <- ~w(planner applier admin) do
      execute """
      INSERT INTO role_permissions (role_id, permission, inserted_at, updated_at)
      SELECT id, 'plan:check', now(), now() FROM roles WHERE name = '#{role}'
      ON CONFLICT (role_id, permission) DO NOTHING
      """
    end
  end
end

defmodule Lynx.Repo.Migrations.AddApplyGateToEnvironments do
  @moduledoc """
  Per-env opt-in apply gate (issue #38). When `require_passing_plan` is
  true, a state-write must be preceded by a passing plan-check from the
  same actor within `plan_max_age_seconds`. Default off so existing envs
  keep working without any operator action.
  """

  use Ecto.Migration

  def change do
    alter table(:environments) do
      add :require_passing_plan, :boolean, null: false, default: false
      add :plan_max_age_seconds, :integer, null: false, default: 1800
    end
  end
end

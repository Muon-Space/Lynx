defmodule Lynx.Repo.Migrations.PolicyGateGlobalDefaultsAndBlockViolatingApply do
  @moduledoc """
  Two-axis policy enforcement (issue #38 follow-up):

    1. **Plan gate** (existing) — apply must be preceded by a passing
       `POST /tf/.../plan` upload from the same actor.
    2. **Block violating apply** (new) — at state-write time, evaluate
       the new state body against effective policies; reject if any
       policy produces a `deny[msg]`. Independent of plan-check uploads.

  Both knobs are per-env booleans that may be NULL (= inherit a global
  default stored in `configs`). Existing envs with explicit `false` keep
  their current behaviour; envs that haven't opted in switch to inherit
  mode (NULL). The data backfill below preserves the current effective
  value for any env that had `require_passing_plan = true`.
  """

  use Ecto.Migration

  def up do
    alter table(:environments) do
      modify :require_passing_plan, :boolean, null: true, from: {:boolean, null: false}
      add :block_violating_apply, :boolean, null: true
    end

    # Existing rows with the old default (false) become NULL = "inherit".
    # Anyone who explicitly toggled it on stays at true.
    execute("UPDATE environments SET require_passing_plan = NULL WHERE require_passing_plan = false")
  end

  def down do
    execute("UPDATE environments SET require_passing_plan = false WHERE require_passing_plan IS NULL")

    alter table(:environments) do
      remove :block_violating_apply
      modify :require_passing_plan, :boolean, null: false, default: false, from: {:boolean, null: true}
    end
  end
end

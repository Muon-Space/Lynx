defmodule Lynx.Repo.Migrations.DropGateFieldDefaults do
  @moduledoc """
  `require_passing_plan` was originally `boolean default false`. Migration
  20260424000007 made it nullable (so NULL = "inherit global default")
  but left the column default at `false`, which meant freshly-created
  envs still got `false` instead of NULL — and `false` reads as
  "explicit override: off" in `list_envs_with_gate_overrides/0`,
  cluttering the override list with envs the operator never touched.

  Drop the column default so new inserts go to NULL. Existing rows
  with explicit `true` / `false` are preserved; existing rows with
  `false` from the old default are NOT migrated to NULL because we
  can't distinguish "user explicitly set false" from "factory default
  false". Operators wanting the latter to become "inherit" can just
  toggle the per-env override to "inherit global default" in the UI.
  """

  use Ecto.Migration

  def up do
    execute("ALTER TABLE environments ALTER COLUMN require_passing_plan DROP DEFAULT")
  end

  def down do
    execute("ALTER TABLE environments ALTER COLUMN require_passing_plan SET DEFAULT false")
  end
end

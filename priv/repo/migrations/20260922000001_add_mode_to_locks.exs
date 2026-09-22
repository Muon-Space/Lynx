defmodule Lynx.Repo.Migrations.AddModeToLocks do
  @moduledoc """
  Readers-writer locking for Terraform state.

  `terraform plan` only reads state, so its lock is recorded as `shared`
  and any number of shared locks may be active on the same path at once.
  Every other operation (apply, import, state mv, the UI force-lock) is
  `exclusive`, and only one exclusive lock may be active per path. The
  partial unique index that used to cover every active row now covers
  exclusive rows only; that is what lets concurrent plans coexist.

  Existing rows predate the column and were all taken under exclusive
  semantics, so the default backfills them as `exclusive`.
  """
  use Ecto.Migration

  def up do
    alter table(:locks) do
      add :mode, :string, null: false, default: "exclusive"
    end

    drop_if_exists index(:locks, [:environment_id, :sub_path],
                     name: :locks_unique_active_per_path
                   )

    # Shared rows are looked up by (env, path, active) on every lock and
    # state push; the existing locks_environment_id_sub_path_is_active_index
    # already covers that, so no extra index is needed here.
    create unique_index(:locks, [:environment_id, :sub_path],
             where: "is_active = true AND mode = 'exclusive'",
             name: :locks_unique_active_exclusive_per_path
           )
  end

  def down do
    drop_if_exists index(:locks, [:environment_id, :sub_path],
                     name: :locks_unique_active_exclusive_per_path
                   )

    # Any active shared rows would violate the old index; release them
    # rather than fail the rollback. They never blocked anything.
    execute("UPDATE locks SET is_active = false WHERE is_active = true AND mode = 'shared'")

    create unique_index(:locks, [:environment_id, :sub_path],
             where: "is_active = true",
             name: :locks_unique_active_per_path
           )

    alter table(:locks) do
      remove :mode
    end
  end
end

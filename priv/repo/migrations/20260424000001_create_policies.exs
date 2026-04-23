defmodule Lynx.Repo.Migrations.CreatePolicies do
  @moduledoc """
  Plan-policy gates (issue #38). A `policy` is a chunk of OPA Rego attached
  to either a project (every env under it) or a single environment. The
  bundle endpoint walks this table to assemble the tarball OPA polls.

  Exactly one of `project_id` / `environment_id` must be set — enforced via
  a CHECK constraint so a NULL/NULL or both/both row can't slip in.
  """

  use Ecto.Migration

  def change do
    create table(:policies) do
      add :uuid, :uuid, null: false
      add :name, :string, null: false
      add :description, :string, null: false, default: ""
      add :rego_source, :text, null: false
      add :enabled, :boolean, null: false, default: true

      add :project_id,
          references(:projects, on_delete: :delete_all),
          null: true

      add :environment_id,
          references(:environments, on_delete: :delete_all),
          null: true

      timestamps()
    end

    create unique_index(:policies, [:uuid])
    create index(:policies, [:project_id])
    create index(:policies, [:environment_id])

    # Hard guard at the DB so the schema-level "exactly one of" rule is
    # enforced even if a future caller bypasses the changeset.
    create constraint(:policies, :exactly_one_scope,
             check:
               "(project_id IS NOT NULL AND environment_id IS NULL) OR (project_id IS NULL AND environment_id IS NOT NULL)"
           )
  end
end

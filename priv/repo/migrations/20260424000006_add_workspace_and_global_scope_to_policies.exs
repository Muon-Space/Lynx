defmodule Lynx.Repo.Migrations.AddWorkspaceAndGlobalScopeToPolicies do
  @moduledoc """
  Expand policy scope so a single policy can be attached at one of four
  levels (issue #38 follow-up): global (no scope columns set), workspace,
  project, or environment. Effective set for an env unions all four.

  Replaces the original `exactly_one_scope` CHECK with a
  `at_most_one_scope` CHECK that allows zero scopes (= global) or
  exactly one of (workspace, project, environment).
  """

  use Ecto.Migration

  def up do
    alter table(:policies) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: true
    end

    create index(:policies, [:workspace_id])

    drop_if_exists constraint(:policies, :exactly_one_scope)

    create constraint(:policies, :at_most_one_scope,
             check: """
             (
               (CASE WHEN workspace_id IS NULL THEN 0 ELSE 1 END) +
               (CASE WHEN project_id IS NULL THEN 0 ELSE 1 END) +
               (CASE WHEN environment_id IS NULL THEN 0 ELSE 1 END)
             ) <= 1
             """
           )
  end

  def down do
    drop_if_exists constraint(:policies, :at_most_one_scope)

    create constraint(:policies, :exactly_one_scope,
             check:
               "(project_id IS NOT NULL AND environment_id IS NULL) OR (project_id IS NULL AND environment_id IS NOT NULL)"
           )

    drop index(:policies, [:workspace_id])

    alter table(:policies) do
      remove :workspace_id
    end
  end
end

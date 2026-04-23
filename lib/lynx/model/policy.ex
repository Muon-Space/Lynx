defmodule Lynx.Model.Policy do
  @moduledoc """
  OPA Rego policy attached at one of four scopes:

    * **Global** — no scope IDs set; applies to every env.
    * **Workspace** — `workspace_id` set; applies to every env in the workspace.
    * **Project** — `project_id` set; applies to every env in the project.
    * **Environment** — `environment_id` set; applies to that env only.

  Exactly one of `workspace_id`/`project_id`/`environment_id` may be set,
  enforced at the DB layer via the `at_most_one_scope` CHECK constraint.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "policies" do
    field :uuid, Ecto.UUID
    field :name, :string
    field :description, :string, default: ""
    field :rego_source, :string
    field :enabled, :boolean, default: true

    field :workspace_id, :id
    field :project_id, :id
    field :environment_id, :id

    timestamps()
  end

  @doc false
  def changeset(policy, attrs) do
    policy
    |> cast(attrs, [
      :uuid,
      :name,
      :description,
      :rego_source,
      :enabled,
      :workspace_id,
      :project_id,
      :environment_id
    ])
    |> validate_required([:uuid, :name, :rego_source])
    |> validate_length(:name, min: 1, max: 100)
    |> validate_scope_exclusivity()
    |> check_constraint(:workspace_id,
      name: :at_most_one_scope,
      message: "at most one of workspace, project, or environment can be set"
    )
  end

  defp validate_scope_exclusivity(changeset) do
    set =
      [:workspace_id, :project_id, :environment_id]
      |> Enum.count(&(get_field(changeset, &1) != nil))

    if set > 1 do
      add_error(
        changeset,
        :environment_id,
        "at most one of workspace_id / project_id / environment_id can be set"
      )
    else
      changeset
    end
  end

  @doc """
  Derive the policy's scope tag from its FK columns. Useful for renderers
  that want to badge a policy as "global", "workspace", "project", or "env"
  without re-implementing the same conditional everywhere.
  """
  def scope(%__MODULE__{environment_id: id}) when not is_nil(id), do: :env
  def scope(%__MODULE__{project_id: id}) when not is_nil(id), do: :project
  def scope(%__MODULE__{workspace_id: id}) when not is_nil(id), do: :workspace
  def scope(_), do: :global
end

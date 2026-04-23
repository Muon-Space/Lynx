defmodule Lynx.Model.Policy do
  @moduledoc """
  OPA Rego policy attached to either a project or an environment.
  Exactly one of `project_id` / `environment_id` is set.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "policies" do
    field :uuid, Ecto.UUID
    field :name, :string
    field :description, :string, default: ""
    field :rego_source, :string
    field :enabled, :boolean, default: true

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
      :project_id,
      :environment_id
    ])
    |> validate_required([:uuid, :name, :rego_source])
    |> validate_length(:name, min: 1, max: 100)
    |> validate_scope_exclusivity()
    |> check_constraint(:project_id,
      name: :exactly_one_scope,
      message: "must be attached to exactly one of project or environment"
    )
  end

  defp validate_scope_exclusivity(changeset) do
    project_id = get_field(changeset, :project_id)
    env_id = get_field(changeset, :environment_id)

    cond do
      is_nil(project_id) and is_nil(env_id) ->
        add_error(changeset, :project_id, "must be attached to a project or environment")

      not is_nil(project_id) and not is_nil(env_id) ->
        add_error(changeset, :environment_id, "cannot be set when project_id is set")

      true ->
        changeset
    end
  end
end

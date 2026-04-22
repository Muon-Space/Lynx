defmodule Lynx.Model.UserProject do
  @moduledoc """
  UserProject Model — direct (non-team) role grant from a user to a project.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "user_projects" do
    field :uuid, Ecto.UUID
    field :user_id, :id
    field :project_id, :id
    field :role_id, :id
    field :expires_at, :utc_datetime
    # Nullable: NULL = project-wide grant; non-null = env-specific override.
    field :environment_id, :id

    timestamps()
  end

  @doc false
  def changeset(user_project, attrs) do
    user_project
    |> cast(attrs, [:uuid, :user_id, :project_id, :role_id, :expires_at, :environment_id])
    |> validate_required([:uuid, :user_id, :project_id, :role_id])
    |> unique_constraint([:user_id, :project_id, :environment_id],
      name: :user_projects_user_project_env_unique
    )
    |> unique_constraint([:user_id, :project_id],
      name: :user_projects_user_project_no_env_unique
    )
    |> unique_constraint(:uuid)
  end
end

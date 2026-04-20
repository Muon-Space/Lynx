defmodule Lynx.Model.Role do
  @moduledoc """
  Role Model — a named bundle of permissions.

  System roles (planner, applier, admin) are seeded by migration
  `20260421000003_create_roles.exs` and have `is_system: true`. Custom roles
  may be added in the future and behave identically.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "roles" do
    field :uuid, Ecto.UUID
    field :name, :string
    field :description, :string
    field :is_system, :boolean, default: false

    timestamps()
  end

  @doc false
  def changeset(role, attrs) do
    role
    |> cast(attrs, [:uuid, :name, :description, :is_system])
    |> validate_required([:uuid, :name])
    |> validate_length(:name, min: 1, max: 60)
    |> unique_constraint(:name)
    |> unique_constraint(:uuid)
  end
end

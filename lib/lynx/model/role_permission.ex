defmodule Lynx.Model.RolePermission do
  @moduledoc """
  RolePermission Model — join table mapping a role to a permission string.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "role_permissions" do
    field :role_id, :id
    field :permission, :string

    timestamps()
  end

  @doc false
  def changeset(role_permission, attrs) do
    role_permission
    |> cast(attrs, [:role_id, :permission])
    |> validate_required([:role_id, :permission])
    |> unique_constraint([:role_id, :permission])
  end
end

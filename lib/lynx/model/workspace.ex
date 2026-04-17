defmodule Lynx.Model.Workspace do
  use Ecto.Schema
  import Ecto.Changeset

  schema "workspaces" do
    field :uuid, Ecto.UUID
    field :name, :string
    field :slug, :string
    field :description, :string

    timestamps()
  end

  def changeset(workspace, attrs) do
    workspace
    |> cast(attrs, [:uuid, :name, :slug, :description])
    |> validate_required([:uuid, :name, :slug])
    |> unique_constraint(:slug)
  end
end

defmodule Lynx.Model.OPABundleToken do
  @moduledoc """
  Long-lived service token presented by an external OPA instance polling
  Lynx's bundle endpoint. Stored plaintext to match the `scim_tokens`
  pattern; if/when SCIM moves to hashed storage this should follow.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "opa_bundle_tokens" do
    field :uuid, Ecto.UUID
    field :name, :string
    field :token, :string
    field :is_active, :boolean, default: true
    field :last_used_at, :utc_datetime

    timestamps()
  end

  @doc false
  def changeset(record, attrs) do
    record
    |> cast(attrs, [:uuid, :name, :token, :is_active, :last_used_at])
    |> validate_required([:uuid, :name, :token])
    |> validate_length(:name, min: 1, max: 100)
    |> unique_constraint(:token)
  end
end

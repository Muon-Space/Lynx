defmodule Lynx.Model.OPABundleToken do
  @moduledoc """
  Long-lived service token presented by an external OPA instance polling
  Lynx's bundle endpoint.

  `token` is a virtual field — the plaintext is accepted on input,
  hashed via `Lynx.Service.TokenHash` in the changeset, and only the
  hash + prefix are persisted. The virtual stays populated on the
  in-memory struct after `generate_token/1` so callers can surface
  the plaintext to the operator once.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Lynx.Service.TokenHash

  schema "opa_bundle_tokens" do
    field :uuid, Ecto.UUID
    field :name, :string
    field :token, :string, virtual: true
    field :token_hash, :string
    field :token_prefix, :string
    field :is_active, :boolean, default: true
    field :last_used_at, :utc_datetime

    timestamps()
  end

  @doc false
  def changeset(record, attrs) do
    record
    |> cast(attrs, [:uuid, :name, :token, :token_hash, :token_prefix, :is_active, :last_used_at])
    |> derive_token_hash()
    |> validate_required([:uuid, :name, :token_hash])
    |> validate_length(:name, min: 1, max: 100)
    |> unique_constraint(:token_hash)
  end

  defp derive_token_hash(changeset) do
    case get_change(changeset, :token) do
      nil ->
        changeset

      "" ->
        changeset

      plaintext when is_binary(plaintext) ->
        changeset
        |> put_change(:token_hash, TokenHash.hash(plaintext))
        |> put_change(:token_prefix, TokenHash.prefix(plaintext))
    end
  end
end

# Copyright 2023 Clivern. All rights reserved.
# Use of this source code is governed by the MIT
# license that can be found in the LICENSE file.

defmodule Lynx.Model.SCIMToken do
  @moduledoc """
  SCIM Token Model.

  `token` is a virtual field — the plaintext is accepted on input,
  hashed via `Lynx.Service.TokenHash` in the changeset, and only the
  hash + prefix are persisted. The virtual stays populated on the
  in-memory struct after `generate_token/1` so callers can surface
  the plaintext to the operator once.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Lynx.Service.TokenHash

  schema "scim_tokens" do
    field :uuid, Ecto.UUID
    field :token, :string, virtual: true
    field :token_hash, :string
    field :token_prefix, :string
    field :description, :string
    field :is_active, :boolean, default: true
    field :last_used_at, :utc_datetime

    timestamps()
  end

  @doc false
  def changeset(scim_token, attrs) do
    scim_token
    |> cast(attrs, [
      :uuid,
      :token,
      :token_hash,
      :token_prefix,
      :description,
      :is_active,
      :last_used_at
    ])
    |> derive_token_hash()
    |> validate_required([
      :uuid,
      :token_hash
    ])
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

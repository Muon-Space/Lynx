# Copyright 2023 Clivern. All rights reserved.
# Use of this source code is governed by the MIT
# license that can be found in the LICENSE file.

defmodule Lynx.Model.User do
  @moduledoc """
  User Model.

  `api_key` is a virtual field — the plaintext is accepted on input,
  hashed via `Lynx.Service.TokenHash` in the changeset, and only the
  hash + prefix are persisted. The virtual stays populated on the
  in-memory struct after a successful insert/update so callers can
  return the plaintext to the user once (mint-once UX).

  Identity providers (local password, SCIM, SAML, OIDC) live in the
  `user_identities` table — see `Lynx.Model.UserIdentity`. A single
  `users` row can be linked to multiple IdPs.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Lynx.Service.TokenHash

  schema "users" do
    field :uuid, Ecto.UUID
    field :email, :string
    field :name, :string
    field :password_hash, :string
    field :verified, :boolean, default: false
    field :last_seen, :utc_datetime
    field :role, :string
    field :api_key, :string, virtual: true
    field :api_key_hash, :string
    field :api_key_prefix, :string
    field :is_active, :boolean, default: true

    timestamps()
  end

  @doc false
  def changeset(user, attrs) do
    user
    |> cast(attrs, [
      :uuid,
      :name,
      :email,
      :password_hash,
      :verified,
      :last_seen,
      :role,
      :api_key,
      :api_key_hash,
      :api_key_prefix,
      :is_active
    ])
    |> derive_api_key_hash()
    |> validate_required([
      :uuid,
      :name,
      :email,
      :password_hash,
      :verified,
      :last_seen,
      :role,
      :api_key_hash
    ])
    |> validate_length(:name, min: 3, max: 60)
    |> validate_length(:email, min: 3, max: 60)
    |> validate_length(:role, min: 3, max: 60)
    |> validate_length(:password_hash, min: 3, max: 300)
    |> unique_constraint(:email, name: :users_email_unique_index)
  end

  # When a plaintext `:api_key` is provided, derive the hash + prefix.
  # Both are stored; the virtual stays on the struct so the caller can
  # surface the plaintext to the user (mint-once flow).
  defp derive_api_key_hash(changeset) do
    case get_change(changeset, :api_key) do
      nil ->
        changeset

      "" ->
        changeset

      plaintext when is_binary(plaintext) ->
        changeset
        |> put_change(:api_key_hash, TokenHash.hash(plaintext))
        |> put_change(:api_key_prefix, TokenHash.prefix(plaintext))
    end
  end
end

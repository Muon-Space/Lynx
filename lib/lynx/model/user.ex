# Copyright 2023 Clivern. All rights reserved.
# Use of this source code is governed by the MIT
# license that can be found in the LICENSE file.

defmodule Lynx.Model.User do
  @moduledoc """
  User Model
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "users" do
    field :uuid, Ecto.UUID
    field :email, :string
    field :name, :string
    field :password_hash, :string
    field :verified, :boolean, default: false
    field :last_seen, :utc_datetime
    field :role, :string
    field :api_key, :string
    field :auth_provider, :string, default: "local"
    field :external_id, :string
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
      :auth_provider,
      :external_id,
      :is_active
    ])
    |> validate_required([
      :uuid,
      :name,
      :email,
      :verified,
      :last_seen,
      :role,
      :api_key
    ])
    |> validate_password_for_local_users()
    |> validate_length(:name, min: 3, max: 60)
    |> validate_length(:email, min: 3, max: 60)
    |> validate_length(:role, min: 3, max: 60)
    |> validate_length(:api_key, min: 3, max: 60)
    |> validate_length(:password_hash, min: 3, max: 300)
    |> validate_inclusion(:auth_provider, ["local", "oidc", "saml", "scim"])
  end

  defp validate_password_for_local_users(changeset) do
    provider = get_field(changeset, :auth_provider) || "local"

    if provider == "local" do
      validate_required(changeset, [:password_hash])
    else
      changeset
    end
  end
end

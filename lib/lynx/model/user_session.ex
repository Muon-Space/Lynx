# Copyright 2023 Clivern. All rights reserved.
# Use of this source code is governed by the MIT
# license that can be found in the LICENSE file.

defmodule Lynx.Model.UserSession do
  @moduledoc """
  UserSession Model
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "users_session" do
    field :value, :string
    field :expire_at, :utc_datetime
    field :user_id, :id
    field :auth_method, :string, default: "password"
    field :idp_session_id, :string

    timestamps()
  end

  @doc false
  def changeset(user_meta, attrs) do
    user_meta
    |> cast(attrs, [
      :value,
      :expire_at,
      :user_id,
      :auth_method,
      :idp_session_id
    ])
    |> validate_required([
      :value,
      :expire_at,
      :user_id
    ])
    |> validate_inclusion(:auth_method, ["password", "oidc", "saml"])
  end
end

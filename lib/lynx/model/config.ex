# Copyright 2023 Clivern. All rights reserved.
# Use of this source code is governed by the MIT
# license that can be found in the LICENSE file.

defmodule Lynx.Model.Config do
  @moduledoc """
  Config Model
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "configs" do
    field :uuid, Ecto.UUID
    field :name, :string
    field :value, :string

    timestamps()
  end

  @doc false
  def changeset(config, attrs) do
    config
    |> cast(attrs, [
      :uuid,
      :name,
      :value
    ])
    |> validate_required([
      :uuid,
      :name,
      :value
    ])
    |> validate_length(:name, min: 1, max: 200)
    # Encrypted secrets (a SecretBox envelope around e.g. an RSA-2048/4096 SAML
    # SP private key) run ~2.3-4.4 KB — well past the original 2 KB cap, which
    # silently failed those saves. The DB column is `text`, so this is the only
    # bound.
    |> validate_length(:value, max: 8000)
  end
end

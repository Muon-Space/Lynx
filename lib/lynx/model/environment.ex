# Copyright 2023 Clivern. All rights reserved.
# Use of this source code is governed by the MIT
# license that can be found in the LICENSE file.

defmodule Lynx.Model.Environment do
  @moduledoc """
  Environment Model.

  `secret` is a virtual field — the plaintext is accepted on input,
  hashed via `Lynx.Service.TokenHash` in the changeset, and only the
  hash + prefix are persisted. The virtual stays populated on the
  in-memory struct after a successful insert/update so callers can
  surface the plaintext at creation/rotation (mint-once UX).
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Lynx.Service.TokenHash

  schema "environments" do
    field :uuid, Ecto.UUID
    field :name, :string
    field :slug, :string
    field :username, :string
    field :secret, :string, virtual: true
    field :secret_hash, :string
    field :secret_prefix, :string
    field :project_id, :id

    # Policy enforcement gates (issue #38). Both nullable so they can
    # inherit a global default from `Settings.PolicyGate`. nil = inherit;
    # true / false = explicit override.
    field :require_passing_plan, :boolean
    field :block_violating_apply, :boolean
    field :plan_max_age_seconds, :integer, default: 1800

    timestamps()
  end

  @doc false
  def changeset(state, attrs) do
    state
    |> cast(attrs, [
      :uuid,
      :name,
      :slug,
      :username,
      :secret,
      :secret_hash,
      :secret_prefix,
      :project_id,
      :require_passing_plan,
      :block_violating_apply,
      :plan_max_age_seconds
    ])
    |> derive_secret_hash()
    |> validate_required([
      :uuid,
      :name,
      :slug,
      :username,
      :secret_hash,
      :project_id
    ])
    |> validate_number(:plan_max_age_seconds, greater_than: 0)
    |> unique_constraint(:slug,
      name: :environments_project_id_slug_index,
      message: "already exists in this project"
    )
  end

  defp derive_secret_hash(changeset) do
    case get_change(changeset, :secret) do
      nil ->
        changeset

      "" ->
        changeset

      plaintext when is_binary(plaintext) ->
        changeset
        |> put_change(:secret_hash, TokenHash.hash(plaintext))
        |> put_change(:secret_prefix, TokenHash.prefix(plaintext))
    end
  end
end

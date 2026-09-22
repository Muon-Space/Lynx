# Copyright 2023 Clivern. All rights reserved.
# Use of this source code is governed by the MIT
# license that can be found in the LICENSE file.

defmodule Lynx.Model.Lock do
  @moduledoc """
  Lock Model

  `mode` is `"shared"` for read-only operations (`terraform plan`) and
  `"exclusive"` for everything that may write state. Any number of shared
  locks can be active on one path; at most one exclusive lock can be, which
  the `locks_unique_active_exclusive_per_path` partial index enforces.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @modes ~w(shared exclusive)

  def modes, do: @modes

  schema "locks" do
    field :uuid, Ecto.UUID
    field :environment_id, :id
    field :operation, :string
    field :info, :string
    field :who, :string
    field :version, :string
    field :path, :string
    field :sub_path, :string, default: ""
    field :mode, :string, default: "exclusive"
    field :is_active, :boolean

    timestamps()
  end

  @doc false
  def changeset(lock, attrs) do
    lock
    |> cast(attrs, [
      :uuid,
      :environment_id,
      :operation,
      :info,
      :who,
      :version,
      :path,
      :sub_path,
      :mode,
      :is_active
    ])
    |> validate_required([
      :uuid,
      :environment_id,
      :mode
    ])
    |> validate_inclusion(:mode, @modes)
    |> unique_constraint([:environment_id, :sub_path],
      name: :locks_unique_active_exclusive_per_path
    )
  end
end

# Copyright 2023 Clivern. All rights reserved.
# Use of this source code is governed by the MIT
# license that can be found in the LICENSE file.

defmodule Lynx.Model.AuditEvent do
  @moduledoc """
  AuditEvent Model
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "audit_events" do
    field :uuid, Ecto.UUID
    field :actor_id, :integer
    field :actor_name, :string
    field :actor_type, :string, default: "user"
    field :action, :string
    field :resource_type, :string
    field :resource_id, :string
    field :resource_name, :string
    field :metadata, :string

    timestamps()
  end

  @doc false
  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :uuid,
      :actor_id,
      :actor_name,
      :actor_type,
      :action,
      :resource_type,
      :resource_id,
      :resource_name,
      :metadata
    ])
    |> validate_required([:uuid, :action, :resource_type])
  end
end

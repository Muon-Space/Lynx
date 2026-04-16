# Copyright 2023 Clivern. All rights reserved.
# Use of this source code is governed by the MIT
# license that can be found in the LICENSE file.

defmodule Lynx.Repo.Migrations.CreateScimTokens do
  use Ecto.Migration

  def change do
    create table(:scim_tokens) do
      add :uuid, :uuid
      add :token, :string
      add :description, :string
      add :is_active, :boolean, default: true
      add :last_used_at, :utc_datetime, null: true

      timestamps()
    end

    create index(:scim_tokens, [:token])
    create index(:scim_tokens, [:is_active])
  end
end

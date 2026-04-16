# Copyright 2023 Clivern. All rights reserved.
# Use of this source code is governed by the MIT
# license that can be found in the LICENSE file.

defmodule Lynx.Repo.Migrations.AddSsoFieldsToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :auth_provider, :string, default: "local"
      add :external_id, :string, null: true
      add :is_active, :boolean, default: true
    end

    create index(:users, [:external_id])
    create index(:users, [:auth_provider])
  end
end

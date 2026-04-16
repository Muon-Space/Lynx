# Copyright 2023 Clivern. All rights reserved.
# Use of this source code is governed by the MIT
# license that can be found in the LICENSE file.

defmodule Lynx.Repo.Migrations.AddScimFieldsToTeams do
  use Ecto.Migration

  def change do
    alter table(:teams) do
      add :external_id, :string, null: true
    end

    create unique_index(:teams, [:external_id])
  end
end

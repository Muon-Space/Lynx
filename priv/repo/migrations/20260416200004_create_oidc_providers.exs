# Copyright 2023 Clivern. All rights reserved.
# Use of this source code is governed by the MIT
# license that can be found in the LICENSE file.

defmodule Lynx.Repo.Migrations.CreateOidcProviders do
  use Ecto.Migration

  def change do
    create table(:oidc_providers) do
      add :uuid, :uuid
      add :name, :string, null: false
      add :discovery_url, :string, null: false
      add :audience, :string
      add :is_active, :boolean, default: true

      timestamps()
    end

    create unique_index(:oidc_providers, [:name])
  end
end

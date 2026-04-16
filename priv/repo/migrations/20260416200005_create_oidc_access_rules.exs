# Copyright 2023 Clivern. All rights reserved.
# Use of this source code is governed by the MIT
# license that can be found in the LICENSE file.

defmodule Lynx.Repo.Migrations.CreateOidcAccessRules do
  use Ecto.Migration

  def change do
    create table(:oidc_access_rules) do
      add :uuid, :uuid
      add :name, :string, null: false
      add :claim_rules, :text, null: false
      add :is_active, :boolean, default: true
      add :provider_id, references(:oidc_providers, on_delete: :delete_all), null: false
      add :environment_id, references(:environments, on_delete: :delete_all), null: false

      timestamps()
    end

    create index(:oidc_access_rules, [:provider_id])
    create index(:oidc_access_rules, [:environment_id])
    create index(:oidc_access_rules, [:provider_id, :environment_id])
  end
end

# Copyright 2023 Clivern. All rights reserved.
# Use of this source code is governed by the MIT
# license that can be found in the LICENSE file.

defmodule Lynx.Repo.Migrations.CreateAuditEvents do
  use Ecto.Migration

  def change do
    create table(:audit_events) do
      add :uuid, :uuid
      add :actor_id, :integer
      add :actor_name, :string
      add :actor_type, :string, default: "user"
      add :action, :string, null: false
      add :resource_type, :string, null: false
      add :resource_id, :string
      add :resource_name, :string
      add :metadata, :text

      timestamps()
    end

    create index(:audit_events, [:action])
    create index(:audit_events, [:resource_type])
    create index(:audit_events, [:actor_id])
    create index(:audit_events, [:inserted_at])
  end
end

# Copyright 2023 Clivern. All rights reserved.
# Use of this source code is governed by the MIT
# license that can be found in the LICENSE file.

defmodule Lynx.Repo.Migrations.AddSsoFieldsToUsersSession do
  use Ecto.Migration

  def change do
    alter table(:users_session) do
      add :auth_method, :string, default: "password"
      add :idp_session_id, :string, null: true
    end
  end
end

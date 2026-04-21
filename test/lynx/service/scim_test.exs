# Copyright 2023 Clivern. All rights reserved.
# Use of this source code is governed by the MIT
# license that can be found in the LICENSE file.

defmodule Lynx.Service.SCIMTest do
  @moduledoc """
  SCIM Module Test Cases
  """

  use ExUnit.Case

  alias Lynx.Service.SCIM
  alias Lynx.Context.UserContext

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Lynx.Repo)
  end

  # -- Users --

  describe "SCIM user operations" do
    test "create_user/1 creates a new user" do
      attrs = %{
        email: "scim_user@example.com",
        name: "SCIM User",
        external_id: "scim-ext-001",
        is_active: true
      }

      assert {:ok, user} = SCIM.create_user(attrs)
      assert user.email == "scim_user@example.com"
      assert user.name == "SCIM User"
      assert user.external_id == "scim-ext-001"
      assert user.auth_provider == "scim"
      assert user.role == "regular"
      assert user.is_active == true
    end

    test "create_user/1 is idempotent by external_id" do
      attrs = %{
        email: "scim_idem@example.com",
        name: "SCIM Idempotent",
        external_id: "scim-ext-idem",
        is_active: true
      }

      {:ok, first} = SCIM.create_user(attrs)

      attrs2 = %{
        email: "scim_idem@example.com",
        name: "SCIM Idempotent Updated",
        external_id: "scim-ext-idem",
        is_active: true
      }

      {:ok, second} = SCIM.create_user(attrs2)
      assert second.id == first.id
      assert second.name == "SCIM Idempotent Updated"
    end

    test "get_user/1 returns user by uuid" do
      {:ok, user} =
        SCIM.create_user(%{
          email: "scim_get@example.com",
          name: "SCIM Get",
          external_id: "scim-ext-get"
        })

      assert {:ok, found} = SCIM.get_user(user.uuid)
      assert found.id == user.id
    end

    test "get_user/1 returns not_found for missing uuid" do
      assert {:not_found, _} = SCIM.get_user(Ecto.UUID.generate())
    end

    test "patch_user/2 deactivates a user" do
      {:ok, user} =
        SCIM.create_user(%{
          email: "scim_deactivate@example.com",
          name: "To Deactivate",
          external_id: "scim-ext-deactivate"
        })

      operations = [%{"op" => "replace", "value" => %{"active" => false}}]
      assert {:ok, updated} = SCIM.patch_user(user.uuid, operations)
      assert updated.is_active == false
    end

    test "delete_user/1 soft-deletes by setting is_active false" do
      {:ok, user} =
        SCIM.create_user(%{
          email: "scim_delete@example.com",
          name: "To Delete",
          external_id: "scim-ext-delete"
        })

      assert :ok = SCIM.delete_user(user.uuid)

      # User still exists but is inactive
      found = UserContext.get_user_by_uuid(user.uuid)
      assert found != nil
      assert found.is_active == false
    end

    test "delete_user/1 returns not_found for missing uuid" do
      assert {:not_found, _} = SCIM.delete_user(Ecto.UUID.generate())
    end

    test "list_users/3 returns users" do
      {:ok, _} =
        SCIM.create_user(%{
          email: "scim_list1@example.com",
          name: "List User 1",
          external_id: "scim-ext-list1"
        })

      {users, total} = SCIM.list_users(nil, 1, 100)
      assert total >= 1
      assert length(users) >= 1
    end

    test "list_users/3 filters by userName" do
      {:ok, _} =
        SCIM.create_user(%{
          email: "scim_filter@example.com",
          name: "Filter User",
          external_id: "scim-ext-filter"
        })

      filter = %{attr: "userName", value: "scim_filter@example.com"}
      {users, _total} = SCIM.list_users(filter, 1, 100)
      assert length(users) == 1
      assert hd(users).email == "scim_filter@example.com"
    end
  end

  # -- Groups --

  describe "SCIM group operations" do
    test "create_group/1 creates a new team" do
      attrs = %{
        display_name: "Engineering",
        description: "Engineering Team",
        external_id: "scim-grp-001"
      }

      assert {:ok, team} = SCIM.create_group(attrs)
      assert team.name == "Engineering"
      assert team.slug == "engineering"
      assert team.external_id == "scim-grp-001"
    end

    test "create_group/1 is idempotent by external_id" do
      attrs = %{
        display_name: "Platform",
        external_id: "scim-grp-idem"
      }

      {:ok, first} = SCIM.create_group(attrs)

      attrs2 = %{
        display_name: "Platform Updated",
        external_id: "scim-grp-idem"
      }

      {:ok, second} = SCIM.create_group(attrs2)
      assert second.id == first.id
      assert second.name == "Platform Updated"
    end

    test "get_group/1 returns team by uuid" do
      {:ok, team} =
        SCIM.create_group(%{
          display_name: "Get Group",
          external_id: "scim-grp-get"
        })

      assert {:ok, found} = SCIM.get_group(team.uuid)
      assert found.id == team.id
    end

    test "get_group/1 returns not_found for missing uuid" do
      assert {:not_found, _} = SCIM.get_group(Ecto.UUID.generate())
    end

    test "delete_group/1 deletes a team" do
      {:ok, team} =
        SCIM.create_group(%{
          display_name: "Delete Group",
          external_id: "scim-grp-delete"
        })

      assert :ok = SCIM.delete_group(team.uuid)
      assert {:not_found, _} = SCIM.get_group(team.uuid)
    end

    test "patch_group/2 adds members" do
      {:ok, user} =
        SCIM.create_user(%{
          email: "member@example.com",
          name: "Member User",
          external_id: "scim-ext-member"
        })

      {:ok, team} =
        SCIM.create_group(%{
          display_name: "Membership Group",
          external_id: "scim-grp-members"
        })

      operations = [
        %{
          "op" => "add",
          "path" => "members",
          "value" => [%{"value" => user.uuid}]
        }
      ]

      assert {:ok, _} = SCIM.patch_group(team.uuid, operations)

      # Verify membership
      members = Lynx.Context.TeamContext.get_team_members(team.id)
      assert user.uuid in members
    end

    test "patch_group/2 removes members" do
      {:ok, user} =
        SCIM.create_user(%{
          email: "remove_member@example.com",
          name: "Remove Member",
          external_id: "scim-ext-remove"
        })

      {:ok, team} =
        SCIM.create_group(%{
          display_name: "Remove Member Group",
          external_id: "scim-grp-remove"
        })

      # Add member first
      user_id = UserContext.get_user_id_with_uuid(user.uuid)
      UserContext.add_user_to_team(user_id, team.id)

      # Remove via SCIM PATCH
      operations = [
        %{
          "op" => "remove",
          "path" => "members[value eq \"#{user.uuid}\"]"
        }
      ]

      assert {:ok, _} = SCIM.patch_group(team.uuid, operations)

      members = Lynx.Context.TeamContext.get_team_members(team.id)
      assert user.uuid not in members
    end
  end
end

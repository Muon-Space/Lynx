# Copyright 2023 Clivern. All rights reserved.
# Use of this source code is governed by the MIT
# license that can be found in the LICENSE file.

defmodule Lynx.Service.SCIMServiceTest do
  @moduledoc """
  SCIM Service Test Cases
  """

  use ExUnit.Case

  alias Lynx.Service.SCIMService

  describe "parse_filter/1" do
    test "parses eq filter" do
      assert SCIMService.parse_filter("userName eq \"jane@example.com\"") == %{
               attr: "userName",
               value: "jane@example.com"
             }
    end

    test "returns nil for nil input" do
      assert SCIMService.parse_filter(nil) == nil
    end

    test "returns nil for empty string" do
      assert SCIMService.parse_filter("") == nil
    end

    test "returns nil for unsupported filter" do
      assert SCIMService.parse_filter("userName co \"jane\"") == nil
    end
  end

  describe "parse_user_resource/1" do
    test "parses valid user with userName" do
      body = %{
        "userName" => "jane@example.com",
        "name" => %{"givenName" => "Jane", "familyName" => "Doe"},
        "externalId" => "ext-123",
        "active" => true
      }

      assert {:ok, attrs} = SCIMService.parse_user_resource(body)
      assert attrs.email == "jane@example.com"
      assert attrs.name == "Jane Doe"
      assert attrs.external_id == "ext-123"
      assert attrs.is_active == true
    end

    test "parses user with emails array" do
      body = %{
        "emails" => [%{"value" => "via_emails@example.com", "primary" => true}],
        "name" => %{"formatted" => "Email User"}
      }

      assert {:ok, attrs} = SCIMService.parse_user_resource(body)
      assert attrs.email == "via_emails@example.com"
    end

    test "returns error when no email present" do
      body = %{"name" => %{"formatted" => "No Email"}}
      assert {:error, _} = SCIMService.parse_user_resource(body)
    end

    test "defaults active to true" do
      body = %{"userName" => "default_active@example.com"}
      {:ok, attrs} = SCIMService.parse_user_resource(body)
      assert attrs.is_active == true
    end
  end

  describe "parse_group_resource/1" do
    test "parses valid group" do
      body = %{
        "displayName" => "Engineering",
        "externalId" => "grp-123",
        "members" => [%{"value" => "user-uuid-1"}]
      }

      assert {:ok, attrs} = SCIMService.parse_group_resource(body)
      assert attrs.display_name == "Engineering"
      assert attrs.external_id == "grp-123"
      assert length(attrs.members) == 1
    end

    test "returns error when displayName missing" do
      body = %{"externalId" => "grp-123"}
      assert {:error, _} = SCIMService.parse_group_resource(body)
    end

    test "handles nil members" do
      body = %{"displayName" => "No Members"}
      {:ok, attrs} = SCIMService.parse_group_resource(body)
      assert attrs.members == nil
    end
  end

  describe "parse_patch_operations/1" do
    test "parses valid operations" do
      body = %{
        "Operations" => [
          %{"op" => "replace", "value" => %{"active" => false}}
        ]
      }

      assert {:ok, ops} = SCIMService.parse_patch_operations(body)
      assert length(ops) == 1
    end

    test "returns error when Operations missing" do
      assert {:error, _} = SCIMService.parse_patch_operations(%{})
    end

    test "returns error when Operations not a list" do
      assert {:error, _} = SCIMService.parse_patch_operations(%{"Operations" => "invalid"})
    end
  end

  describe "format_error/2" do
    test "formats SCIM error" do
      error = SCIMService.format_error(404, "Not found")
      assert error["status"] == "404"
      assert error["detail"] == "Not found"
      assert "urn:ietf:params:scim:api:messages:2.0:Error" in error["schemas"]
    end
  end

  describe "service_provider_config/0" do
    test "returns valid config" do
      config = SCIMService.service_provider_config()
      assert config["patch"]["supported"] == true
      assert config["bulk"]["supported"] == false
      assert config["filter"]["supported"] == true
      assert length(config["authenticationSchemes"]) == 1
    end
  end
end

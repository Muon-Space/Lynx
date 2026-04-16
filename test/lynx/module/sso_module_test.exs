# Copyright 2023 Clivern. All rights reserved.
# Use of this source code is governed by the MIT
# license that can be found in the LICENSE file.

defmodule Lynx.Module.SSOModuleTest do
  @moduledoc """
  SSO Module Test Cases
  """

  use ExUnit.Case

  alias Lynx.Module.SSOModule
  alias Lynx.Module.UserModule
  alias Lynx.Context.UserContext

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Lynx.Repo)
  end

  describe "config helpers" do
    test "is_sso_enabled?/0 returns false by default" do
      assert SSOModule.is_sso_enabled?() == false
    end

    test "is_password_enabled?/0 returns true by default" do
      assert SSOModule.is_password_enabled?() == true
    end

    test "get_sso_protocol/0 returns :oidc by default" do
      assert SSOModule.get_sso_protocol() == :oidc
    end

    test "get_sso_login_label/0 returns SSO by default" do
      assert SSOModule.get_sso_login_label() == "SSO"
    end
  end

  describe "find_or_create_sso_user/2" do
    test "creates a new user when none exists" do
      attrs = %{
        external_id: "ext-user-001",
        email: "sso_new@example.com",
        name: "SSO User"
      }

      assert {:ok, user} = SSOModule.find_or_create_sso_user(attrs, "oidc")
      assert user.email == "sso_new@example.com"
      assert user.name == "SSO User"
      assert user.external_id == "ext-user-001"
      assert user.is_active == true
      assert user.role == "regular"
    end

    test "finds existing user by external_id on repeat login" do
      attrs = %{
        external_id: "ext-user-002",
        email: "sso_repeat@example.com",
        name: "SSO Repeat"
      }

      {:ok, first_user} = SSOModule.find_or_create_sso_user(attrs, "oidc")

      # Second login with same external_id
      attrs2 = %{
        external_id: "ext-user-002",
        email: "sso_repeat@example.com",
        name: "SSO Repeat Updated"
      }

      {:ok, second_user} = SSOModule.find_or_create_sso_user(attrs2, "oidc")
      assert second_user.id == first_user.id
      assert second_user.name == "SSO Repeat Updated"
    end

    test "links existing local user by email on first SSO login" do
      # Install app first so app_key is available for password hashing
      alias Lynx.Module.InstallModule

      InstallModule.store_configs(%{
        app_name: "Lynx",
        app_url: "http://lynx.test",
        app_email: "test@lynx.test",
        app_key: Lynx.Service.AuthService.get_random_salt()
      })

      # Create a local user first
      {:ok, local_user} =
        UserModule.create_user(%{
          email: "local_user@example.com",
          name: "Local User",
          password: "password123",
          role: "regular",
          api_key: Ecto.UUID.generate()
        })

      # SSO login with same email
      attrs = %{
        external_id: "ext-user-003",
        email: "local_user@example.com",
        name: "Local User"
      }

      {:ok, sso_user} = SSOModule.find_or_create_sso_user(attrs, "oidc")
      assert sso_user.id == local_user.id
      assert sso_user.external_id == "ext-user-003"
    end

    test "rejects deactivated user" do
      attrs = %{
        external_id: "ext-user-deactivated",
        email: "deactivated@example.com",
        name: "Deactivated User"
      }

      {:ok, user} = SSOModule.find_or_create_sso_user(attrs, "oidc")
      UserContext.update_user(user, %{is_active: false})

      # Try to login again
      assert {:error, "Account is deactivated"} =
               SSOModule.find_or_create_sso_user(attrs, "oidc")
    end
  end
end

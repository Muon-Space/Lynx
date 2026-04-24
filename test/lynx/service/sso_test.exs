# Copyright 2023 Clivern. All rights reserved.
# Use of this source code is governed by the MIT
# license that can be found in the LICENSE file.

defmodule Lynx.Service.SSOTest do
  @moduledoc """
  SSO Module Test Cases
  """

  use ExUnit.Case

  alias Lynx.Service.SSO
  alias Lynx.Context.UserContext
  alias Lynx.Context.UserContext

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Lynx.Repo)
  end

  describe "config helpers" do
    test "is_sso_enabled?/0 returns false by default" do
      assert SSO.is_sso_enabled?() == false
    end

    test "is_password_enabled?/0 returns true by default" do
      assert SSO.is_password_enabled?() == true
    end

    test "get_sso_protocol/0 returns :oidc by default" do
      assert SSO.get_sso_protocol() == :oidc
    end

    test "get_sso_login_label/0 returns SSO by default" do
      assert SSO.get_sso_login_label() == "SSO"
    end
  end

  describe "find_or_create_sso_user/2" do
    test "creates a new user when none exists" do
      attrs = %{
        external_id: "ext-user-001",
        email: "sso_new@example.com",
        name: "SSO User"
      }

      assert {:ok, user} = SSO.find_or_create_sso_user(attrs, "oidc")
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

      {:ok, first_user} = SSO.find_or_create_sso_user(attrs, "oidc")

      # Second login with same external_id
      attrs2 = %{
        external_id: "ext-user-002",
        email: "sso_repeat@example.com",
        name: "SSO Repeat Updated"
      }

      {:ok, second_user} = SSO.find_or_create_sso_user(attrs2, "oidc")
      assert second_user.id == first_user.id
      assert second_user.name == "SSO Repeat Updated"
    end

    test "links existing local user by email on first SSO login" do
      # Install app first so app_key is available for password hashing
      alias Lynx.Service.Install

      Install.store_configs(%{
        app_name: "Lynx",
        app_url: "http://lynx.test",
        app_email: "test@lynx.test",
        app_key: Lynx.Service.AuthService.get_random_salt()
      })

      # Create a local user first
      {:ok, local_user} =
        UserContext.create_user_from_data(%{
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

      {:ok, sso_user} = SSO.find_or_create_sso_user(attrs, "oidc")
      assert sso_user.id == local_user.id
      assert sso_user.external_id == "ext-user-003"
    end

    test "repeat SSO login with nil name preserves the existing name (regression: SCIM-set names were getting clobbered with email)" do
      # Provision the user with a friendly name (mirrors the SCIM flow,
      # which writes "Aron Gates" rather than the email).
      provisioned = %{
        external_id: "ext-scim-001",
        email: "aron@example.com",
        name: "Aron Gates"
      }

      {:ok, first_user} = SSO.find_or_create_sso_user(provisioned, "oidc")
      assert first_user.name == "Aron Gates"

      # Subsequent SSO login where the IdP didn't include a `name`
      # claim — the extractor passes nil through. The update branch
      # must keep the existing name, not overwrite with email.
      login_no_name = %{
        external_id: "ext-scim-001",
        email: "aron@example.com",
        name: nil
      }

      {:ok, second_user} = SSO.find_or_create_sso_user(login_no_name, "oidc")
      assert second_user.id == first_user.id
      assert second_user.name == "Aron Gates"
    end

    test "first JIT user with nil name still gets a non-nil name (falls back to email)" do
      attrs = %{
        external_id: "ext-jit-noname",
        email: "noname@example.com",
        name: nil
      }

      assert {:ok, user} = SSO.find_or_create_sso_user(attrs, "oidc")
      assert user.name == "noname@example.com"
    end

    test "rejects deactivated user" do
      attrs = %{
        external_id: "ext-user-deactivated",
        email: "deactivated@example.com",
        name: "Deactivated User"
      }

      {:ok, user} = SSO.find_or_create_sso_user(attrs, "oidc")
      UserContext.update_user(user, %{is_active: false})

      # Try to login again
      assert {:error, "Account is deactivated"} =
               SSO.find_or_create_sso_user(attrs, "oidc")
    end
  end
end

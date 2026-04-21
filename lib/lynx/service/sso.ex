# Copyright 2023 Clivern. All rights reserved.
# Use of this source code is governed by the MIT
# license that can be found in the LICENSE file.

defmodule Lynx.Service.SSO do
  @moduledoc """
  SSO Module - handles JIT provisioning and SSO configuration
  """

  alias Lynx.Context.UserContext
  alias Lynx.Context.UserContext
  alias Lynx.Service.Settings
  alias Lynx.Service.AuthService

  @doc """
  Check if SSO is enabled
  """
  def is_sso_enabled? do
    Settings.get_sso_config("auth_sso_enabled", "false") == "true"
  end

  @doc """
  Check if password auth is enabled
  """
  def is_password_enabled? do
    if System.get_env("FORCE_PASSWORD_LOGIN") == "true" do
      true
    else
      Settings.get_sso_config("auth_password_enabled", "true") == "true"
    end
  end

  @doc """
  Get SSO protocol (:oidc or :saml)
  """
  def get_sso_protocol do
    case Settings.get_sso_config("sso_protocol", "oidc") do
      "saml" -> :saml
      _ -> :oidc
    end
  end

  @doc """
  Get SSO login button label
  """
  def get_sso_login_label do
    Settings.get_sso_config("sso_login_label", "SSO")
  end

  @doc """
  Check if JIT provisioning is enabled
  """
  def is_jit_enabled? do
    Settings.get_sso_config("sso_jit_enabled", "true") == "true"
  end

  @doc """
  Find or create a user from SSO claims.

  Lookup order:
  1. By external_id (repeat SSO login)
  2. By email (local/SCIM user's first SSO login - links the account)
  3. Not found - creates new user (only if JIT provisioning is enabled)
  """
  def find_or_create_sso_user(attrs, provider) when provider in ["oidc", "saml"] do
    external_id = attrs[:external_id]
    email = attrs[:email]
    name = attrs[:name]

    case UserContext.get_user_by_external_id(external_id) do
      nil ->
        case UserContext.get_user_by_email(email) do
          nil ->
            if is_jit_enabled?() do
              UserContext.create_sso_user(%{
                email: email,
                name: name,
                auth_provider: provider,
                external_id: external_id
              })
            else
              {:error,
               "User not found. JIT provisioning is disabled -- users must be provisioned via SCIM before they can log in."}
            end

          existing_user ->
            if existing_user.is_active do
              UserContext.update_user(existing_user, %{
                external_id: external_id,
                name: name || existing_user.name
              })
            else
              {:error, "Account is deactivated"}
            end
        end

      existing_user ->
        if existing_user.is_active do
          UserContext.update_user(existing_user, %{
            name: name || existing_user.name,
            last_seen: DateTime.utc_now()
          })
        else
          {:error, "Account is deactivated"}
        end
    end
  end

  @doc """
  Create SSO session for a user
  """
  def create_sso_session(user, auth_method) do
    AuthService.login_sso(user, auth_method)
  end
end

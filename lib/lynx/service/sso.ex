# Copyright 2023 Clivern. All rights reserved.
# Use of this source code is governed by the MIT
# license that can be found in the LICENSE file.

defmodule Lynx.Service.SSO do
  @moduledoc """
  SSO Module - handles JIT provisioning and SSO configuration
  """

  alias Lynx.Context.{UserContext, UserIdentityContext}
  alias Lynx.Service.{AuthService, Settings}

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
  Find or create a user from SSO claims via the identity-linking layer.

  Routes through `UserIdentityContext.find_or_link/4`, which is the
  single point of truth for the "is this a known user?" decision —
  shared with SCIM provisioning. When the IdP-asserted identity isn't
  yet linked but the email matches an existing user, the new identity
  is auto-linked to that user (the "merge"), so the same human can
  log in via SAML, OIDC, SCIM, or password without spawning duplicate
  user rows.

  Returns `{:ok, user}` on success, or `{:error, reason}` if the user
  is deactivated / JIT is disabled / DB-level failure.
  """
  def find_or_create_sso_user(attrs, provider) when provider in ["oidc", "saml"] do
    external_id = attrs[:external_id]
    email = attrs[:email]
    name = attrs[:name]

    create_fn = fn ->
      if is_jit_enabled?() do
        # Identity linkage happens in `UserIdentityContext.find_or_link/4`
        # — this just mints the canonical user row. Name fallback is
        # only applied when the IdP didn't provide one (extractors
        # leave it nil so merge branches preserve existing names).
        UserContext.create_sso_user(%{
          email: email,
          name: name || email
        })
      else
        {:error,
         "User not found. JIT provisioning is disabled -- users must be provisioned via SCIM before they can log in."}
      end
    end

    case UserIdentityContext.find_or_link(provider, external_id, email, create_fn) do
      {:ok, user, _linkage} ->
        cond do
          not user.is_active ->
            {:error, "Account is deactivated"}

          true ->
            # Refresh display name + last_seen on the canonical user.
            # Name preservation: only overwrite if the IdP supplied
            # one (extractors leave nil otherwise).
            UserContext.update_user(user, %{
              name: name || user.name,
              last_seen: DateTime.utc_now()
            })
        end

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Create SSO session for a user
  """
  def create_sso_session(user, auth_method) do
    AuthService.login_sso(user, auth_method)
  end
end

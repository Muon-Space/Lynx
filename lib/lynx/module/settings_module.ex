# Copyright 2023 Clivern. All rights reserved.
# Use of this source code is governed by the MIT
# license that can be found in the LICENSE file.

defmodule Lynx.Module.SettingsModule do
  @moduledoc """
  Settings Module
  """

  alias Lynx.Context.ConfigContext

  @doc """
  Update Application Configs
  """
  def update_configs(configs \\ %{}) do
    items = [
      ConfigContext.new_config(%{name: "app_name", value: configs[:app_name]}),
      ConfigContext.new_config(%{name: "app_url", value: configs[:app_url]}),
      ConfigContext.new_config(%{name: "app_email", value: configs[:app_email]})
    ]

    for item <- items do
      config = ConfigContext.get_config_by_name(item.name)
      ConfigContext.update_config(config, %{value: item.value})
    end
  end

  @doc """
  Update SSO/SCIM Configs
  """
  def update_sso_configs(configs \\ %{}) do
    keys = [
      "auth_password_enabled",
      "auth_sso_enabled",
      "sso_protocol",
      "sso_login_label",
      "sso_issuer",
      "sso_client_id",
      "sso_client_secret",
      "sso_saml_idp_sso_url",
      "sso_saml_idp_issuer",
      "sso_saml_idp_cert",
      "sso_saml_idp_metadata_url",
      "sso_saml_sp_entity_id",
      "sso_saml_sp_cert",
      "sso_saml_sp_key",
      "sso_saml_sign_requests",
      "scim_enabled"
    ]

    for key <- keys do
      if Map.has_key?(configs, key) do
        upsert_config(key, configs[key])
      end
    end
  end

  @doc """
  Get Config (DB first, then env var fallback via Application config)
  """
  def get_config(name, default \\ "") do
    case ConfigContext.get_config_by_name(name) do
      nil ->
        default

      config ->
        config.value
    end
  end

  @doc """
  Get SSO/SCIM config with env var fallback
  """
  def get_sso_config(name, default \\ "") do
    case ConfigContext.get_config_by_name(name) do
      nil ->
        env_fallback(name, default)

      config ->
        config.value
    end
  end

  @doc """
  Upsert a config value (create if missing, update if exists)
  """
  def upsert_config(name, value) do
    case ConfigContext.get_config_by_name(name) do
      nil ->
        item = ConfigContext.new_config(%{name: name, value: value})
        ConfigContext.create_config(item)

      config ->
        ConfigContext.update_config(config, %{value: value})
    end
  end

  defp env_fallback("auth_password_enabled", default),
    do: to_string(Application.get_env(:lynx, :auth_password_enabled, default))

  defp env_fallback("auth_sso_enabled", default),
    do: to_string(Application.get_env(:lynx, :auth_sso_enabled, default))

  defp env_fallback("sso_protocol", default),
    do: Application.get_env(:lynx, :sso_protocol, default)

  defp env_fallback("sso_login_label", default),
    do: Application.get_env(:lynx, :sso_login_label, default)

  defp env_fallback("sso_issuer", default),
    do: Application.get_env(:lynx, :sso_issuer, default)

  defp env_fallback("sso_client_id", default),
    do: Application.get_env(:lynx, :sso_client_id, default)

  defp env_fallback("sso_client_secret", default),
    do: Application.get_env(:lynx, :sso_client_secret, default)

  defp env_fallback("sso_saml_idp_sso_url", default),
    do: Application.get_env(:lynx, :sso_saml_idp_sso_url, default)

  defp env_fallback("sso_saml_idp_issuer", default),
    do: Application.get_env(:lynx, :sso_saml_idp_issuer, default)

  defp env_fallback("sso_saml_idp_cert", default),
    do: Application.get_env(:lynx, :sso_saml_idp_cert, default)

  defp env_fallback("sso_saml_idp_metadata_url", default),
    do: Application.get_env(:lynx, :sso_saml_idp_metadata_url, default)

  defp env_fallback("sso_saml_sp_entity_id", default),
    do: Application.get_env(:lynx, :sso_saml_sp_entity_id, default)

  defp env_fallback("sso_saml_sign_requests", default),
    do: to_string(Application.get_env(:lynx, :sso_saml_sign_requests, default))

  defp env_fallback("scim_enabled", default),
    do: to_string(Application.get_env(:lynx, :scim_enabled, default))

  defp env_fallback(_, default), do: default
end

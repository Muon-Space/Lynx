# Copyright 2023 Clivern. All rights reserved.
# Use of this source code is governed by the MIT
# license that can be found in the LICENSE file.

defmodule Lynx.Service.Settings do
  @moduledoc """
  Settings Module.

  Sensitive config keys are transparently encrypted at rest via
  `Lynx.Service.SecretBox` (AES-256-GCM with a key derived from
  `APP_SECRET`). Both `upsert_config/2` and the `get_*_config`
  helpers route through the secret box when the key is in
  `@encrypted_keys` — call sites don't need to know.

  Currently encrypted: `sso_client_secret` (OIDC) +
  `sso_saml_sp_key` (SAML SP private key).
  """

  require Logger

  alias Lynx.Context.ConfigContext
  alias Lynx.Service.SecretBox

  # Config rows whose `value` is encrypted at rest. Keep this list
  # minimal — only entries the app actually needs to recover in
  # plaintext (vs token-style entries, which should use TokenHash).
  @encrypted_keys MapSet.new([
                    "sso_client_secret",
                    "sso_saml_sp_key"
                  ])

  @doc "Whether a config key is encrypted at rest. Exposed so the migration backfill can use the same source of truth."
  def encrypted_key?(name) when is_binary(name), do: MapSet.member?(@encrypted_keys, name)
  def encrypted_key?(_), do: false

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
      "sso_jit_enabled",
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
  Get Config (DB first, then env var fallback via Application config).

  Encrypted keys are decrypted transparently. If decryption fails
  (e.g. APP_SECRET rotated under existing ciphertext), the default is
  returned and a warning is logged so SSO surfaces "not configured"
  instead of crashing.
  """
  def get_config(name, default \\ "") do
    case ConfigContext.get_config_by_name(name) do
      nil ->
        default

      config ->
        decrypt_if_encrypted(name, config.value, default)
    end
  end

  @doc """
  Get SSO/SCIM config with env var fallback. Same encryption-
  transparency contract as `get_config/2`.
  """
  def get_sso_config(name, default \\ "") do
    case ConfigContext.get_config_by_name(name) do
      nil ->
        env_fallback(name, default)

      config ->
        decrypt_if_encrypted(name, config.value, default)
    end
  end

  @doc """
  Upsert a config value (create if missing, update if exists).

  When `name` is in `@encrypted_keys`, the value is encrypted via
  `SecretBox` before being persisted. Empty strings pass through
  unchanged (treated as "no value"), so clearing a sensitive field
  works identically to clearing a non-sensitive one.
  """
  def upsert_config(name, value) do
    stored = encrypt_if_encrypted(name, value)

    case ConfigContext.get_config_by_name(name) do
      nil ->
        item = ConfigContext.new_config(%{name: name, value: stored})
        ConfigContext.create_config(item)

      config ->
        ConfigContext.update_config(config, %{value: stored})
    end
  end

  defp decrypt_if_encrypted(name, raw, default) do
    if encrypted_key?(name) do
      case SecretBox.decrypt(raw) do
        {:ok, plaintext} ->
          plaintext

        {:error, reason} ->
          Logger.warning(
            "Settings: failed to decrypt config '#{name}' (#{inspect(reason)}); falling back to default. " <>
              "If APP_SECRET was rotated, re-enter this value via the Settings UI."
          )

          default
      end
    else
      raw
    end
  end

  defp encrypt_if_encrypted(name, value) when is_binary(value) do
    if encrypted_key?(name), do: SecretBox.encrypt(value), else: value
  end

  defp encrypt_if_encrypted(_name, value), do: value

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

  defp env_fallback("sso_jit_enabled", default),
    do: to_string(Application.get_env(:lynx, :sso_jit_enabled, default))

  defp env_fallback("sso_saml_sign_requests", default),
    do: to_string(Application.get_env(:lynx, :sso_saml_sign_requests, default))

  defp env_fallback("scim_enabled", default),
    do: to_string(Application.get_env(:lynx, :scim_enabled, default))

  defp env_fallback(_, default), do: default
end

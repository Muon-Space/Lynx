defmodule Lynx.Service.SettingsTest do
  @moduledoc """
  Pinning the encryption-at-rest contract for sensitive configs:

    * `upsert_config/2` for an encrypted key persists ciphertext
      (the raw DB row never holds plaintext).
    * `get_config/2` and `get_sso_config/2` decrypt transparently.
    * Non-sensitive keys are stored + read as plaintext (no behavior
      change for the rest of the configs table).
    * Decrypt failure (e.g. APP_SECRET rotated under existing
      ciphertext) falls back to the configured default + logs.
  """
  use LynxWeb.LiveCase, async: false

  alias Lynx.Context.ConfigContext
  alias Lynx.Service.{SecretBox, Settings}

  setup do
    mark_installed()
    :ok
  end

  describe "encrypted_key?/1" do
    test "lists the two SSO secrets we encrypt at rest" do
      assert Settings.encrypted_key?("sso_client_secret")
      assert Settings.encrypted_key?("sso_saml_sp_key")
    end

    test "false for everything else (non-sensitive keys stay plaintext)" do
      refute Settings.encrypted_key?("app_name")
      refute Settings.encrypted_key?("sso_client_id")
      refute Settings.encrypted_key?("sso_saml_sp_cert")
      refute Settings.encrypted_key?(nil)
    end
  end

  describe "upsert_config + get_*_config — encrypted keys" do
    test "sso_client_secret is stored as ciphertext, returned as plaintext" do
      Settings.upsert_config("sso_client_secret", "super-secret-oidc-value")

      # Raw DB row holds the envelope, not the plaintext.
      raw = ConfigContext.get_config_by_name("sso_client_secret").value
      assert SecretBox.encrypted?(raw)
      refute raw =~ "super-secret-oidc-value"

      # Reads decrypt transparently — both helpers route through SecretBox.
      assert Settings.get_config("sso_client_secret") == "super-secret-oidc-value"
      assert Settings.get_sso_config("sso_client_secret") == "super-secret-oidc-value"
    end

    test "sso_saml_sp_key (PEM private key) round-trips through encryption" do
      pem =
        "-----BEGIN PRIVATE KEY-----\nMIIE....fake-key-bytes....AwIB\n-----END PRIVATE KEY-----"

      Settings.upsert_config("sso_saml_sp_key", pem)

      raw = ConfigContext.get_config_by_name("sso_saml_sp_key").value
      assert SecretBox.encrypted?(raw)
      refute raw =~ "PRIVATE KEY"

      assert Settings.get_sso_config("sso_saml_sp_key") == pem
    end

    test "decrypt failure falls back to the caller's default (no crash)" do
      # Hand-write a row that looks encrypted but isn't — simulates a
      # rotated APP_SECRET making prior ciphertext unreadable.
      Settings.upsert_config("sso_client_secret", "first-value")

      bogus =
        "v1." <>
          Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false) <>
          "." <>
          Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false) <>
          "." <>
          Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)

      raw_row = ConfigContext.get_config_by_name("sso_client_secret")
      ConfigContext.update_config(raw_row, %{value: bogus})

      assert Settings.get_sso_config("sso_client_secret", "fallback") == "fallback"
    end
  end

  describe "non-sensitive keys are unchanged" do
    test "app_name is stored + returned as plaintext" do
      Settings.upsert_config("app_name", "Lynx Prod")

      raw = ConfigContext.get_config_by_name("app_name").value
      assert raw == "Lynx Prod"
      refute SecretBox.encrypted?(raw)

      assert Settings.get_config("app_name") == "Lynx Prod"
    end
  end
end

defmodule Lynx.Service.SecretBox do
  @moduledoc """
  Symmetric AES-256-GCM encryption for at-rest secrets that the app
  needs to recover (vs `TokenHash`, which is one-way for bearer
  tokens). Currently used for the two sensitive `configs` rows:
  `sso_client_secret` and `sso_saml_sp_key`.

  ## Envelope format

  `v1.<base64-iv>.<base64-ciphertext>.<base64-tag>`

  All three components are URL-safe Base64 (no padding). The `v1`
  prefix lets future schemes coexist during a migration without a
  flag day; readers branch on the prefix.

  ## Key derivation

  `HMAC-SHA-256(APP_SECRET, "lynx.secret_box.v1")` — produces a 32-byte
  key suitable for AES-256-GCM. Coupling to `APP_SECRET` matches the
  `TokenHash` precedent: rotating it invalidates everything secret-
  bearing in the app, which keeps the security boundary coherent.

  ## Why not cloak_ecto

  cloak_ecto offers transparent Ecto types + key rotation, but its
  benefits don't pay off for a tiny set (currently 2) of sensitive
  rows in a generic key/value `configs` table — we'd need to fork
  the column or route per-row anyway. Direct `:crypto` keeps the dep
  tree smaller (govcloud) and matches the `TokenHash` precedent.
  Migrate to cloak_ecto if the encrypted-secret count grows or if
  per-key rotation becomes a requirement.

  ## Fail mode

  `decrypt/1` returns `{:error, _}` rather than raising, so callers
  can degrade gracefully when `APP_SECRET` rotated under existing
  ciphertext (operator must re-enter the secret). The Settings
  module logs + returns the configured default in that case so SSO
  surfaces "not configured" instead of crashing.
  """

  require Logger

  @info "lynx.secret_box.v1"
  @prefix "v1."
  # NIST-recommended IV size for GCM.
  @iv_bytes 12

  @doc """
  Encrypt a plaintext string into the versioned envelope. nil/empty
  pass through unchanged so callers can write empty values without a
  branch.
  """
  def encrypt(nil), do: nil
  def encrypt(""), do: ""

  def encrypt(plaintext) when is_binary(plaintext) do
    iv = :crypto.strong_rand_bytes(@iv_bytes)
    {ciphertext, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, key(), iv, plaintext, "", true)

    @prefix <>
      Base.url_encode64(iv, padding: false) <>
      "." <>
      Base.url_encode64(ciphertext, padding: false) <>
      "." <>
      Base.url_encode64(tag, padding: false)
  end

  @doc """
  Decrypt a versioned envelope. Strings missing the `v1.` prefix are
  treated as plaintext (forward-compat with rows that haven't been
  backfilled yet, or hand-written values via `mix` consoles).
  """
  def decrypt(nil), do: {:ok, nil}
  def decrypt(""), do: {:ok, ""}

  def decrypt(@prefix <> rest) do
    with [iv64, ct64, tag64] <- String.split(rest, ".", parts: 3),
         {:ok, iv} <- Base.url_decode64(iv64, padding: false),
         {:ok, ct} <- Base.url_decode64(ct64, padding: false),
         {:ok, tag} <- Base.url_decode64(tag64, padding: false) do
      case :crypto.crypto_one_time_aead(:aes_256_gcm, key(), iv, ct, "", tag, false) do
        plaintext when is_binary(plaintext) -> {:ok, plaintext}
        :error -> {:error, :decrypt_failed}
      end
    else
      _ -> {:error, :malformed}
    end
  end

  # Anything else is treated as already-plaintext. Returning {:ok, raw}
  # lets the Settings layer keep working through a partial backfill.
  def decrypt(other) when is_binary(other), do: {:ok, other}

  @doc """
  True iff the value looks like a SecretBox-encrypted envelope. Used
  by the migration backfill to skip rows that already happen to be
  encrypted (idempotent re-runs).
  """
  def encrypted?(@prefix <> _), do: true
  def encrypted?(_), do: false

  defp key do
    app_secret =
      Application.get_env(:lynx, LynxWeb.Endpoint)[:secret_key_base] ||
        Application.get_env(:lynx, :app_secret) ||
        System.get_env("APP_SECRET") ||
        raise "SecretBox: no APP_SECRET available — cannot derive encryption key"

    :crypto.mac(:hmac, :sha256, app_secret, @info)
  end
end

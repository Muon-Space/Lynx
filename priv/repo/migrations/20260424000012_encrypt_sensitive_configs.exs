defmodule Lynx.Repo.Migrations.EncryptSensitiveConfigs do
  @moduledoc """
  Encrypt the existing plaintext values for the two sensitive
  `configs` rows that the runtime now treats as encrypted at rest:
  `sso_client_secret` and `sso_saml_sp_key`. After this migration,
  `Lynx.Service.Settings` writes new values via `SecretBox.encrypt/1`
  and reads them via `SecretBox.decrypt/1`.

  Idempotent — rows already in the `v1.<...>` envelope are skipped,
  so re-running the migration (or running it on an empty install
  with no rows) is a no-op.

  ## Rollback

  `down/0` is intentionally not provided. The encryption key is
  derived from `APP_SECRET`; without retaining the pre-migration key
  there's no way to recover plaintext from the ciphertext. Operators
  rolling back must restore from a snapshot taken before this
  migration, then re-deploy a release that doesn't read the encrypted
  values.

  ## APP_SECRET coupling

  Operators **must not rotate `APP_SECRET` between applying this
  migration and deploying the new release**. Rotation invalidates the
  encryption key, leaving prior ciphertext undecryptable; the runtime
  will log + fall back to "not configured" and operators will need to
  re-enter the values via the Settings UI.
  """

  use Ecto.Migration

  alias Lynx.Repo
  alias Lynx.Service.{SecretBox, Settings}

  def up do
    keys =
      ["sso_client_secret", "sso_saml_sp_key"]
      |> Enum.filter(&Settings.encrypted_key?/1)

    Enum.each(keys, &encrypt_in_place/1)
  end

  defp encrypt_in_place(name) do
    %Postgrex.Result{rows: rows} =
      Repo.query!("SELECT id, value FROM configs WHERE name = $1", [name])

    Enum.each(rows, fn [id, value] ->
      cond do
        is_nil(value) or value == "" ->
          # Empty / never-set rows stay empty — nothing to encrypt.
          :ok

        SecretBox.encrypted?(value) ->
          # Already in the envelope (e.g. operator hand-encrypted, or
          # the migration was partially applied previously). Skip.
          :ok

        true ->
          ciphertext = SecretBox.encrypt(value)
          Repo.query!("UPDATE configs SET value = $1 WHERE id = $2", [ciphertext, id])
      end
    end)
  end

  def down,
    do:
      raise(
        "EncryptSensitiveConfigs is irreversible — restore plaintext config rows from a pre-migration snapshot."
      )
end

defmodule Lynx.Service.TokenHash do
  @moduledoc """
  Pepper-derived HMAC-SHA-256 hashing for high-entropy bearer tokens
  (`users.api_key`, `environments.secret`, `scim_tokens.token`,
  `opa_bundle_tokens.token`).

  Why HMAC + pepper rather than bcrypt: every token here is a 32+ byte
  random value from `:crypto.strong_rand_bytes/1`, so brute-force
  resistance isn't the threat model. The threat is DB exfiltration —
  an adversary with stolen `_hash` columns should not be able to
  authenticate. HMAC with a server-side pepper means a stolen hash is
  useless without the pepper, and the pepper lives in the app's
  process env (sourced from `APP_SECRET`), not the DB.

  Pepper derivation: `HMAC-SHA-256(APP_SECRET, "lynx.token_hash.v1")`.

  **Operator note:** rotating `APP_SECRET` invalidates every token in
  the system (every `_hash` becomes unmatchable). This is intentional
  and consistent with how session secrets work — if you're rotating
  `APP_SECRET`, you're already accepting "every operator re-auths".
  Re-mint API keys / env secrets / SCIM + OPA tokens after rotation.
  The `v1` info string reserves room for a future scheme migration
  without disturbing this contract.
  """

  @info "lynx.token_hash.v1"

  @doc """
  Hash a token to a hex-encoded HMAC. Returns nil for nil/empty input
  so changesets can pass `nil` through without raising.
  """
  def hash(nil), do: nil
  def hash(""), do: nil

  def hash(token) when is_binary(token) do
    :crypto.mac(:hmac, :sha256, pepper(), token)
    |> Base.encode16(case: :lower)
  end

  @doc """
  First 8 chars of the token, for UI display alongside a `…` marker.
  Lets operators identify which token is which (e.g. in a list of
  three SCIM tokens) without revealing the full secret.
  """
  def prefix(nil), do: nil
  def prefix(""), do: nil

  def prefix(token) when is_binary(token) and byte_size(token) > 8,
    do: String.slice(token, 0, 8)

  def prefix(token) when is_binary(token), do: token

  defp pepper do
    app_secret =
      Application.get_env(:lynx, LynxWeb.Endpoint)[:secret_key_base] ||
        Application.get_env(:lynx, :app_secret) ||
        System.get_env("APP_SECRET") ||
        raise "TokenHash: no APP_SECRET available — cannot hash tokens"

    :crypto.mac(:hmac, :sha256, app_secret, @info)
  end
end

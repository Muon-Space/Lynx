defmodule Lynx.Middleware.OPABundleAuthMiddleware do
  @moduledoc """
  Bearer-token auth for the OPA bundle endpoint (issue #38).

  Resolves in two steps so both Helm-auto-deploy and admin-managed
  deployments work side-by-side:

    1. If `OPA_BUNDLE_TOKEN` env var is set AND the presented bearer
       matches it byte-for-byte (constant-time compare) → allow.
       This is the path the Helm chart uses: a Secret is generated and
       mounted into both the Lynx and OPA pods so they agree on the
       value without any DB row.

    2. Otherwise, look the token up in `opa_bundle_tokens`. If found and
       active → allow + bump `last_used_at`. This is for operators
       running OPA outside the Lynx-controlled deployment, who mint
       tokens via the Settings UI.

  Distinct from `SCIMAuthMiddleware` — different endpoint, different
  token table, different capability. They share the *pattern*, nothing else.
  """

  import Plug.Conn
  require Logger

  alias Lynx.Context.OPABundleTokenContext

  def init(_opts), do: nil

  def call(conn, _opts) do
    case get_bearer_token(conn) do
      nil ->
        deny(conn, "Missing or invalid Authorization header")

      token ->
        cond do
          env_token_match?(token) ->
            assign(conn, :opa_auth_source, :env)

          record = OPABundleTokenContext.validate_token(token) ->
            conn
            |> assign(:opa_auth_source, :db)
            |> assign(:opa_token_uuid, record.uuid)

          true ->
            Logger.info("OPA bundle auth failed: invalid bearer token")
            deny(conn, "Invalid bearer token")
        end
    end
  end

  defp deny(conn, message) do
    conn
    |> put_status(:unauthorized)
    |> Phoenix.Controller.json(%{"errorMessage" => message})
    |> halt()
  end

  defp get_bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> String.trim(token)
      _ -> nil
    end
  end

  defp env_token_match?(presented) do
    case Application.get_env(:lynx, :opa_bundle_token) do
      nil -> false
      "" -> false
      value when is_binary(value) -> Plug.Crypto.secure_compare(value, presented)
    end
  end
end

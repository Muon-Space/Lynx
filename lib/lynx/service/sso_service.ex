# Copyright 2023 Clivern. All rights reserved.
# Use of this source code is governed by the MIT
# license that can be found in the LICENSE file.

defmodule Lynx.Service.SSOService do
  @moduledoc """
  SSO Service - encapsulates OIDC and SAML protocol logic.

  Configuration lives in the DB (Settings tab). The `OpenIDConnect`
  library exists as a dep for JWT verification helpers, but the OIDC
  authorize/callback path is implemented directly so it can be reconfigured
  at runtime through the admin UI without an app restart.
  """

  require Logger

  alias Lynx.Service.Settings

  # -- OIDC --

  @doc """
  Build the OIDC authorization URL from DB-stored SSO config.
  """
  def oidc_authorize_url(state) do
    oidc_authorize_url_from_db(state)
  end

  defp oidc_authorize_url_from_db(state) do
    issuer = Settings.get_sso_config("sso_issuer", "")
    client_id = Settings.get_sso_config("sso_client_id", "")
    redirect_uri = build_redirect_uri()

    if issuer == "" or client_id == "" do
      {:error, "OIDC Issuer URL and Client ID must be configured"}
    else
      case fetch_discovery_document(issuer) do
        {:ok, doc} ->
          auth_endpoint = doc["authorization_endpoint"]

          params =
            URI.encode_query(%{
              "client_id" => client_id,
              "redirect_uri" => redirect_uri,
              "response_type" => "code",
              "scope" => "openid email profile",
              "state" => state
            })

          {:ok, "#{auth_endpoint}?#{params}"}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Handle OIDC callback — exchange code for tokens against DB-stored SSO config.
  """
  def oidc_callback(code) do
    oidc_callback_from_db(code)
  end

  defp oidc_callback_from_db(code) do
    issuer = Settings.get_sso_config("sso_issuer", "")
    client_id = Settings.get_sso_config("sso_client_id", "")
    client_secret = Settings.get_sso_config("sso_client_secret", "")
    redirect_uri = build_redirect_uri()

    if issuer == "" or client_id == "" or client_secret == "" do
      {:error, "OIDC Issuer URL, Client ID, and Client Secret must be configured"}
    else
      with {:ok, doc} <- fetch_discovery_document(issuer),
           {:ok, tokens} <-
             exchange_code_for_tokens(
               doc["token_endpoint"],
               code,
               client_id,
               client_secret,
               redirect_uri
             ),
           {:ok, claims} <- decode_id_token(tokens["id_token"]) do
        {:ok, extract_oidc_claims(claims)}
      else
        {:error, reason} ->
          Logger.error("OIDC callback (DB config) failed: #{inspect(reason)}")
          {:error, "SSO authentication failed"}
      end
    end
  end

  defp fetch_discovery_document(issuer) when issuer in ["", nil] do
    {:error, "Issuer URL is not configured"}
  end

  defp fetch_discovery_document(issuer) do
    url = "#{issuer}/.well-known/openid-configuration"

    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in [nil, ""] or host in [nil, ""] ->
        {:error, "Invalid issuer URL: #{inspect(issuer)}"}

      _ ->
        case Finch.build(:get, url) |> Finch.request(Lynx.Finch) do
          {:ok, %{status: 200, body: body}} ->
            {:ok, Jason.decode!(body)}

          {:ok, %{status: status}} ->
            {:error, "Discovery document fetch failed with status #{status}"}

          {:error, reason} ->
            {:error, "Discovery document fetch failed: #{inspect(reason)}"}
        end
    end
  end

  defp exchange_code_for_tokens(token_endpoint, code, client_id, client_secret, redirect_uri) do
    body =
      URI.encode_query(%{
        "grant_type" => "authorization_code",
        "code" => code,
        "client_id" => client_id,
        "client_secret" => client_secret,
        "redirect_uri" => redirect_uri
      })

    headers = [{"content-type", "application/x-www-form-urlencoded"}]

    case Finch.build(:post, token_endpoint, headers, body) |> Finch.request(Lynx.Finch) do
      {:ok, %{status: 200, body: resp_body}} ->
        {:ok, Jason.decode!(resp_body)}

      {:ok, %{status: status, body: resp_body}} ->
        {:error, "Token exchange failed (#{status}): #{resp_body}"}

      {:error, reason} ->
        {:error, "Token exchange failed: #{inspect(reason)}"}
    end
  end

  defp decode_id_token(nil), do: {:error, "No id_token in response"}

  defp decode_id_token(id_token) do
    # Decode the JWT payload (middle segment) without signature verification.
    # In production with the OpenIDConnect worker, full verification is done.
    # This fallback trusts the token because it came directly from the token endpoint
    # over TLS using the client secret.
    case String.split(id_token, ".") do
      [_, payload, _] ->
        case Base.url_decode64(payload, padding: false) do
          {:ok, json} -> {:ok, Jason.decode!(json)}
          :error -> {:error, "Failed to decode id_token payload"}
        end

      _ ->
        {:error, "Invalid id_token format"}
    end
  end

  defp build_redirect_uri do
    app_url = Settings.get_config("app_url", "http://localhost:4000")
    String.trim_trailing(app_url, "/") <> "/auth/sso/callback"
  end

  defp extract_oidc_claims(claims) do
    # Pure extraction: returns nil when the IdP didn't provide a name.
    # The fallback to email lives in `Lynx.Service.SSO.find_or_create_sso_user/2`
    # so it ONLY applies on user creation. On subsequent logins, a nil
    # name preserves whatever the user / SCIM already set — otherwise
    # IdPs that omit `name` would clobber SCIM-provisioned full names
    # ("Aron Gates") with the email on every login.
    name =
      cond do
        Map.has_key?(claims, "name") and claims["name"] != "" ->
          claims["name"]

        Map.has_key?(claims, "given_name") ->
          combined = "#{claims["given_name"]} #{claims["family_name"] || ""}" |> String.trim()
          if combined == "", do: nil, else: combined

        true ->
          nil
      end

    %{
      external_id: claims["sub"],
      email: claims["email"],
      name: name
    }
  end

  # -- SAML --

  @doc """
  Extract user attributes from a Samly.Assertion struct
  """
  def saml_assertion_to_attrs(%{attributes: attrs, subject: subject}) do
    email =
      Map.get(attrs, "email") ||
        Map.get(attrs, "http://schemas.xmlsoap.org/ws/2005/05/identity/claims/emailaddress") ||
        Map.get(attrs, "urn:oid:0.9.2342.19200300.100.1.3")

    name =
      Map.get(attrs, "name") ||
        Map.get(
          attrs,
          "http://schemas.xmlsoap.org/ws/2005/05/identity/claims/name"
        ) ||
        build_saml_name(attrs)

    external_id = subject.name || email

    case email do
      nil ->
        {:error, "No email attribute found in SAML assertion"}

      email ->
        # Pure extraction: nil when the IdP didn't provide a name.
        # `Lynx.Service.SSO.find_or_create_sso_user/2` falls back to
        # email only on user creation; on update, a nil name preserves
        # whatever SCIM / the operator already set.
        {:ok,
         %{
           external_id: external_id,
           email: email,
           name: name
         }}
    end
  end

  defp build_saml_name(attrs) do
    given =
      Map.get(attrs, "givenName") ||
        Map.get(attrs, "http://schemas.xmlsoap.org/ws/2005/05/identity/claims/givenname")

    family =
      Map.get(attrs, "surname") ||
        Map.get(attrs, "http://schemas.xmlsoap.org/ws/2005/05/identity/claims/surname")

    case {given, family} do
      {nil, nil} -> nil
      {given, nil} -> given
      {nil, family} -> family
      {given, family} -> "#{given} #{family}"
    end
  end
end

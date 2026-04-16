# Copyright 2023 Clivern. All rights reserved.
# Use of this source code is governed by the MIT
# license that can be found in the LICENSE file.

defmodule Lynx.Service.SSOService do
  @moduledoc """
  SSO Service - encapsulates OIDC and SAML protocol logic
  """

  require Logger

  # -- OIDC --

  @doc """
  Build the OIDC authorization URL
  """
  def oidc_authorize_url(state) do
    case OpenIDConnect.authorization_uri(:lynx, state) do
      {:ok, uri} -> {:ok, uri}
      {:error, reason} -> {:error, "Failed to build authorization URL: #{inspect(reason)}"}
    end
  end

  @doc """
  Handle OIDC callback - exchange code for tokens and extract claims
  """
  def oidc_callback(code) do
    with {:ok, tokens} <- OpenIDConnect.fetch_tokens(:lynx, %{code: code}),
         {:ok, claims} <- OpenIDConnect.verify(:lynx, tokens["id_token"]) do
      {:ok, extract_oidc_claims(claims)}
    else
      {:error, reason} ->
        Logger.error("OIDC callback failed: #{inspect(reason)}")
        {:error, "SSO authentication failed"}
    end
  end

  defp extract_oidc_claims(claims) do
    name =
      cond do
        Map.has_key?(claims, "name") and claims["name"] != "" ->
          claims["name"]

        Map.has_key?(claims, "given_name") ->
          "#{claims["given_name"]} #{claims["family_name"] || ""}" |> String.trim()

        true ->
          claims["email"] || "Unknown"
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
        {:ok,
         %{
           external_id: external_id,
           email: email,
           name: name || email
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

# Copyright 2023 Clivern. All rights reserved.
# Use of this source code is governed by the MIT
# license that can be found in the LICENSE file.

defmodule Lynx.Service.JWTService do
  @moduledoc """
  JWT Service - validates JWT tokens against OIDC provider JWKS.
  Caches discovery documents and JWKS keys in ETS.
  """

  require Logger

  @cache_table :lynx_jwks_cache
  @cache_ttl_seconds 3600

  def init_cache do
    if :ets.whereis(@cache_table) == :undefined do
      :ets.new(@cache_table, [:named_table, :set, :public, read_concurrency: true])
    end
  end

  @doc """
  Validate a JWT token against an OIDC provider's JWKS.
  Returns {:ok, claims} or {:error, reason}.
  """
  def validate_token(discovery_url, jwt, expected_audience \\ nil) do
    init_cache()

    with {:ok, jwks} <- get_jwks(discovery_url),
         {:ok, claims} <- verify_and_decode(jwt, jwks),
         :ok <- check_expiry(claims),
         :ok <- check_audience(claims, expected_audience) do
      {:ok, claims}
    end
  end

  defp get_jwks(discovery_url) do
    case get_cached("jwks:#{discovery_url}") do
      {:ok, jwks} ->
        {:ok, jwks}

      :miss ->
        with {:ok, doc} <- fetch_discovery(discovery_url),
             jwks_uri when is_binary(jwks_uri) <- doc["jwks_uri"],
             {:ok, jwks} <- fetch_jwks(jwks_uri) do
          put_cached("jwks:#{discovery_url}", jwks)
          {:ok, jwks}
        else
          nil -> {:error, "No jwks_uri in discovery document"}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp fetch_discovery(discovery_url) do
    url =
      if String.contains?(discovery_url, ".well-known") do
        discovery_url
      else
        String.trim_trailing(discovery_url, "/") <> "/.well-known/openid-configuration"
      end

    case Finch.build(:get, url) |> Finch.request(Lynx.Finch) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, Jason.decode!(body)}

      {:ok, %{status: status}} ->
        {:error, "Discovery fetch failed (HTTP #{status})"}

      {:error, reason} ->
        {:error, "Discovery fetch failed: #{inspect(reason)}"}
    end
  end

  defp fetch_jwks(jwks_uri) do
    case Finch.build(:get, jwks_uri) |> Finch.request(Lynx.Finch) do
      {:ok, %{status: 200, body: body}} ->
        jwks = Jason.decode!(body)
        {:ok, jwks}

      {:ok, %{status: status}} ->
        {:error, "JWKS fetch failed (HTTP #{status})"}

      {:error, reason} ->
        {:error, "JWKS fetch failed: #{inspect(reason)}"}
    end
  end

  defp verify_and_decode(jwt, jwks) do
    keys = jwks["keys"] || []

    # Try each key until one works
    result =
      Enum.find_value(keys, {:error, "No matching key found"}, fn key_data ->
        try do
          jwk = JOSE.JWK.from_map(key_data)

          case JOSE.JWT.verify_strict(jwk, [key_data["alg"] || "RS256"], jwt) do
            {true, %JOSE.JWT{fields: claims}, _} ->
              {:ok, claims}

            {false, _, _} ->
              nil
          end
        rescue
          _ -> nil
        end
      end)

    result
  end

  defp check_expiry(claims) do
    case claims["exp"] do
      nil ->
        :ok

      exp when is_number(exp) ->
        if exp > :os.system_time(:second) do
          :ok
        else
          {:error, "Token expired"}
        end

      _ ->
        :ok
    end
  end

  defp check_audience(_claims, nil), do: :ok
  defp check_audience(_claims, ""), do: :ok

  defp check_audience(claims, expected) do
    aud = claims["aud"]

    cond do
      is_nil(aud) -> :ok
      is_binary(aud) and aud == expected -> :ok
      is_list(aud) and expected in aud -> :ok
      true -> {:error, "Audience mismatch: expected #{expected}, got #{inspect(aud)}"}
    end
  end

  # -- ETS Cache --

  defp get_cached(key) do
    case :ets.lookup(@cache_table, key) do
      [{^key, value, inserted_at}] ->
        if :os.system_time(:second) - inserted_at < @cache_ttl_seconds do
          {:ok, value}
        else
          :ets.delete(@cache_table, key)
          :miss
        end

      [] ->
        :miss
    end
  rescue
    ArgumentError -> :miss
  end

  defp put_cached(key, value) do
    :ets.insert(@cache_table, {key, value, :os.system_time(:second)})
  rescue
    ArgumentError -> :ok
  end
end

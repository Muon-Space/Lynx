# Copyright 2023 Clivern. All rights reserved.
# Use of this source code is governed by the MIT
# license that can be found in the LICENSE file.

defmodule Lynx.Module.SCIMTokenModule do
  @moduledoc """
  SCIM Token Module - generate, validate, list, and revoke SCIM bearer tokens
  """

  alias Lynx.Context.SCIMTokenContext

  @doc """
  Generate a new SCIM token. Returns the plaintext token (shown once to the user).
  """
  def generate_token(description \\ "") do
    token = generate_random_token()

    attrs = %{
      uuid: Ecto.UUID.generate(),
      token: token,
      description: description,
      is_active: true
    }

    case SCIMTokenContext.create_token(attrs) do
      {:ok, record} ->
        {:ok, %{uuid: record.uuid, token: token, description: record.description}}

      {:error, changeset} ->
        messages =
          changeset.errors
          |> Enum.map(fn {field, {message, _options}} -> "#{field}: #{message}" end)

        {:error, Enum.at(messages, 0)}
    end
  end

  @doc """
  Validate a bearer token. Returns true if the token is active.
  Also updates last_used_at.
  """
  def validate_token(token) do
    case SCIMTokenContext.get_active_token(token) do
      nil ->
        false

      record ->
        SCIMTokenContext.touch_last_used(record)
        true
    end
  end

  @doc """
  List all tokens (masks the actual token values)
  """
  def list_tokens() do
    SCIMTokenContext.list_tokens()
    |> Enum.map(fn t ->
      %{
        uuid: t.uuid,
        token_prefix: mask_token(t.token),
        description: t.description,
        is_active: t.is_active,
        last_used_at: t.last_used_at,
        created_at: t.inserted_at
      }
    end)
  end

  @doc """
  Revoke a token by UUID
  """
  def revoke_token(uuid) do
    case SCIMTokenContext.get_token_by_uuid(uuid) do
      nil ->
        {:not_found, "Token not found"}

      token ->
        SCIMTokenContext.revoke_token(token)
        {:ok, "Token revoked"}
    end
  end

  @doc """
  Delete a token by UUID
  """
  def delete_token(uuid) do
    case SCIMTokenContext.get_token_by_uuid(uuid) do
      nil ->
        {:not_found, "Token not found"}

      token ->
        SCIMTokenContext.delete_token(token)
        {:ok, "Token deleted"}
    end
  end

  defp generate_random_token do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end

  defp mask_token(token) when is_binary(token) and byte_size(token) > 8 do
    String.slice(token, 0, 8) <> "..."
  end

  defp mask_token(token), do: token
end

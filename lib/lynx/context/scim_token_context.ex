# Copyright 2023 Clivern. All rights reserved.
# Use of this source code is governed by the MIT
# license that can be found in the LICENSE file.

defmodule Lynx.Context.SCIMTokenContext do
  @moduledoc """
  SCIM Token Context Module
  """

  import Ecto.Query

  alias Lynx.Repo
  alias Lynx.Model.SCIMToken

  @doc """
  Create a new SCIM token
  """
  def create_token(attrs \\ %{}) do
    %SCIMToken{}
    |> SCIMToken.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Get token by UUID
  """
  def get_token_by_uuid(uuid) do
    from(t in SCIMToken, where: t.uuid == ^uuid)
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  Get active token by token value
  """
  def get_active_token(token) do
    from(t in SCIMToken,
      where: t.token == ^token,
      where: t.is_active == true
    )
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  List all tokens (active and inactive) as display maps with masked token
  values. The full token is never returned after creation.
  """
  def list_tokens() do
    list_token_records()
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

  @doc "Raw token records — internal use; prefer `list_tokens/0` for display."
  def list_token_records() do
    from(t in SCIMToken, order_by: [desc: t.inserted_at])
    |> Repo.all()
  end

  @doc """
  List active tokens
  """
  def list_active_tokens() do
    from(t in SCIMToken,
      where: t.is_active == true,
      order_by: [desc: t.inserted_at]
    )
    |> Repo.all()
  end

  @doc """
  Update a token
  """
  def update_token(token, attrs) do
    token
    |> SCIMToken.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Touch last_used_at timestamp
  """
  def touch_last_used(token) do
    update_token(token, %{last_used_at: DateTime.utc_now()})
  end

  @doc """
  Revoke a token (soft-delete)
  """
  def revoke_token(token) do
    update_token(token, %{is_active: false})
  end

  @doc """
  Delete a token (hard-delete)
  """
  def delete_token(token) do
    Repo.delete(token)
  end

  @doc """
  Check if any active tokens exist
  """
  def has_active_tokens?() do
    from(t in SCIMToken,
      select: count(t.id),
      where: t.is_active == true
    )
    |> Repo.one()
    |> Kernel.>(0)
  end

  # -- High-level token operations (was SCIMTokenModule) --

  @doc """
  Generate a new SCIM token. Returns `{:ok, %{uuid, token, description}}`
  with the plaintext token (shown once to the caller).
  """
  def generate_token(description \\ "") do
    token = generate_random_token()

    attrs = %{
      uuid: Ecto.UUID.generate(),
      token: token,
      description: description,
      is_active: true
    }

    case create_token(attrs) do
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
  Validate a bearer token. Returns true if the token is active. Updates
  `last_used_at` as a side effect.
  """
  def validate_token(token) do
    case get_active_token(token) do
      nil ->
        false

      record ->
        touch_last_used(record)
        true
    end
  end

  @doc "Revoke a token by UUID. Returns `{:ok, msg}` or `{:not_found, msg}`."
  def revoke_token_by_uuid(uuid) do
    case get_token_by_uuid(uuid) do
      nil -> {:not_found, "Token not found"}
      token -> revoke_token(token) && {:ok, "Token revoked"}
    end
  end

  @doc "Delete a token by UUID. Returns `{:ok, msg}` or `{:not_found, msg}`."
  def delete_token_by_uuid(uuid) do
    case get_token_by_uuid(uuid) do
      nil -> {:not_found, "Token not found"}
      token -> delete_token(token) && {:ok, "Token deleted"}
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

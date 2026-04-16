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
  List all tokens (active and inactive)
  """
  def list_tokens() do
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
end

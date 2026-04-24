# Copyright 2023 Clivern. All rights reserved.
# Use of this source code is governed by the MIT
# license that can be found in the LICENSE file.

defmodule LynxWeb.UserJSON do
  # Render users list
  def render("list.json", %{users: users, metadata: metadata}) do
    %{
      users: Enum.map(users, &render_user/1),
      _metadata: %{
        limit: metadata.limit,
        offset: metadata.offset,
        totalCount: metadata.totalCount
      }
    }
  end

  # Render user
  def render("index.json", %{user: user}) do
    render_user(user)
  end

  # Render errors
  def render("error.json", %{message: message}) do
    %{errorMessage: message}
  end

  # Format user. `authProviders` is sourced from the linked
  # `user_identities` rows — a user can be linked to multiple IdPs
  # (e.g. local password + SCIM) so the field is now a list. The old
  # singular `authProvider` field is retained for backward compat,
  # populated with the first non-local provider if any.
  defp render_user(user) do
    providers =
      Lynx.Context.UserIdentityContext.list_identities_for_user(user.id)
      |> Enum.map(& &1.provider)

    %{
      id: user.uuid,
      email: user.email,
      name: user.name,
      role: user.role,
      isActive: user.is_active,
      authProviders: providers,
      authProvider: Enum.find(providers, &(&1 != "local")) || List.first(providers) || "local",
      createdAt: user.inserted_at,
      updatedAt: user.updated_at
    }
  end
end

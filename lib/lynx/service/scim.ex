# Copyright 2023 Clivern. All rights reserved.
# Use of this source code is governed by the MIT
# license that can be found in the LICENSE file.

defmodule Lynx.Service.SCIM do
  @moduledoc """
  SCIM 2.0 Module - orchestrates SCIM user and group operations
  """

  alias Lynx.Context.UserContext
  alias Lynx.Context.TeamContext
  alias Lynx.Context.UserContext
  alias Lynx.Context.TeamContext
  alias Lynx.Service.SlugService

  # -- Users --

  @doc """
  List SCIM users with optional filtering
  """
  def list_users(filter, start_index, count) do
    offset = max(start_index - 1, 0)

    users =
      case filter do
        nil ->
          UserContext.get_active_users(offset, count)

        %{attr: "userName", value: value} ->
          case UserContext.get_user_by_email(value) do
            nil -> []
            user -> if user.is_active, do: [user], else: []
          end

        _ ->
          UserContext.get_active_users(offset, count)
      end

    total = UserContext.count_active_users()
    {users, total}
  end

  @doc """
  Get a SCIM user by UUID
  """
  def get_user(uuid) do
    case UserContext.get_user_by_uuid(uuid) do
      nil -> {:not_found, "User not found"}
      user -> {:ok, user}
    end
  end

  @doc """
  Create a SCIM user (idempotent by external_id)
  """
  def create_user(attrs) do
    external_id = attrs[:external_id]

    if external_id do
      case UserContext.get_user_by_external_id(external_id) do
        nil -> do_create_user(attrs)
        existing -> update_user(existing.uuid, attrs)
      end
    else
      case UserContext.get_user_by_email(attrs[:email]) do
        nil ->
          do_create_user(attrs)

        existing ->
          UserContext.update_user(existing, %{
            external_id: external_id,
            auth_provider: "scim"
          })
      end
    end
  end

  defp do_create_user(attrs) do
    UserContext.create_sso_user(%{
      email: attrs[:email],
      name: attrs[:name],
      auth_provider: "scim",
      external_id: attrs[:external_id],
      is_active: Map.get(attrs, :is_active, true)
    })
  end

  @doc """
  Replace a SCIM user (PUT)
  """
  def update_user(uuid, attrs) do
    case UserContext.get_user_by_uuid(uuid) do
      nil ->
        {:not_found, "User not found"}

      user ->
        new_attrs = %{
          email: attrs[:email] || user.email,
          name: attrs[:name] || user.name,
          external_id: attrs[:external_id] || user.external_id,
          is_active: Map.get(attrs, :is_active, user.is_active)
        }

        UserContext.update_user(user, new_attrs)
    end
  end

  @doc """
  Patch a SCIM user (partial update)
  """
  def patch_user(uuid, operations) do
    case UserContext.get_user_by_uuid(uuid) do
      nil ->
        {:not_found, "User not found"}

      user ->
        attrs = apply_user_patch_operations(user, operations)
        UserContext.update_user(user, attrs)
    end
  end

  defp apply_user_patch_operations(_user, operations) do
    Enum.reduce(operations, %{}, fn op, acc ->
      # RFC 7644 §3.5.2: the `op` value MUST be matched case-insensitively
      # ("add", "remove", "replace"). Okta sends "Replace" with a capital R
      # by default; case-sensitive matching silently no-ops the request,
      # so a user reactivated in Okta stays deactivated in Lynx.
      case normalize_op(op) do
        %{"op" => "replace", "value" => values} when is_map(values) ->
          Map.merge(acc, map_scim_user_values(values))

        %{"op" => "replace", "path" => path, "value" => value} ->
          Map.merge(acc, map_scim_user_path(path, value))

        _ ->
          acc
      end
    end)
  end

  defp normalize_op(%{"op" => op} = m) when is_binary(op),
    do: Map.put(m, "op", String.downcase(op))

  defp normalize_op(m), do: m

  defp map_scim_user_values(values) do
    result = %{}

    result =
      if Map.has_key?(values, "active"),
        do: Map.put(result, :is_active, values["active"]),
        else: result

    result =
      if Map.has_key?(values, "userName"),
        do: Map.put(result, :email, values["userName"]),
        else: result

    result =
      if Map.has_key?(values, "name") and is_map(values["name"]),
        do: Map.put(result, :name, format_scim_name(values["name"])),
        else: result

    result
  end

  defp map_scim_user_path("active", value), do: %{is_active: value}
  defp map_scim_user_path("userName", value), do: %{email: value}

  defp map_scim_user_path("name.formatted", value), do: %{name: value}

  defp map_scim_user_path("name", value) when is_map(value),
    do: %{name: format_scim_name(value)}

  defp map_scim_user_path(_, _), do: %{}

  @doc """
  Delete (deactivate) a SCIM user.

  Flips `is_active: false` AND deletes every active `user_sessions`
  row for the user. Without the session purge, a deactivated user's
  cookie remains a valid session bearer; once SCIM reactivates them,
  those stale sessions become live again. The session purge plus the
  `is_active` check in `LiveAuth` (and `LoginLive` mount) ensure the
  user is actually logged out across all browsers + devices.
  """
  def delete_user(uuid) do
    case UserContext.get_user_by_uuid(uuid) do
      nil ->
        {:not_found, "User not found"}

      user ->
        UserContext.update_user(user, %{is_active: false})
        UserContext.delete_user_sessions(user.id)
        :ok
    end
  end

  # -- Groups --

  @doc """
  List SCIM groups with optional filtering
  """
  def list_groups(filter, start_index, count) do
    offset = max(start_index - 1, 0)

    teams =
      case filter do
        nil ->
          TeamContext.get_teams(offset, count)

        %{attr: "displayName", value: value} ->
          slug = SlugService.create(value)

          case TeamContext.get_team_by_slug(slug) do
            nil -> []
            team -> [team]
          end

        _ ->
          TeamContext.get_teams(offset, count)
      end

    total = TeamContext.count_teams()
    {teams, total}
  end

  @doc """
  Get a SCIM group by UUID
  """
  def get_group(uuid) do
    case TeamContext.get_team_by_uuid(uuid) do
      nil -> {:not_found, "Group not found"}
      team -> {:ok, team}
    end
  end

  @doc """
  Create a SCIM group (idempotent by external_id)
  """
  def create_group(attrs) do
    external_id = attrs[:external_id]

    if external_id do
      case TeamContext.get_team_by_external_id(external_id) do
        nil -> do_create_group(attrs)
        existing -> update_group(existing.uuid, attrs)
      end
    else
      do_create_group(attrs)
    end
  end

  defp do_create_group(attrs) do
    display_name = attrs[:display_name]
    slug = SlugService.create(display_name)

    team =
      TeamContext.new_team(%{
        name: display_name,
        slug: slug,
        description: attrs[:description] || display_name,
        external_id: attrs[:external_id]
      })

    case TeamContext.create_team(team) do
      {:ok, team} ->
        if attrs[:members] do
          sync_group_members(team.id, attrs[:members])
        end

        {:ok, team}

      {:error, changeset} ->
        messages =
          changeset.errors
          |> Enum.map(fn {field, {message, _options}} -> "#{field}: #{message}" end)

        {:error, Enum.at(messages, 0)}
    end
  end

  @doc """
  Replace a SCIM group (PUT)
  """
  def update_group(uuid, attrs) do
    case TeamContext.get_team_by_uuid(uuid) do
      nil ->
        {:not_found, "Group not found"}

      team ->
        display_name = attrs[:display_name] || team.name

        new_attrs = %{
          name: display_name,
          slug: SlugService.create(display_name),
          description: attrs[:description] || team.description,
          external_id: attrs[:external_id] || team.external_id
        }

        case TeamContext.update_team(team, new_attrs) do
          {:ok, updated_team} ->
            if attrs[:members] do
              sync_group_members(updated_team.id, attrs[:members])
            end

            {:ok, updated_team}

          {:error, changeset} ->
            messages =
              changeset.errors
              |> Enum.map(fn {field, {message, _options}} -> "#{field}: #{message}" end)

            {:error, Enum.at(messages, 0)}
        end
    end
  end

  @doc """
  Patch a SCIM group (partial update, including membership changes)
  """
  def patch_group(uuid, operations) do
    case TeamContext.get_team_by_uuid(uuid) do
      nil ->
        {:not_found, "Group not found"}

      team ->
        Enum.each(operations, fn op ->
          # Same case-insensitive op normalization as user patches —
          # see normalize_op/1 + RFC 7644 §3.5.2.
          apply_group_patch_operation(team, normalize_op(op))
        end)

        {:ok, TeamContext.get_team_by_uuid(uuid)}
    end
  end

  defp apply_group_patch_operation(team, %{"op" => "add", "path" => "members", "value" => members})
       when is_list(members) do
    Enum.each(members, fn member ->
      user_uuid = member["value"]

      case UserContext.get_user_id_with_uuid(user_uuid) do
        nil -> :skip
        user_id -> UserContext.add_user_to_team(user_id, team.id)
      end
    end)
  end

  defp apply_group_patch_operation(team, %{
         "op" => "remove",
         "path" => "members[value eq \"" <> rest
       }) do
    user_uuid = String.trim_trailing(rest, "\"]")

    case UserContext.get_user_id_with_uuid(user_uuid) do
      nil -> :skip
      user_id -> UserContext.remove_user_from_team(user_id, team.id)
    end
  end

  defp apply_group_patch_operation(team, %{
         "op" => "replace",
         "path" => "members",
         "value" => members
       })
       when is_list(members) do
    member_uuids = Enum.map(members, fn m -> m["value"] end)
    TeamContext.sync_team_members(team.id, member_uuids)
  end

  defp apply_group_patch_operation(team, %{"op" => "replace", "value" => values})
       when is_map(values) do
    if Map.has_key?(values, "displayName") do
      display_name = values["displayName"]

      TeamContext.update_team(team, %{
        name: display_name,
        slug: SlugService.create(display_name)
      })
    end
  end

  defp apply_group_patch_operation(_team, _op), do: :skip

  @doc """
  Delete a SCIM group
  """
  def delete_group(uuid) do
    case TeamContext.get_team_by_uuid(uuid) do
      nil ->
        {:not_found, "Group not found"}

      team ->
        TeamContext.delete_team(team)
        :ok
    end
  end

  # -- Helpers --

  defp sync_group_members(team_id, members) when is_list(members) do
    member_uuids = Enum.map(members, fn m -> m["value"] end)
    TeamContext.sync_team_members(team_id, member_uuids)
  end

  defp sync_group_members(_team_id, _), do: :ok

  @doc """
  Format a SCIM name object to a display name string
  """
  def format_scim_name(%{"formatted" => name}) when is_binary(name) and name != "", do: name

  def format_scim_name(%{"givenName" => given, "familyName" => family})
      when is_binary(given) and is_binary(family),
      do: "#{given} #{family}" |> String.trim()

  def format_scim_name(%{"givenName" => given}) when is_binary(given), do: given
  def format_scim_name(%{"familyName" => family}) when is_binary(family), do: family
  def format_scim_name(_), do: "Unknown"
end

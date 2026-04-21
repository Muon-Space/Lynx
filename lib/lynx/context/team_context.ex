# Copyright 2023 Clivern. All rights reserved.
# Use of this source code is governed by the MIT
# license that can be found in the LICENSE file.

defmodule Lynx.Context.TeamContext do
  @moduledoc """
  Team Context Module
  """

  import Ecto.Query

  alias Lynx.Repo
  alias Lynx.Model.{Team, TeamMeta}
  alias Lynx.Context.UserContext

  @doc """
  Get a new team
  """
  def new_team(attrs \\ %{}) do
    %{
      name: attrs.name,
      description: attrs.description,
      slug: attrs.slug,
      external_id: Map.get(attrs, :external_id),
      uuid: Map.get(attrs, :uuid, Ecto.UUID.generate())
    }
  end

  @doc """
  Get a team meta
  """
  def new_meta(meta \\ %{}) do
    %{
      key: meta.key,
      value: meta.value,
      team_id: meta.team_id
    }
  end

  @doc """
  Create a new team
  """
  def create_team(attrs \\ %{}) do
    %Team{}
    |> Team.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Get Team ID with UUID
  """
  def get_team_id_with_uuid(uuid) do
    case get_team_by_uuid(uuid) do
      nil ->
        nil

      team ->
        team.id
    end
  end

  @doc """
  Get Team UUID with ID
  """
  def get_team_uuid_with_id(id) do
    case get_team_by_id(id) do
      nil ->
        nil

      team ->
        team.uuid
    end
  end

  @doc """
  Retrieve a team by ID
  """
  def get_team_by_id(id) do
    Repo.get(Team, id)
  end

  @doc """
  Validate Team ID
  """
  def validate_team_id(id) do
    case get_team_by_id(id) do
      nil ->
        false

      _ ->
        true
    end
  end

  @doc """
  Validate Team UUID
  """
  def validate_team_uuid(uuid) do
    case get_team_by_uuid(uuid) do
      nil ->
        false

      _ ->
        true
    end
  end

  @doc """
  Get team by uuid
  """
  def get_team_by_uuid(uuid) do
    from(
      t in Team,
      where: t.uuid == ^uuid
    )
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  Get team by slug
  """
  def get_team_by_slug(slug) do
    from(
      t in Team,
      where: t.slug == ^slug
    )
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  Get team by external ID
  """
  def get_team_by_external_id(external_id) do
    from(
      t in Team,
      where: t.external_id == ^external_id
    )
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  Update a team
  """
  def update_team(team, attrs) do
    team
    |> Team.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Delete a team
  """
  def delete_team(team) do
    Repo.delete(team)
  end

  @doc """
  Search teams by name or slug substring (case-insensitive). For autocomplete
  dropdowns; returns at most `limit` matches ordered by name.
  """
  def search_teams(query, limit \\ 25) when is_binary(query) do
    pattern = "%#{String.replace(query, ~w(\\ % _), fn c -> "\\" <> c end)}%"

    from(t in Team,
      where: ilike(t.name, ^pattern) or ilike(t.slug, ^pattern),
      order_by: [asc: t.name],
      limit: ^limit
    )
    |> Repo.all()
  end

  @doc """
  Search teams that `user_id` is a member of. For non-super users in
  autocomplete inputs.
  """
  def search_user_teams(user_id, query, limit \\ 25) when is_binary(query) do
    pattern = "%#{String.replace(query, ~w(\\ % _), fn c -> "\\" <> c end)}%"

    from(t in Team,
      join: ut in Lynx.Model.UserTeam,
      on: ut.team_id == t.id,
      where: ut.user_id == ^user_id,
      where: ilike(t.name, ^pattern) or ilike(t.slug, ^pattern),
      order_by: [asc: t.name],
      limit: ^limit
    )
    |> Repo.all()
  end

  @doc """
  Retrieve teams (paginated). Caller is responsible for capping `limit` —
  see `LynxWeb.Limits` for the platform-wide caps and `search_teams/2` for
  autocomplete-style lookups.
  """
  def get_teams(offset, limit) do
    from(t in Team,
      order_by: [desc: t.inserted_at],
      limit: ^limit,
      offset: ^offset
    )
    |> Repo.all()
  end

  @doc """
  Retrieve teams
  """
  def get_teams(teams_ids, offset, limit) do
    from(t in Team,
      order_by: [desc: t.inserted_at],
      where: t.id in ^teams_ids,
      limit: ^limit,
      offset: ^offset
    )
    |> Repo.all()
  end

  @doc """
  Count all teams
  """
  def count_teams() do
    from(t in Team,
      select: count(t.id)
    )
    |> Repo.one()
  end

  @doc """
  Create a new team meta
  """
  def create_team_meta(attrs \\ %{}) do
    %TeamMeta{}
    |> TeamMeta.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Retrieve a team meta by id
  """
  def get_team_meta_by_id(id) do
    Repo.get(TeamMeta, id)
  end

  @doc """
  Update a team meta
  """
  def update_team_meta(team_meta, attrs) do
    team_meta
    |> TeamMeta.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Delete a team meta
  """
  def delete_team_meta(team_meta) do
    Repo.delete(team_meta)
  end

  @doc """
  Get team meta by team id and key
  """
  def get_team_meta_by_id_key(team_id, meta_key) do
    from(
      t in TeamMeta,
      where: t.team_id == ^team_id,
      where: t.key == ^meta_key
    )
    |> Repo.one()
  end

  @doc """
  Get team metas
  """
  def get_team_metas(team_id) do
    from(
      t in TeamMeta,
      where: t.team_id == ^team_id
    )
    |> Repo.all()
  end

  # -- Tagged-tuple lookups (Phoenix `fetch_*` convention) --

  def fetch_team_by_id(id) do
    case get_team_by_id(id) do
      nil -> {:not_found, "Team with ID #{id} not found"}
      team -> {:ok, team}
    end
  end

  def fetch_team_by_uuid(uuid) do
    case get_team_by_uuid(uuid) do
      nil -> {:not_found, "Team with ID #{uuid} not found"}
      team -> {:ok, team}
    end
  end

  # -- High-level orchestration (was TeamModule) --

  @doc """
  Create a team from a data map. Returns `{:ok, team}` or `{:error, message}`.
  """
  def create_team_from_data(data \\ %{}) do
    team =
      new_team(%{
        name: data[:name],
        slug: data[:slug],
        description: data[:description]
      })

    case create_team(team) do
      {:ok, team} ->
        {:ok, team}

      {:error, changeset} ->
        messages =
          changeset.errors
          |> Enum.map(fn {field, {message, _options}} -> "#{field}: #{message}" end)

        {:error, Enum.at(messages, 0)}
    end
  end

  @doc "Sync team membership: future_members are user UUIDs."
  def sync_team_members(team_id, future_members \\ []) do
    current_members =
      UserContext.get_team_users(team_id)
      |> Enum.map(& &1.id)

    future_members_ids =
      future_members
      |> Enum.map(&UserContext.get_user_id_with_uuid/1)
      |> Enum.reject(&is_nil/1)

    for member <- current_members, member not in future_members_ids do
      UserContext.remove_user_from_team(member, team_id)
    end

    for member <- future_members_ids, member not in current_members do
      UserContext.add_user_to_team(member, team_id)
    end
  end

  @doc "Get team members (UUIDs)."
  def get_team_members(team_id) do
    UserContext.get_team_users(team_id) |> Enum.map(& &1.uuid)
  end

  @doc "Get team members as `[{name, uuid}, ...]` — combobox-friendly."
  def get_team_member_options(team_id) do
    import Ecto.Query

    from(u in Lynx.Model.User,
      join: ut in Lynx.Model.UserTeam,
      on: ut.user_id == u.id,
      where: ut.team_id == ^team_id,
      order_by: [asc: u.name],
      select: {u.name, u.uuid}
    )
    |> Repo.all()
  end

  @doc "Update a team from a data map (UUID-keyed)."
  def update_team_from_data(data \\ %{}) do
    case get_team_by_uuid(data[:uuid]) do
      nil ->
        {:not_found, "Team with ID #{data[:uuid]} not found"}

      team ->
        new_team = %{
          name: data[:name] || team.name,
          description: data[:description] || team.description,
          slug: data[:slug] || team.slug
        }

        case update_team(team, new_team) do
          {:ok, team} ->
            {:ok, team}

          {:error, changeset} ->
            messages =
              changeset.errors
              |> Enum.map(fn {field, {message, _options}} -> "#{field}: #{message}" end)

            {:error, Enum.at(messages, 0)}
        end
    end
  end

  def is_slug_used(slug) do
    case get_team_by_slug(slug) do
      nil -> false
      _ -> true
    end
  end

  @doc "Paginated user-scoped teams."
  def get_user_teams_paged(user_id, offset, limit) do
    teams_ids =
      user_id
      |> UserContext.get_user_teams()
      |> Enum.map(& &1.id)

    get_teams(teams_ids, offset, limit)
  end

  def delete_team_by_uuid(uuid) do
    case get_team_by_uuid(uuid) do
      nil ->
        {:not_found, "Team with ID #{uuid} not found"}

      team ->
        delete_team(team)
        {:ok, "Team with ID #{uuid} deleted successfully"}
    end
  end

  # -- Pass-through delegations to UserContext (so callers can use TeamContext
  # for everything team-related without knowing the data lives in UserContext) --

  defdelegate count_user_teams(user_id), to: UserContext
  defdelegate get_user_teams(user_id), to: UserContext
end

# Copyright 2023 Clivern. All rights reserved.
# Use of this source code is governed by the MIT
# license that can be found in the LICENSE file.

defmodule Lynx.Context.UserContext do
  @moduledoc """
  User Context Module
  """

  import Ecto.Query

  alias Lynx.Repo
  alias Lynx.Service.{AuthService, Settings}
  alias Lynx.Model.{Team, UserMeta, User, UserSession, UserTeam}

  @doc """
  Creates a new user with the provided attributes
  """
  def new_user(attrs \\ %{}) do
    # `auth_provider` + `external_id` columns are deprecated — they
    # live in `user_identities` now. The columns stay on `users` for
    # one release as a rollback safety net but no new writes go there.
    %{
      email: attrs.email,
      name: attrs.name,
      password_hash: attrs.password_hash,
      verified: attrs.verified,
      last_seen: attrs.last_seen,
      role: attrs.role,
      api_key: Map.get(attrs, :api_key),
      is_active: Map.get(attrs, :is_active, true),
      uuid: Map.get(attrs, :uuid, Ecto.UUID.generate())
    }
  end

  @doc """
  Creates a new user meta with the provided attributes
  """
  def new_meta(meta \\ %{}) do
    %{
      key: meta.key,
      value: meta.value,
      user_id: meta.user_id
    }
  end

  @doc """
  Creates a new user session with the provided attributes
  """
  def new_session(session \\ %{}) do
    %{
      value: session.value,
      expire_at: session.expire_at,
      user_id: session.user_id,
      auth_method: Map.get(session, :auth_method, "password"),
      idp_session_id: Map.get(session, :idp_session_id)
    }
  end

  @doc """
  Creates a new user record in the database
  """
  def create_user(attrs \\ %{}) do
    %User{}
    |> User.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Retrieves a user record by its ID
  """
  def get_user_by_id(id) do
    Repo.get(User, id)
  end

  @doc """
  Retrieves the ID of a user by its UUID
  """
  def get_user_id_with_uuid(uuid) do
    case get_user_by_uuid(uuid) do
      nil ->
        nil

      user ->
        user.id
    end
  end

  @doc """
  Retrieves a user record by its UUID
  """
  def get_user_by_uuid(uuid) do
    from(
      u in User,
      where: u.uuid == ^uuid
    )
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  Get user by API Key. Hashes the presented value via `TokenHash`
  before the equality probe — only the hash is stored in the DB.
  """
  def get_user_by_api_key(api_key) when is_binary(api_key) and api_key != "" do
    hash = Lynx.Service.TokenHash.hash(api_key)

    from(
      u in User,
      where: u.api_key_hash == ^hash
    )
    |> limit(1)
    |> Repo.one()
  end

  def get_user_by_api_key(_), do: nil

  @doc """
  Get user by email
  """
  def get_user_by_email(email) do
    from(
      u in User,
      where: u.email == ^email
    )
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  Update a user
  """
  def update_user(user, attrs) do
    user
    |> User.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Delete a user
  """
  def delete_user(user) do
    Repo.delete(user)
  end

  @doc """
  Search users by name or email substring (case-insensitive). For autocomplete
  dropdowns where loading every user upfront isn't viable. Returns at most
  `limit` matches ordered by name.
  """
  def search_users(query, limit \\ 25) when is_binary(query) do
    pattern = "%#{Lynx.Search.escape_like(query)}%"

    from(u in User,
      where: ilike(u.name, ^pattern) or ilike(u.email, ^pattern),
      order_by: [asc: u.name],
      limit: ^limit
    )
    |> Repo.all()
  end

  @doc """
  Retrieve users (paginated). Caller is responsible for capping `limit` —
  see `LynxWeb.Limits` for the platform-wide caps used by admin pages and
  `search_users/2` for autocomplete-style lookups.
  """
  def get_users(offset, limit) do
    from(u in User,
      order_by: [desc: u.inserted_at],
      limit: ^limit,
      offset: ^offset
    )
    |> Repo.all()
  end

  @doc """
  Count all users
  """
  def count_users() do
    from(u in User,
      select: count(u.id)
    )
    |> Repo.one()
  end

  @doc """
  Create a new user meta
  """
  def create_user_meta(attrs \\ %{}) do
    %UserMeta{}
    |> UserMeta.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Create a new user session
  """
  def create_user_session(attrs \\ %{}) do
    %UserSession{}
    |> UserSession.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Retrieve a user meta by id
  """
  def get_user_meta_by_id(id) do
    Repo.get(UserMeta, id)
  end

  @doc """
  Update a user meta
  """
  def update_user_meta(user_meta, attrs) do
    user_meta
    |> UserMeta.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Update a user session
  """
  def update_user_session(user_session, attrs) do
    user_session
    |> UserSession.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Delete a user meta
  """
  def delete_user_meta(user_meta) do
    Repo.delete(user_meta)
  end

  @doc """
  Delete a user session
  """
  def delete_user_session(user_session) do
    Repo.delete(user_session)
  end

  @doc """
  Delete user sessions
  """
  def delete_user_sessions(user_id) do
    from(
      u in UserSession,
      where: u.user_id == ^user_id
    )
    |> Repo.delete_all()
  end

  @doc """
  Get user meta by user id and key
  """
  def get_user_meta_by_id_key(user_id, meta_key) do
    from(
      u in UserMeta,
      where: u.user_id == ^user_id,
      where: u.key == ^meta_key
    )
    |> Repo.one()
  end

  @doc """
  Get user session by user id and value
  """
  def get_user_session_by_id_value(user_id, value) do
    from(
      u in UserSession,
      where: u.user_id == ^user_id,
      where: u.value == ^value
    )
    |> Repo.one()
  end

  @doc """
  Get user sessions
  """
  def get_user_sessions(user_id) do
    from(
      u in UserSession,
      where: u.user_id == ^user_id
    )
    |> Repo.all()
  end

  @doc """
  Get user metas
  """
  def get_user_metas(user_id) do
    from(
      u in UserMeta,
      where: u.user_id == ^user_id
    )
    |> Repo.all()
  end

  @doc """
  Add a user to a team
  """
  def add_user_to_team(user_id, team_id) do
    %UserTeam{}
    |> UserTeam.changeset(%{
      user_id: user_id,
      team_id: team_id,
      uuid: Ecto.UUID.generate()
    })
    |> Repo.insert()
  end

  @doc """
  Remove user from a team
  """
  def remove_user_from_team(user_id, team_id) do
    from(
      u in UserTeam,
      where: u.user_id == ^user_id,
      where: u.team_id == ^team_id
    )
    |> Repo.delete_all()
  end

  @doc """
  Remove user from a team by UUID
  """
  def remove_user_from_team_by_uuid(uuid) do
    from(
      u in UserTeam,
      where: u.uuid == ^uuid
    )
    |> Repo.delete_all()
  end

  @doc """
  Get every Team a user belongs to.
  """
  def get_user_teams(user_id) do
    from(t in Team,
      join: ut in UserTeam,
      on: ut.team_id == t.id,
      where: ut.user_id == ^user_id
    )
    |> Repo.all()
  end

  @doc """
  Count team users
  """
  def count_team_users(team_id) do
    from(u in UserTeam,
      select: count(u.id),
      where: u.team_id == ^team_id
    )
    |> Repo.one()
  end

  @doc """
  Count user teams
  """
  def count_user_teams(user_id) do
    from(u in UserTeam,
      select: count(u.id),
      where: u.user_id == ^user_id
    )
    |> Repo.one()
  end

  @doc """
  Get team users
  """
  def get_team_users(team_id) do
    users = []

    items =
      from(
        u in UserTeam,
        where: u.team_id == ^team_id
      )
      |> Repo.all()

    for item <- items do
      user = Repo.get(User, item.user_id)

      case user do
        nil ->
          nil

        _ ->
          users ++ user
      end
    end
  end

  @doc """
  Get active users
  """
  def get_active_users(offset, limit) do
    from(u in User,
      order_by: [desc: u.inserted_at],
      where: u.is_active == true,
      limit: ^limit,
      offset: ^offset
    )
    |> Repo.all()
  end

  @doc """
  Count active users
  """
  def count_active_users() do
    from(u in User,
      select: count(u.id),
      where: u.is_active == true
    )
    |> Repo.one()
  end

  @doc """
  Validate user id
  """
  def validate_user_id(user_id) do
    user = Repo.get(User, user_id)

    case user do
      nil ->
        false

      _ ->
        true
    end
  end

  @doc """
  Validate team id
  """
  def validate_team_id(team_id) do
    team = Repo.get(Team, team_id)

    case team do
      nil ->
        false

      _ ->
        true
    end
  end

  # -- Tagged-tuple lookups (Phoenix `fetch_*` convention) --

  def fetch_user_by_id(id) do
    case get_user_by_id(id) do
      nil -> {:not_found, nil}
      user -> {:ok, user}
    end
  end

  def fetch_user_by_uuid(uuid) do
    case get_user_by_uuid(uuid) do
      nil -> {:not_found, "User with ID #{uuid} not found"}
      user -> {:ok, user}
    end
  end

  # -- High-level orchestration (was UserModule) --

  @doc "Create a user. Hashes the password using the seeded `app_key`."
  def create_user_from_data(params \\ %{}) do
    app_key = Settings.get_config("app_key", "")
    hash = AuthService.hash_password(params[:password], app_key)

    user =
      new_user(%{
        email: params[:email],
        name: params[:name],
        password_hash: hash,
        verified: false,
        api_key: params[:api_key],
        role: params[:role],
        last_seen: DateTime.utc_now()
      })

    case create_user(user) do
      {:ok, user} ->
        {:ok, user}

      {:error, changeset} ->
        messages =
          changeset.errors
          |> Enum.map(fn {field, {message, _options}} -> "#{field}: #{message}" end)

        {:error, Enum.at(messages, 0)}
    end
  end

  @doc "Update an existing user. If `:password` is blank, the password is left untouched."
  def update_user_from_data(params \\ %{}) do
    case get_user_by_uuid(params[:uuid]) do
      nil ->
        {:not_found, "User with ID #{params[:uuid]} not found"}

      user ->
        new_user =
          if params[:password] == nil or params[:password] == "" do
            %{
              email: params[:email] || user.email,
              name: params[:name] || user.name,
              role: params[:role] || user.role
            }
          else
            app_key = Settings.get_config("app_key", "")
            hash = AuthService.hash_password(params[:password], app_key)

            %{
              email: params[:email] || user.email,
              name: params[:name] || user.name,
              role: params[:role] || user.role,
              password_hash: hash
            }
          end

        case update_user(user, new_user) do
          {:ok, user} ->
            {:ok, user}

          {:error, changeset} ->
            messages =
              changeset.errors
              |> Enum.map(fn {field, {message, _options}} -> "#{field}: #{message}" end)

            {:error, Enum.at(messages, 0)}
        end
    end
  end

  def rotate_api_key(user_uuid, new_api_key) do
    case get_user_by_uuid(user_uuid) do
      nil ->
        {:not_found, "User with ID #{user_uuid} not found"}

      user ->
        case update_user(user, %{api_key: new_api_key}) do
          {:ok, user} ->
            {:ok, user}

          {:error, changeset} ->
            messages =
              changeset.errors
              |> Enum.map(fn {field, {message, _options}} -> "#{field}: #{message}" end)

            {:error, Enum.at(messages, 0)}
        end
    end
  end

  @doc """
  Create an SSO/SCIM user (no password — auth handled externally).

  Caller is responsible for linking a `user_identities` row after
  this returns — the `:auth_provider` / `:external_id` params are
  accepted but no longer persisted to `users` (see `new_user/1`).
  Use `UserIdentityContext.find_or_link/4` instead, which calls into
  this for the create branch.
  """
  def create_sso_user(params \\ %{}) do
    user =
      new_user(%{
        email: params[:email],
        name: params[:name],
        password_hash: "__SSO_NO_PASSWORD__",
        verified: true,
        api_key: AuthService.get_uuid(),
        role: params[:role] || "regular",
        last_seen: DateTime.utc_now(),
        is_active: Map.get(params, :is_active, true)
      })

    case create_user(user) do
      {:ok, user} ->
        {:ok, user}

      {:error, changeset} ->
        messages =
          changeset.errors
          |> Enum.map(fn {field, {message, _options}} -> "#{field}: #{message}" end)

        {:error, Enum.at(messages, 0)}
    end
  end

  def delete_user_by_uuid(uuid) do
    case get_user_by_uuid(uuid) do
      nil ->
        {:not_found, "User with ID #{uuid} not found"}

      user ->
        delete_user(user)
        {:ok, "User with ID #{uuid} deleted successfully"}
    end
  end

  def is_email_used(email) do
    case get_user_by_email(email) do
      nil -> false
      _ -> true
    end
  end
end

# Copyright 2023 Clivern. All rights reserved.
# Use of this source code is governed by the MIT
# license that can be found in the LICENSE file.

defmodule Lynx.Context.SnapshotContext do
  @moduledoc """
  Snapshot Context Module
  """

  import Ecto.Query

  alias Lynx.Repo
  alias Lynx.Model.{Snapshot, SnapshotMeta}
  alias Lynx.Context.{EnvironmentContext, ProjectContext, StateContext, TeamContext}

  @doc """
  Get a new snapshot
  """
  def new_snapshot(attrs \\ %{}) do
    %{
      title: attrs.title,
      description: attrs.description,
      record_type: attrs.record_type,
      record_uuid: attrs.record_uuid,
      status: attrs.status,
      data: attrs.data,
      team_id: attrs.team_id,
      uuid: Map.get(attrs, :uuid, Ecto.UUID.generate())
    }
  end

  @doc """
  Get a snapshot meta
  """
  def new_meta(meta \\ %{}) do
    %{
      key: meta.key,
      value: meta.value,
      snapshot_id: meta.snapshot_id
    }
  end

  @doc """
  Create a new snapshot
  """
  def create_snapshot(attrs \\ %{}) do
    %Snapshot{}
    |> Snapshot.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Retrieve a snapshot by ID
  """
  def get_snapshot_by_id(id) do
    Repo.get(Snapshot, id)
  end

  @doc """
  Get snapshot by uuid
  """
  def get_snapshot_by_uuid(uuid) do
    from(
      s in Snapshot,
      where: s.uuid == ^uuid
    )
    |> Repo.one()
  end

  @doc """
  Resolve the project a snapshot belongs to. Snapshots can be scoped to a
  project, an environment, or a unit (which is keyed by env_uuid in
  practice — see snapshots_live's `create_snapshot` handler).
  """
  def get_project_for_snapshot(%Snapshot{record_type: "project", record_uuid: uuid}),
    do: Lynx.Context.ProjectContext.get_project_by_uuid(uuid)

  def get_project_for_snapshot(%Snapshot{record_uuid: env_uuid})
      when is_binary(env_uuid) do
    case Lynx.Context.EnvironmentContext.get_env_by_uuid(env_uuid) do
      nil -> nil
      env -> Lynx.Context.ProjectContext.get_project_by_id(env.project_id)
    end
  end

  def get_project_for_snapshot(_), do: nil

  @doc """
  Get snapshot by UUID and team ids
  """
  def get_snapshot_by_uuid_teams(uuid, teams_ids) do
    from(
      s in Snapshot,
      where: s.uuid == ^uuid,
      where: s.team_id in ^teams_ids
    )
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  Get snapshot by ID and team ids
  """
  def get_snapshot_by_id_teams(id, teams_ids) do
    from(
      s in Snapshot,
      where: s.id == ^id,
      where: s.team_id in ^teams_ids
    )
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  Count snapshots
  """
  def count_snapshots() do
    from(s in Snapshot,
      select: count(s.id)
    )
    |> Repo.one()
  end

  @doc """
  Count snapshots by teams
  """
  def count_snapshots_by_teams(teams_ids) do
    from(s in Snapshot,
      select: count(s.id),
      where: s.team_id in ^teams_ids
    )
    |> Repo.one()
  end

  @doc """
  Update a snapshot
  """
  def update_snapshot(snapshot, attrs) do
    snapshot
    |> Snapshot.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Delete a snapshot
  """
  def delete_snapshot(snapshot) do
    Repo.delete(snapshot)
  end

  @doc """
  Retrieve snapshots
  """
  def get_snapshots(offset, limit) do
    from(s in Snapshot,
      limit: ^limit,
      offset: ^offset
    )
    |> Repo.all()
  end

  @doc """
  Retrieve snapshots by status
  """
  def get_snapshots_by_status(status) do
    from(s in Snapshot,
      where: s.status == ^status
    )
    |> Repo.all()
  end

  @doc """
  Get snapshots by teams
  """
  def get_snapshots_by_teams(teams_ids, offset, limit) do
    from(s in Snapshot,
      order_by: [desc: s.inserted_at],
      where: s.team_id in ^teams_ids,
      limit: ^limit,
      offset: ^offset
    )
    |> Repo.all()
  end

  @doc """
  Create a new snapshot meta
  """
  def create_snapshot_meta(attrs \\ %{}) do
    %SnapshotMeta{}
    |> SnapshotMeta.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Retrieve a snapshot meta by id
  """
  def get_snapshot_meta_by_id(id) do
    Repo.get(SnapshotMeta, id)
  end

  @doc """
  Update a snapshot meta
  """
  def update_snapshot_meta(snapshot_meta, attrs) do
    snapshot_meta
    |> SnapshotMeta.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Delete a snapshot meta
  """
  def delete_snapshot_meta(snapshot_meta) do
    Repo.delete(snapshot_meta)
  end

  @doc """
  Get snapshot meta by snapshot id and key
  """
  def get_snapshot_meta_by_id_key(snapshot_id, meta_key) do
    from(
      m in SnapshotMeta,
      where: m.snapshot_id == ^snapshot_id,
      where: m.key == ^meta_key
    )
    |> Repo.one()
  end

  @doc """
  Get snapshot metas
  """
  def get_snapshot_metas(snapshot_id) do
    from(
      m in SnapshotMeta,
      where: m.snapshot_id == ^snapshot_id
    )
    |> Repo.all()
  end

  @doc """
  Fetch a snapshot by UUID — returns `{:ok, snapshot}` or `{:not_found, msg}`.
  """
  def fetch_snapshot_by_uuid(uuid) do
    case get_snapshot_by_uuid(uuid) do
      nil -> {:not_found, "Snapshot with UUID #{uuid} not found"}
      snapshot -> {:ok, snapshot}
    end
  end

  # -- High-level orchestration (was SnapshotModule) --

  def create_snapshot_from_data(data \\ %{}) do
    snapshot =
      new_snapshot(%{
        title: data[:title],
        description: data[:description],
        record_type: data[:record_type],
        record_uuid: data[:record_uuid],
        status: data[:status],
        data: data[:data],
        team_id: if(data[:team_id], do: TeamContext.get_team_id_with_uuid(data[:team_id]))
      })

    case create_snapshot(snapshot) do
      {:ok, snapshot} ->
        {:ok, snapshot}

      {:error, changeset} ->
        messages =
          changeset.errors
          |> Enum.map(fn {field, {message, _options}} -> "#{field}: #{message}" end)

        {:error, Enum.at(messages, 0)}
    end
  end

  def update_snapshot_from_data(data \\ %{}) do
    case get_snapshot_by_uuid(data[:uuid]) do
      nil ->
        {:not_found, "Snapshot with ID #{data[:uuid]} not found"}

      snapshot ->
        team_id =
          if data[:team_id] == nil or data[:team_id] == "" do
            snapshot.team_id
          else
            TeamContext.get_team_id_with_uuid(data[:team_id])
          end

        new_snapshot = %{
          title: data[:title] || snapshot.title,
          description: data[:description] || snapshot.description,
          team_id: team_id
        }

        case update_snapshot(snapshot, new_snapshot) do
          {:ok, snapshot} ->
            {:ok, snapshot}

          {:error, changeset} ->
            messages =
              changeset.errors
              |> Enum.map(fn {field, {message, _options}} -> "#{field}: #{message}" end)

            {:error, Enum.at(messages, 0)}
        end
    end
  end

  @doc "Get snapshots visible to the user via team membership."
  def get_snapshots_for_user(user_id, offset, limit) do
    teams_ids =
      user_id
      |> Lynx.Context.UserContext.get_user_teams()
      |> Enum.map(& &1.id)

    get_snapshots_by_teams(teams_ids, offset, limit)
  end

  @doc "Count snapshots visible to the user via team membership."
  def count_snapshots_for_user(user_id) do
    teams_ids =
      user_id
      |> Lynx.Context.UserContext.get_user_teams()
      |> Enum.map(& &1.id)

    count_snapshots_by_teams(teams_ids)
  end

  def take_snapshot(record_type, record_uuid, opts \\ %{}) do
    case {String.to_atom(record_type), record_uuid} do
      {:project, p_uuid} ->
        case project_snapshot_data(p_uuid) do
          {:error, msg} -> {:error, msg}
          {:ok, data} -> {:ok, Jason.encode!(data)}
        end

      {:environment, e_uuid} ->
        case environment_snapshot_data(e_uuid) do
          {:error, msg} -> {:error, msg}
          {:ok, data} -> {:ok, Jason.encode!(data)}
        end

      {:unit, e_uuid} ->
        sub_path = opts[:sub_path] || ""
        version_id = opts[:version_id]

        case unit_snapshot_data(e_uuid, sub_path, version_id) do
          {:error, msg} -> {:error, msg}
          {:ok, data} -> {:ok, Jason.encode!(data)}
        end
    end
  end

  def restore_snapshot(uuid) do
    case fetch_snapshot_by_uuid(uuid) do
      {:ok, snapshot} ->
        data = Jason.decode!(snapshot.data)

        for environment <- data["environments"] do
          case EnvironmentContext.get_env_by_uuid(environment["uuid"]) do
            nil -> recreate_environment(environment)
            env -> restore_environment_state(env, environment)
          end
        end

        {:ok, "Snapshot restored"}

      {:not_found, msg} ->
        {:error, msg}
    end
  end

  def delete_snapshot_by_uuid(uuid) do
    case fetch_snapshot_by_uuid(uuid) do
      {:not_found, msg} ->
        {:not_found, msg}

      {:ok, snapshot} ->
        delete_snapshot(snapshot)
        {:ok, "Snapshot with ID #{uuid} deleted successfully"}
    end
  end

  defp restore_environment_state(env, snapshot_env) do
    states = snapshot_env["states"] || []

    states
    |> Enum.group_by(& &1["sub_path"])
    |> Enum.each(fn {sub_path, unit_states} ->
      latest = List.last(unit_states)

      if latest do
        state =
          StateContext.new_state(%{
            name: latest["name"] || "_tf_state_",
            value: latest["value"],
            sub_path: sub_path || "",
            environment_id: env.id
          })

        StateContext.create_state(state)
      end
    end)
  end

  defp recreate_environment(new_environment) do
    data =
      EnvironmentContext.new_env(%{
        slug: new_environment["slug"],
        name: new_environment["name"],
        username: new_environment["username"],
        secret: new_environment["secret"],
        project_id: new_environment["project_id"],
        uuid: new_environment["uuid"]
      })

    case EnvironmentContext.create_env(data) do
      {:ok, environment} ->
        restore_environment_state(environment, new_environment)

      {:error, changeset} ->
        messages =
          changeset.errors
          |> Enum.map(fn {field, {message, _options}} -> "#{field}: #{message}" end)

        {:error, Enum.at(messages, 0)}
    end
  end

  defp project_snapshot_data(uuid) do
    case ProjectContext.get_project_by_uuid(uuid) do
      nil ->
        {:error, "Project with ID #{uuid} not found"}

      project ->
        data = %{
          id: project.id,
          uuid: project.uuid,
          name: project.name,
          slug: project.slug,
          description: project.description,
          team_ids: ProjectContext.get_project_team_ids(project.id),
          inserted_at: project.inserted_at,
          updated_at: project.updated_at,
          environments: []
        }

        environments =
          for environment <-
                EnvironmentContext.get_project_envs(
                  project.id,
                  0,
                  LynxWeb.Limits.serialization_max()
                ) do
            states = serialize_states(environment.id)

            %{
              id: environment.id,
              uuid: environment.uuid,
              name: environment.name,
              slug: environment.slug,
              username: environment.username,
              secret: environment.secret,
              project_id: environment.project_id,
              inserted_at: environment.inserted_at,
              updated_at: environment.updated_at,
              states: states
            }
          end

        {:ok, %{data | environments: environments}}
    end
  end

  defp environment_snapshot_data(uuid) do
    case EnvironmentContext.get_env_by_uuid(uuid) do
      nil ->
        {:error, "Environment with ID #{uuid} not found"}

      environment ->
        case ProjectContext.get_project_by_id(environment.project_id) do
          nil ->
            {:error, "Project with ID #{environment.project_id} not found"}

          project ->
            data = %{
              id: project.id,
              uuid: project.uuid,
              name: project.name,
              slug: project.slug,
              description: project.description,
              team_ids: ProjectContext.get_project_team_ids(project.id),
              inserted_at: project.inserted_at,
              updated_at: project.updated_at,
              environments: []
            }

            states = serialize_states(environment.id)

            environments = [
              %{
                id: environment.id,
                uuid: environment.uuid,
                name: environment.name,
                slug: environment.slug,
                username: environment.username,
                secret: environment.secret,
                project_id: environment.project_id,
                inserted_at: environment.inserted_at,
                updated_at: environment.updated_at,
                states: states
              }
            ]

            {:ok, %{data | environments: environments}}
        end
    end
  end

  defp unit_snapshot_data(env_uuid, sub_path, version_id) do
    case EnvironmentContext.get_env_by_uuid(env_uuid) do
      nil ->
        {:error, "Environment with ID #{env_uuid} not found"}

      environment ->
        case ProjectContext.get_project_by_id(environment.project_id) do
          nil ->
            {:error, "Project not found"}

          project ->
            all_states =
              for state <- StateContext.get_states_by_environment_id(environment.id),
                  Map.get(state, :sub_path, "") == sub_path do
                serialize_state(state)
              end

            states =
              if version_id do
                Enum.filter(all_states, &(&1.id <= version_id))
              else
                all_states
              end

            data = %{
              id: project.id,
              uuid: project.uuid,
              name: project.name,
              slug: project.slug,
              description: project.description,
              team_ids: ProjectContext.get_project_team_ids(project.id),
              inserted_at: project.inserted_at,
              updated_at: project.updated_at,
              environments: [
                %{
                  id: environment.id,
                  uuid: environment.uuid,
                  name: environment.name,
                  slug: environment.slug,
                  username: environment.username,
                  secret: environment.secret,
                  project_id: environment.project_id,
                  inserted_at: environment.inserted_at,
                  updated_at: environment.updated_at,
                  states: states
                }
              ]
            }

            {:ok, data}
        end
    end
  end

  defp serialize_states(environment_id) do
    for state <- StateContext.get_states_by_environment_id(environment_id) do
      serialize_state(state)
    end
  end

  defp serialize_state(state) do
    %{
      id: state.id,
      uuid: state.uuid,
      name: state.name,
      value: state.value,
      sub_path: Map.get(state, :sub_path, ""),
      environment_id: state.environment_id,
      inserted_at: state.inserted_at,
      updated_at: state.updated_at
    }
  end
end

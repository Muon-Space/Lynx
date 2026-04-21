# Copyright 2023 Clivern. All rights reserved.
# Use of this source code is governed by the MIT
# license that can be found in the LICENSE file.

defmodule Lynx.Context.LockContext do
  @moduledoc """
  Lock Context Module
  """

  import Ecto.Query

  alias Lynx.Repo
  alias Lynx.Model.{LockMeta, Lock}
  alias Lynx.Context.{EnvironmentContext, ProjectContext, WorkspaceContext}

  @doc """
  Get a new lock
  """
  def new_lock(attrs \\ %{}) do
    %{
      environment_id: attrs.environment_id,
      operation: attrs.operation,
      info: attrs.info,
      who: attrs.who,
      version: attrs.version,
      path: attrs.path,
      sub_path: Map.get(attrs, :sub_path, ""),
      is_active: attrs.is_active,
      uuid: Map.get(attrs, :uuid, Ecto.UUID.generate())
    }
  end

  @doc """
  Create a lock meta
  """
  def new_meta(meta \\ %{}) do
    %{
      key: meta.key,
      value: meta.value,
      lock_id: meta.lock_id
    }
  end

  @doc """
  Create a new lock
  """
  def create_lock(attrs \\ %{}) do
    %Lock{}
    |> Lock.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Get a lock by id
  """
  def get_lock_by_id(id) do
    Repo.get(Lock, id)
  end

  @doc """
  Get a lock by uuid
  """
  def get_lock_by_uuid(uuid) do
    from(
      l in Lock,
      where: l.uuid == ^uuid
    )
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  Get active lock by environment id
  """
  def get_active_lock_by_environment_id(environment_id) do
    from(
      l in Lock,
      where: l.environment_id == ^environment_id,
      where: l.is_active == true
    )
    |> limit(1)
    |> Repo.one()
  end

  def get_active_lock_by_environment_and_path(environment_id, sub_path) do
    from(
      l in Lock,
      where: l.environment_id == ^environment_id,
      where: l.sub_path == ^sub_path,
      where: l.is_active == true
    )
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  Check if environment is locked
  """
  def is_environment_locked(environment_id) do
    env =
      from(
        l in Lock,
        where: l.environment_id == ^environment_id,
        where: l.is_active == true
      )
      |> limit(1)
      |> Repo.one()

    case env do
      nil ->
        false

      _ ->
        true
    end
  end

  @doc """
  Update a lock
  """
  def update_lock(lock, attrs) do
    lock
    |> Lock.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Delete a lock
  """
  def delete_lock(lock) do
    Repo.delete(lock)
  end

  @doc """
  Create a new lock meta
  """
  def create_lock_meta(attrs \\ %{}) do
    %LockMeta{}
    |> LockMeta.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Get lock meta by id
  """
  def get_lock_meta_by_id(id) do
    Repo.get(LockMeta, id)
  end

  @doc """
  Update lock meta
  """
  def update_lock_meta(lock_meta, attrs) do
    lock_meta
    |> LockMeta.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Delete lock meta
  """
  def delete_lock_meta(lock_meta) do
    lock_meta
    |> Repo.delete()
  end

  @doc """
  Get lock meta by id and key
  """
  def get_lock_meta_by_id_key(lock_id, meta_key) do
    from(
      l in LockMeta,
      where: l.lock_id == ^lock_id,
      where: l.key == ^meta_key
    )
    |> Repo.one()
  end

  @doc """
  Get lock metas
  """
  def get_lock_metas(lock_id) do
    from(
      l in LockMeta,
      where: l.lock_id == ^lock_id
    )
    |> Repo.all()
  end

  # -- Orchestration (workspace/project/env-aware lock operations) --

  def lock_action(params \\ %{}) do
    case resolve_env(params) do
      {:error, msg} ->
        {:not_found, msg}

      {:ok, env} ->
        lock =
          new_lock(%{
            environment_id: env.id,
            operation: params[:operation],
            info: params[:info],
            who: params[:who],
            version: params[:version],
            path: params[:path],
            sub_path: params[:sub_path] || "",
            uuid: params[:uuid],
            is_active: true
          })

        case :sleeplocks.attempt(:lynx_lock) do
          :ok ->
            case create_lock(lock) do
              {:ok, _} ->
                :sleeplocks.release(:lynx_lock)
                {:success, ""}

              {:error, changeset} ->
                :sleeplocks.release(:lynx_lock)
                messages = changeset.errors |> Enum.map(fn {f, {m, _}} -> "#{f}: #{m}" end)
                {:error, Enum.at(messages, 0)}
            end

          {:error, :unavailable} ->
            {:error, "Unable to hold a lock on environment"}
        end
    end
  end

  def is_locked(params \\ %{}) do
    case resolve_env(params) do
      {:error, msg} ->
        {:not_found, msg}

      {:ok, env} ->
        sub_path = params[:sub_path] || ""

        case check_env_and_unit_lock(env.id, sub_path) do
          nil -> {:success, ""}
          lock -> {:locked, lock}
        end
    end
  end

  defp check_env_and_unit_lock(env_id, "") do
    get_active_lock_by_environment_and_path(env_id, "")
  end

  defp check_env_and_unit_lock(env_id, sub_path) do
    case get_active_lock_by_environment_and_path(env_id, "") do
      nil -> get_active_lock_by_environment_and_path(env_id, sub_path)
      env_lock -> env_lock
    end
  end

  def unlock_action(params \\ %{}) do
    case resolve_env(params) do
      {:error, msg} ->
        {:not_found, msg}

      {:ok, env} ->
        sub_path = params[:sub_path] || ""

        case get_active_lock_by_environment_and_path(env.id, sub_path) do
          nil ->
            {:success, ""}

          lock ->
            case update_lock(lock, %{is_active: false}) do
              {:ok, _} ->
                {:success, ""}

              {:error, changeset} ->
                messages =
                  changeset.errors
                  |> Enum.map(fn {field, {message, _options}} -> "#{field}: #{message}" end)

                {:error, Enum.at(messages, 0)}
            end
        end
    end
  end

  defp resolve_env(params) do
    workspace = WorkspaceContext.get_workspace_by_slug(params[:w_slug])

    project =
      if workspace do
        ProjectContext.get_project_by_slug_and_workspace(params[:p_slug], workspace.id)
      else
        nil
      end

    case project do
      nil ->
        {:error, "Project not found"}

      project ->
        case EnvironmentContext.get_env_by_slug_project(project.id, params[:e_slug]) do
          nil -> {:error, "Environment not found"}
          env -> {:ok, env}
        end
    end
  end

  def force_lock(environment_id, who \\ "admin") do
    case get_active_lock_by_environment_id(environment_id) do
      nil ->
        lock =
          new_lock(%{
            environment_id: environment_id,
            operation: "manual",
            info: "Locked via UI",
            who: who,
            version: "",
            path: "",
            uuid: Ecto.UUID.generate(),
            is_active: true
          })

        case :sleeplocks.attempt(:lynx_lock) do
          :ok ->
            result = create_lock(lock)
            :sleeplocks.release(:lynx_lock)

            case result do
              {:ok, _} -> {:success, "Environment locked"}
              {:error, _} -> {:error, "Failed to lock environment"}
            end

          {:error, :unavailable} ->
            {:error, "Unable to acquire lock"}
        end

      _existing ->
        {:already_locked, "Environment is already locked"}
    end
  end

  def force_unlock(environment_id) do
    case get_active_lock_by_environment_id(environment_id) do
      nil ->
        {:success, "Environment was not locked"}

      lock ->
        case update_lock(lock, %{is_active: false}) do
          {:ok, _} -> {:success, "Environment unlocked"}
          {:error, _} -> {:error, "Failed to unlock environment"}
        end
    end
  end
end

# Copyright 2023 Clivern. All rights reserved.
# Use of this source code is governed by the MIT
# license that can be found in the LICENSE file.

defmodule Lynx.Context.LockContext do
  @moduledoc """
  Lock Context Module

  Locks follow readers-writer semantics keyed on the Terraform operation:

    * `terraform plan` sends `Operation: OperationTypePlan`. It only reads
      state, so it takes a **shared** lock. Any number of shared locks can
      be active on the same path, which is what lets many PR plans run
      against one unit at once.
    * Everything else (apply, import, refresh, state mv, the UI force-lock)
      takes an **exclusive** lock. One per path, enforced by a partial
      unique index.

  A shared lock is refused while an exclusive lock is active, so a plan
  waits for a running apply (given `-lock-timeout`) instead of planning
  against a half-written state. An exclusive lock does **not** wait for
  shared holders: a plan reads state exactly once at start, so an apply
  landing mid-plan cannot tear that read, and Terraform's own "saved plan
  is stale" serial check rejects the plan if anyone tries to apply it
  later. Making applies wait would let a stream of PR plans starve them.

  Because nothing ever waits on a shared lock, a shared row left behind by
  a killed CI job is harmless. Only exclusive locks can get stuck.
  """

  import Ecto.Query

  alias Lynx.Repo
  alias Lynx.Model.{LockMeta, Lock}
  alias Lynx.Context.{EnvironmentContext, ProjectContext, WorkspaceContext}

  @plan_operation "OperationTypePlan"

  @doc """
  Map a Terraform `Operation` string to a lock mode. Only the plan
  operation is shared; anything unrecognised is exclusive so a new or
  misspelt operation fails closed.
  """
  def mode_for_operation(@plan_operation), do: "shared"
  def mode_for_operation(_), do: "exclusive"

  @doc """
  Get a new lock
  """
  def new_lock(attrs \\ %{}) do
    operation = Map.get(attrs, :operation)

    %{
      environment_id: attrs.environment_id,
      operation: operation,
      info: attrs.info,
      who: attrs.who,
      version: attrs.version,
      path: attrs.path,
      sub_path: Map.get(attrs, :sub_path, ""),
      mode: Map.get(attrs, :mode) || mode_for_operation(operation),
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
  The active exclusive lock on a path, or nil. This is the lock that
  blocks other operations; shared locks never do.
  """
  def get_active_exclusive_lock(environment_id, sub_path) do
    from(
      l in Lock,
      where: l.environment_id == ^environment_id,
      where: l.sub_path == ^sub_path,
      where: l.is_active == true,
      where: l.mode == "exclusive"
    )
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  Active shared locks on a path (in-flight plans), oldest first.
  """
  def list_active_shared_locks(environment_id, sub_path) do
    from(
      l in Lock,
      where: l.environment_id == ^environment_id,
      where: l.sub_path == ^sub_path,
      where: l.is_active == true,
      where: l.mode == "shared",
      order_by: [asc: l.inserted_at, asc: l.id]
    )
    |> Repo.all()
  end

  @doc """
  Number of active shared locks across every path in an environment.
  """
  def count_active_shared_locks(environment_id) do
    from(
      l in Lock,
      where: l.environment_id == ^environment_id,
      where: l.is_active == true,
      where: l.mode == "shared",
      select: count(l.id)
    )
    |> Repo.one()
  end

  @doc """
  Whether any exclusive lock is active anywhere in the environment. In-flight
  plans (shared locks) do not count: they block nothing.
  """
  def is_environment_locked(environment_id) do
    from(
      l in Lock,
      where: l.environment_id == ^environment_id,
      where: l.is_active == true,
      where: l.mode == "exclusive",
      select: count(l.id)
    )
    |> Repo.one()
    |> Kernel.>(0)
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

  @doc """
  Record a lock for a Terraform operation. The mode is derived from
  `params[:operation]`. Callers check `is_locked/1` first; if an exclusive
  lock still wins the race on the unique index, the existing lock is
  returned as `{:locked, lock}` so the client sees a normal 423.
  """
  def lock_action(params \\ %{}) do
    case resolve_env(params) do
      {:error, msg} ->
        {:not_found, msg}

      {:ok, env} ->
        sub_path = params[:sub_path] || ""

        lock =
          new_lock(%{
            environment_id: env.id,
            operation: params[:operation],
            info: params[:info],
            who: params[:who],
            version: params[:version],
            path: params[:path],
            sub_path: sub_path,
            uuid: params[:uuid],
            is_active: true
          })

        # No in-process mutex here. Exclusivity is enforced by the partial
        # unique index (see `lock_insert_error/3` for the lost-race path),
        # and shared rows have nothing to serialise. The old single-slot
        # `:sleeplocks.attempt` returned 500 whenever two lock requests
        # landed on one node at the same time, which concurrent plans do
        # constantly, and it never covered a multi-node deployment anyway.
        case create_lock(lock) do
          {:ok, _} ->
            {:success, ""}

          {:error, changeset} ->
            lock_insert_error(changeset, env.id, sub_path)
        end
    end
  end

  defp lock_insert_error(changeset, env_id, sub_path) do
    unique_violation? =
      Enum.any?(changeset.errors, fn {_field, {_msg, opts}} ->
        opts[:constraint] == :unique
      end)

    with true <- unique_violation?,
         %Lock{} = existing <- get_active_exclusive_lock(env_id, sub_path) do
      {:locked, existing}
    else
      _ ->
        messages = changeset.errors |> Enum.map(fn {f, {m, _}} -> "#{f}: #{m}" end)
        {:error, Enum.at(messages, 0)}
    end
  end

  @doc """
  Whether an exclusive lock blocks operations on the given path. An
  env-wide exclusive lock (empty sub_path) blocks every unit; a unit's own
  exclusive lock blocks just that unit. Shared locks never block.
  """
  def is_locked(params \\ %{}) do
    case resolve_env(params) do
      {:error, msg} ->
        {:not_found, msg}

      {:ok, env} ->
        sub_path = params[:sub_path] || ""

        case blocking_lock(env.id, sub_path) do
          nil -> {:success, ""}
          lock -> {:locked, lock}
        end
    end
  end

  defp blocking_lock(env_id, "") do
    get_active_exclusive_lock(env_id, "")
  end

  defp blocking_lock(env_id, sub_path) do
    case get_active_exclusive_lock(env_id, "") do
      nil -> get_active_exclusive_lock(env_id, sub_path)
      env_lock -> env_lock
    end
  end

  @doc """
  Release a lock. Terraform sends the LockInfo it acquired with, so the
  normal path releases exactly the row whose `uuid` matches, whatever its
  mode, and never touches anyone else's. A missing or already-released row
  is a no-op success, matching the old idempotent behaviour.

  When no `uuid` is presented (legacy clients, tests) fall back to
  releasing the path's active exclusive lock, which is what unlock always
  did before shared locks existed.
  """
  def unlock_action(params \\ %{}) do
    case resolve_env(params) do
      {:error, msg} ->
        {:not_found, msg}

      {:ok, env} ->
        sub_path = params[:sub_path] || ""
        uuid = params[:uuid]

        lock =
          if is_binary(uuid) and uuid != "" do
            get_active_lock_by_uuid_and_path(env.id, sub_path, uuid)
          else
            get_active_exclusive_lock(env.id, sub_path)
          end

        release(lock)
    end
  end

  defp get_active_lock_by_uuid_and_path(env_id, sub_path, uuid) do
    case Ecto.UUID.cast(uuid) do
      {:ok, uuid} ->
        from(
          l in Lock,
          where: l.environment_id == ^env_id,
          where: l.sub_path == ^sub_path,
          where: l.is_active == true,
          where: l.uuid == ^uuid
        )
        |> limit(1)
        |> Repo.one()

      :error ->
        nil
    end
  end

  defp release(nil), do: {:success, ""}

  defp release(lock) do
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

  @doc """
  Take the env-wide exclusive lock from the UI or API. Refused only if an
  exclusive lock already exists somewhere in the environment; in-flight
  plans don't prevent a freeze, they just can't start new ones under it.
  """
  def force_lock(environment_id, who \\ "admin") do
    if is_environment_locked(environment_id) do
      {:already_locked, "Environment is already locked"}
    else
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

      case create_lock(lock) do
        {:ok, _} ->
          {:success, "Environment locked"}

        {:error, changeset} ->
          # Lost the race on the exclusive index to a concurrent locker.
          case lock_insert_error(changeset, environment_id, "") do
            {:locked, _} -> {:already_locked, "Environment is already locked"}
            _ -> {:error, "Failed to lock environment"}
          end
      end
    end
  end

  @doc """
  Force-clear EVERY active lock on an environment: the env-wide lock, every
  per-unit exclusive lock, and every shared (plan) lock. The admin-button
  semantic is "stop tracking any lock for this env, period," so cascading
  prevents the painful state where the env shows locked because a unit is
  locked but force-unlock at the env level only clears the env-wide row.
  """
  def force_unlock(environment_id) do
    {count, _} =
      from(l in Lock,
        where: l.environment_id == ^environment_id and l.is_active == true,
        update: [set: [is_active: false, updated_at: ^NaiveDateTime.utc_now(:second)]]
      )
      |> Repo.update_all([])

    case count do
      0 -> {:success, "Environment was not locked"}
      1 -> {:success, "Environment unlocked"}
      n -> {:success, "Environment unlocked (#{n} locks cleared)"}
    end
  end

  @doc """
  Force-clear every active lock (any mode) on one unit path.
  """
  def force_unlock_unit(environment_id, sub_path) do
    {count, _} =
      from(l in Lock,
        where:
          l.environment_id == ^environment_id and l.sub_path == ^sub_path and
            l.is_active == true,
        update: [set: [is_active: false, updated_at: ^NaiveDateTime.utc_now(:second)]]
      )
      |> Repo.update_all([])

    {:success, count}
  end
end

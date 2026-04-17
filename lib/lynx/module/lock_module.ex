# Copyright 2023 Clivern. All rights reserved.
# Use of this source code is governed by the MIT
# license that can be found in the LICENSE file.

defmodule Lynx.Module.LockModule do
  @moduledoc """
  Lock Module
  """

  alias Lynx.Context.LockContext
  alias Lynx.Context.ProjectContext
  alias Lynx.Context.EnvironmentContext

  def lock_action(params \\ %{}) do
    :sleeplocks.new(1, name: :lynx_lock)

    case ProjectContext.get_project_by_slug(params[:p_slug]) do
      nil ->
        {:not_found, "Project not found"}

      project ->
        case EnvironmentContext.get_env_by_slug_project(project.id, params[:e_slug]) do
          nil ->
            {:not_found, "Environment not found"}

          env ->
            lock =
              LockContext.new_lock(%{
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
                case LockContext.create_lock(lock) do
                  {:ok, _} ->
                    :sleeplocks.release(:lynx_lock)
                    {:success, ""}

                  {:error, changeset} ->
                    :sleeplocks.release(:lynx_lock)

                    messages =
                      changeset.errors()
                      |> Enum.map(fn {field, {message, _options}} ->
                        "#{field}: #{message}"
                      end)

                    {:error, Enum.at(messages, 0)}
                end

              {:error, :unavailable} ->
                {:error, "Unable to hold a lock on environment"}
            end
        end
    end
  end

  def is_locked(params \\ %{}) do
    case ProjectContext.get_project_by_slug(params[:p_slug]) do
      nil ->
        {:not_found, "Project not found"}

      project ->
        case EnvironmentContext.get_env_by_slug_project(project.id, params[:e_slug]) do
          nil ->
            {:not_found, "Environment not found"}

          env ->
            sub_path = params[:sub_path] || ""

            case check_env_and_unit_lock(env.id, sub_path) do
              nil -> {:success, ""}
              lock -> {:locked, lock}
            end
        end
    end
  end

  defp check_env_and_unit_lock(env_id, "") do
    LockContext.get_active_lock_by_environment_and_path(env_id, "")
  end

  defp check_env_and_unit_lock(env_id, sub_path) do
    case LockContext.get_active_lock_by_environment_and_path(env_id, "") do
      nil -> LockContext.get_active_lock_by_environment_and_path(env_id, sub_path)
      env_lock -> env_lock
    end
  end

  def unlock_action(params \\ %{}) do
    case ProjectContext.get_project_by_slug(params[:p_slug]) do
      nil ->
        {:not_found, "Project not found"}

      project ->
        case EnvironmentContext.get_env_by_slug_project(project.id, params[:e_slug]) do
          nil ->
            {:not_found, "Environment not found"}

          env ->
            sub_path = params[:sub_path] || ""

            case LockContext.get_active_lock_by_environment_and_path(env.id, sub_path) do
              nil ->
                {:success, ""}

              lock ->
                case LockContext.update_lock(lock, %{is_active: false}) do
                  {:ok, _} ->
                    {:success, ""}

                  {:error, changeset} ->
                    messages =
                      changeset.errors()
                      |> Enum.map(fn {field, {message, _options}} ->
                        "#{field}: #{message}"
                      end)

                    {:error, Enum.at(messages, 0)}
                end
            end
        end
    end
  end

  def force_lock(environment_id, who \\ "admin") do
    :sleeplocks.new(1, name: :lynx_lock)

    case LockContext.get_active_lock_by_environment_id(environment_id) do
      nil ->
        lock =
          LockContext.new_lock(%{
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
            result = LockContext.create_lock(lock)
            :sleeplocks.release(:lynx_lock)

            case result do
              {:ok, _} -> {:success, "Environment locked"}
              {:error, _} -> {:error, "Failed to lock environment"}
            end

          {:error, :unavailable} ->
            {:error, "Unable to acquire lock"}
        end

      _lock ->
        {:already_locked, "Environment is already locked"}
    end
  end

  def force_unlock(environment_id) do
    case LockContext.get_active_lock_by_environment_id(environment_id) do
      nil ->
        {:success, "Environment is not locked"}

      lock ->
        case LockContext.update_lock(lock, %{is_active: false}) do
          {:ok, _} -> {:success, "Environment unlocked"}
          {:error, _} -> {:error, "Failed to unlock environment"}
        end
    end
  end
end

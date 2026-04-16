# Copyright 2023 Clivern. All rights reserved.
# Use of this source code is governed by the MIT
# license that can be found in the LICENSE file.

defmodule Lynx.Module.StateModule do
  @moduledoc """
  State Module
  """

  alias Lynx.Context.StateContext
  alias Lynx.Context.ProjectContext
  alias Lynx.Context.EnvironmentContext

  def get_latest_state(params \\ %{}) do
    case ProjectContext.get_project_by_slug(params[:p_slug]) do
      nil ->
        {:not_found, "Project not found"}

      project ->
        case EnvironmentContext.get_env_by_slug_project(project.id, params[:e_slug]) do
          nil ->
            {:not_found, "Environment not found"}

          env ->
            sub_path = params[:sub_path] || ""

            case StateContext.get_latest_state_by_environment_and_path(env.id, sub_path) do
              nil -> {:no_state, ""}
              state -> {:state_found, state}
            end
        end
    end
  end

  def add_state(params \\ %{}) do
    case ProjectContext.get_project_by_slug(params[:p_slug]) do
      nil ->
        {:not_found, "Project not found"}

      project ->
        case EnvironmentContext.get_env_by_slug_project(project.id, params[:e_slug]) do
          nil ->
            {:not_found, "Environment not found"}

          env ->
            state =
              StateContext.new_state(%{
                environment_id: env.id,
                name: params[:name],
                value: params[:value],
                sub_path: params[:sub_path] || ""
              })

            case StateContext.create_state(state) do
              {:ok, _} ->
                {:success, ""}

              {:error, changeset} ->
                messages =
                  changeset.errors()
                  |> Enum.map(fn {field, {message, _options}} -> "#{field}: #{message}" end)

                {:error, Enum.at(messages, 0)}
            end
        end
    end
  end

  def get_latest_state_by_env_uuid(uuid) do
    case EnvironmentContext.get_env_by_uuid(uuid) do
      nil ->
        nil

      env ->
        case StateContext.get_latest_state_by_environment_id(env.id) do
          nil -> nil
          state -> state
        end
    end
  end

  def get_state_by_uuid(uuid) do
    StateContext.get_state_by_uuid(uuid)
  end

  def count_states(environment_id) do
    StateContext.count_states(environment_id)
  end
end

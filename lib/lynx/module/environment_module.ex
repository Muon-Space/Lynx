# Copyright 2023 Clivern. All rights reserved.
# Use of this source code is governed by the MIT
# license that can be found in the LICENSE file.

defmodule Lynx.Module.EnvironmentModule do
  @moduledoc """
  Environment Module
  """

  alias Lynx.Context.LockContext
  alias Lynx.Context.ProjectContext
  alias Lynx.Context.EnvironmentContext
  alias Lynx.Module.ProjectModule

  @doc """
  Get Environment by UUID and Project UUID
  """
  def get_environment_by_uuid(project_uuid, environment_uuid) do
    case ProjectContext.get_project_by_uuid(project_uuid) do
      nil ->
        {:not_found, "Project with UUID #{project_uuid} not found"}

      project ->
        case EnvironmentContext.get_env_by_uuid_project(project.id, environment_uuid) do
          nil ->
            {:not_found, "Environment with UUID #{environment_uuid} not found"}

          env ->
            {:ok, env}
        end
    end
  end

  @doc """
  Get Project Environments
  """
  def get_project_environments(project_uuid, offset, limit) do
    case ProjectContext.get_project_by_uuid(project_uuid) do
      nil ->
        {:not_found, "Project with UUID #{project_uuid} not found"}

      project ->
        {:ok, EnvironmentContext.get_project_envs(project.id, offset, limit)}
    end
  end

  @doc """
  Count Project Environments
  """
  def count_project_environments(project_uuid) do
    case ProjectContext.get_project_by_uuid(project_uuid) do
      nil ->
        0

      project ->
        EnvironmentContext.count_project_envs(project.id)
    end
  end

  @doc """
  Update environment
  """
  def update_environment(data \\ %{}) do
    case EnvironmentContext.get_env_by_uuid(data[:uuid]) do
      nil ->
        {:not_found, "Environment with UUID #{data[:uuid]} not found"}

      env ->
        project_id =
          if data[:project_id] == nil or data[:project_id] == "" do
            env.project_id
          else
            ProjectModule.get_project_id_with_uuid(data[:project_id])
          end

        new_env = %{
          name: data[:name] || env.name,
          username: data[:username] || env.username,
          secret: data[:secret] || env.secret,
          slug: data[:slug] || env.slug,
          project_id: project_id
        }

        case EnvironmentContext.update_env(env, new_env) do
          {:ok, env} ->
            {:ok, env}

          {:error, changeset} ->
            messages =
              changeset.errors
              |> Enum.map(fn {field, {message, _options}} -> "#{field}: #{message}" end)

            {:error, Enum.at(messages, 0)}
        end
    end
  end

  @doc """
  Create environment
  """
  def create_environment(data \\ %{}) do
    project_id = ProjectModule.get_project_id_with_uuid(data[:project_id])

    env =
      EnvironmentContext.new_env(%{
        name: data[:name],
        slug: data[:slug],
        username: data[:username],
        secret: data[:secret],
        project_id: project_id
      })

    case EnvironmentContext.create_env(env) do
      {:ok, env} ->
        {:ok, env}

      {:error, changeset} ->
        messages =
          changeset.errors
          |> Enum.map(fn {field, {message, _options}} -> "#{field}: #{message}" end)

        {:error, Enum.at(messages, 0)}
    end
  end

  @doc """
  Delete Environment by UUID and Project UUID
  """
  def delete_environment_by_uuid(project_uuid, environment_uuid) do
    case ProjectContext.get_project_by_uuid(project_uuid) do
      nil ->
        {:not_found, "Project with UUID #{project_uuid} not found"}

      project ->
        case EnvironmentContext.get_env_by_uuid_project(project.id, environment_uuid) do
          nil ->
            {:not_found, "Environment with UUID #{environment_uuid} not found"}

          env ->
            EnvironmentContext.delete_env(env)
            {:ok, "Environment with UUID #{environment_uuid} delete successfully"}
        end
    end
  end

  @doc """
  Validate Auth Data for environment.

  Returns `{:ok, project, env, permissions :: MapSet.t(String.t())}` on
  success or `{:error, reason}`. The permission set is the effective set
  granted by whichever auth path matched (OIDC rule's role, user's role on
  the project, or the static env credentials' implicit full access).
  """
  def is_access_allowed(data \\ %{}) do
    alias Lynx.Module.OIDCBackendModule
    alias Lynx.Module.RoleModule
    alias Lynx.Context.UserContext
    alias Lynx.Context.WorkspaceContext

    workspace = WorkspaceContext.get_workspace_by_slug(data[:workspace_slug])

    project =
      if workspace do
        ProjectContext.get_project_by_slug_and_workspace(data[:project_slug], workspace.id)
      else
        nil
      end

    case project do
      nil ->
        {:error, "Invalid project slug"}

      project ->
        case EnvironmentContext.get_env_by_slug_project(project.id, data[:env_slug]) do
          nil ->
            {:error, "Invalid environment credentials"}

          env ->
            cond do
              # OIDC provider auth
              OIDCBackendModule.is_oidc_provider?(data[:username]) ->
                case OIDCBackendModule.validate_access(data[:username], data[:secret], env.id) do
                  {:ok, permissions} -> {:ok, project, env, permissions}
                  {:error, _reason} -> {:error, "Invalid environment credentials"}
                end

              # Email + API key auth
              String.contains?(data[:username] || "", "@") ->
                case UserContext.get_user_by_email(data[:username]) do
                  nil ->
                    {:error, "Invalid credentials"}

                  user ->
                    cond do
                      not user.is_active ->
                        {:error, "Account is deactivated"}

                      user.api_key != data[:secret] ->
                        {:error, "Invalid API key"}

                      true ->
                        permissions = RoleModule.effective_permissions(user, project)

                        if MapSet.size(permissions) == 0 do
                          {:error, "User does not have access to this environment"}
                        else
                          {:ok, project, env, permissions}
                        end
                    end
                end

              # Environment username/secret auth (legacy full-access path)
              true ->
                if env.username == data[:username] and env.secret == data[:secret] do
                  {:ok, project, env, RoleModule.permissions_for_env_credentials()}
                else
                  {:error, "Invalid environment credentials"}
                end
            end
        end
    end
  end

  @doc """
  Check if slug is used
  """
  def is_slug_used(project_id, slug) do
    case EnvironmentContext.get_env_by_slug_project(project_id, slug) do
      nil ->
        false

      _ ->
        true
    end
  end

  @doc """
  Count project envs
  """
  def count_project_envs(project_id) do
    EnvironmentContext.count_project_envs(project_id)
  end

  @doc """
  Check if environment is locked
  """
  def is_environment_locked(environment_id) do
    LockContext.is_environment_locked(environment_id)
  end
end

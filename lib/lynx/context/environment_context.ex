# Copyright 2023 Clivern. All rights reserved.
# Use of this source code is governed by the MIT
# license that can be found in the LICENSE file.

defmodule Lynx.Context.EnvironmentContext do
  @moduledoc """
  Environment Context Module
  """

  import Ecto.Query

  alias Lynx.Repo
  alias Lynx.Model.{Environment, EnvironmentMeta}
  alias Lynx.Context.{LockContext, ProjectContext, RoleContext, UserContext, WorkspaceContext}
  alias Lynx.Service.OIDCBackend

  @doc """
  Get a new environment
  """
  def new_env(attrs \\ %{}) do
    %{
      slug: attrs.slug,
      name: attrs.name,
      username: attrs.username,
      secret: attrs.secret,
      project_id: attrs.project_id,
      uuid: Map.get(attrs, :uuid, Ecto.UUID.generate())
    }
  end

  @doc """
  Get a environment meta
  """
  def new_meta(meta \\ %{}) do
    %{
      key: meta.key,
      value: meta.value,
      environment_id: meta.environment_id
    }
  end

  @doc """
  Create a new environment
  """
  def create_env(attrs \\ %{}) do
    %Environment{}
    |> Environment.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Get Env ID with UUID
  """
  def get_env_id_with_uuid(uuid) do
    case get_env_by_uuid(uuid) do
      nil ->
        nil

      env ->
        env.id
    end
  end

  @doc """
  Retrieve a environment by ID
  """
  def get_env_by_id(id) do
    Repo.get(Environment, id)
  end

  @doc """
  Get environment by slug, project id
  """
  def get_env_by_slug_project(project_id, slug) do
    from(
      e in Environment,
      where: e.slug == ^slug,
      where: e.project_id == ^project_id
    )
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  Get environment by uuid
  """
  def get_env_by_uuid(uuid) do
    from(
      e in Environment,
      where: e.uuid == ^uuid
    )
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  Get environment by uuid and project id
  """
  def get_env_by_uuid_project(project_id, env_uuid) do
    from(
      e in Environment,
      where: e.project_id == ^project_id,
      where: e.uuid == ^env_uuid
    )
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  Update a environment
  """
  def update_env(env, attrs) do
    env
    |> Environment.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Delete a environment
  """
  def delete_env(env) do
    Repo.delete(env)
  end

  @doc """
  Retrieve project environments
  """
  def get_project_envs(project_id, offset, limit) do
    from(e in Environment,
      where: e.project_id == ^project_id,
      limit: ^limit,
      offset: ^offset
    )
    |> Repo.all()
  end

  @doc """
  Count project environments
  """
  def count_project_envs(project_id) do
    from(e in Environment,
      select: count(e.id),
      where: e.project_id == ^project_id
    )
    |> Repo.one()
  end

  @doc """
  Create a new environment meta
  """
  def create_env_meta(attrs \\ %{}) do
    %EnvironmentMeta{}
    |> EnvironmentMeta.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Retrieve a environment meta by id
  """
  def get_env_meta_by_id(id) do
    Repo.get(EnvironmentMeta, id)
  end

  @doc """
  Update a environment meta
  """
  def update_env_meta(env_meta, attrs) do
    env_meta
    |> EnvironmentMeta.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Delete a environment meta
  """
  def delete_env_meta(env_meta) do
    Repo.delete(env_meta)
  end

  @doc """
  Get environment meta by environment id and key
  """
  def get_env_meta_by_id_key(env_id, meta_key) do
    from(
      e in EnvironmentMeta,
      where: e.environment_id == ^env_id,
      where: e.key == ^meta_key
    )
    |> Repo.one()
  end

  @doc """
  Get environment metas
  """
  def get_env_metas(env_id) do
    from(
      e in EnvironmentMeta,
      where: e.environment_id == ^env_id
    )
    |> Repo.all()
  end

  @doc """
  Pass-through to `LockContext.is_environment_locked/1` — exposed here
  because callers think of this as an environment-level question.
  """
  def is_environment_locked(environment_id),
    do: LockContext.is_environment_locked(environment_id)

  # -- Project-aware orchestration --

  def get_environment_by_uuid(project_uuid, environment_uuid) do
    case ProjectContext.get_project_by_uuid(project_uuid) do
      nil ->
        {:not_found, "Project with UUID #{project_uuid} not found"}

      project ->
        case get_env_by_uuid_project(project.id, environment_uuid) do
          nil -> {:not_found, "Environment with UUID #{environment_uuid} not found"}
          env -> {:ok, env}
        end
    end
  end

  def get_project_environments(project_uuid, offset, limit) do
    case ProjectContext.get_project_by_uuid(project_uuid) do
      nil ->
        {:not_found, "Project with UUID #{project_uuid} not found"}

      project ->
        {:ok, get_project_envs(project.id, offset, limit)}
    end
  end

  def count_project_environments(project_uuid) do
    case ProjectContext.get_project_by_uuid(project_uuid) do
      nil -> 0
      project -> count_project_envs(project.id)
    end
  end

  def update_environment(data \\ %{}) do
    case get_env_by_uuid(data[:uuid]) do
      nil ->
        {:not_found, "Environment with UUID #{data[:uuid]} not found"}

      env ->
        project_id =
          if data[:project_id] == nil or data[:project_id] == "" do
            env.project_id
          else
            ProjectContext.get_project_id_with_uuid(data[:project_id])
          end

        new_env = %{
          name: data[:name] || env.name,
          username: data[:username] || env.username,
          secret: data[:secret] || env.secret,
          slug: data[:slug] || env.slug,
          project_id: project_id
        }

        case update_env(env, new_env) do
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

  def create_environment(data \\ %{}) do
    project_id = ProjectContext.get_project_id_with_uuid(data[:project_id])

    env =
      new_env(%{
        name: data[:name],
        slug: data[:slug],
        username: data[:username],
        secret: data[:secret],
        project_id: project_id
      })

    case create_env(env) do
      {:ok, env} ->
        {:ok, env}

      {:error, changeset} ->
        messages =
          changeset.errors
          |> Enum.map(fn {field, {message, _options}} -> "#{field}: #{message}" end)

        {:error, Enum.at(messages, 0)}
    end
  end

  def delete_environment_by_uuid(project_uuid, environment_uuid) do
    case ProjectContext.get_project_by_uuid(project_uuid) do
      nil ->
        {:not_found, "Project with UUID #{project_uuid} not found"}

      project ->
        case get_env_by_uuid_project(project.id, environment_uuid) do
          nil ->
            {:not_found, "Environment with UUID #{environment_uuid} not found"}

          env ->
            delete_env(env)
            {:ok, "Environment with UUID #{environment_uuid} delete successfully"}
        end
    end
  end

  @doc """
  Validate auth data for an environment access attempt (Terraform backend).

  Returns `{:ok, project, env, permissions :: MapSet.t(String.t())}` on
  success or `{:error, reason}`. The permission set is the effective set
  granted by whichever auth path matched (OIDC rule's role, user's role on
  the project, or the static env credentials' implicit full access).
  """
  def is_access_allowed(data \\ %{}) do
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
        case get_env_by_slug_project(project.id, data[:env_slug]) do
          nil ->
            {:error, "Invalid environment credentials"}

          env ->
            cond do
              # OIDC provider auth
              OIDCBackend.is_oidc_provider?(data[:username]) ->
                case OIDCBackend.validate_access(data[:username], data[:secret], env.id) do
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
                        permissions = RoleContext.effective_permissions(user, project)

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
                  {:ok, project, env, RoleContext.permissions_for_env_credentials()}
                else
                  {:error, "Invalid environment credentials"}
                end
            end
        end
    end
  end

  def is_slug_used(project_id, slug) do
    case get_env_by_slug_project(project_id, slug) do
      nil -> false
      _ -> true
    end
  end
end

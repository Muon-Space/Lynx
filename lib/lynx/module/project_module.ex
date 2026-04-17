# Copyright 2023 Clivern. All rights reserved.
# Use of this source code is governed by the MIT
# license that can be found in the LICENSE file.

defmodule Lynx.Module.ProjectModule do
  @moduledoc """
  Project Module
  """

  alias Lynx.Context.ProjectContext
  alias Lynx.Module.TeamModule

  @doc """
  Get Project by ID
  """
  def get_project_by_id(id) do
    case ProjectContext.get_project_by_id(id) do
      nil -> {:not_found, "Project with ID #{id} not found"}
      project -> {:ok, project}
    end
  end

  @doc """
  Get Project by UUID
  """
  def get_project_by_uuid(uuid) do
    case ProjectContext.get_project_by_uuid(uuid) do
      nil -> {:not_found, "Project with UUID #{uuid} not found"}
      project -> {:ok, project}
    end
  end

  @doc """
  Get projects
  """
  def get_projects(offset, limit) do
    ProjectContext.get_projects(offset, limit)
  end

  @doc """
  Count projects
  """
  def count_projects() do
    ProjectContext.count_projects()
  end

  @doc """
  Get user projects
  """
  def get_projects(user_id, offset, limit) do
    user_teams = TeamModule.get_user_teams(user_id)

    teams_ids =
      for user_team <- user_teams do
        user_team.id
      end

    ProjectContext.get_projects_by_teams(teams_ids, offset, limit)
  end

  @doc """
  Count user projects
  """
  def count_projects(user_id) do
    user_teams = TeamModule.get_user_teams(user_id)

    teams_ids =
      for user_team <- user_teams do
        user_team.id
      end

    ProjectContext.count_projects_by_teams(teams_ids)
  end

  @doc """
  Update Project
  """
  def update_project(data \\ %{}) do
    case ProjectContext.get_project_by_uuid(data[:uuid]) do
      nil ->
        {:not_found, "Project with ID #{data[:uuid]} not found"}

      project ->
        new_project = %{
          name: data[:name] || project.name,
          description: data[:description] || project.description,
          slug: data[:slug] || project.slug
        }

        case ProjectContext.update_project(project, new_project) do
          {:ok, project} ->
            # Sync team memberships if team_ids provided
            if data[:team_ids] do
              sync_project_teams(project.id, data[:team_ids])
            end

            {:ok, project}

          {:error, changeset} ->
            messages =
              changeset.errors()
              |> Enum.map(fn {field, {message, _options}} -> "#{field}: #{message}" end)

            {:error, Enum.at(messages, 0)}
        end
    end
  end

  @doc """
  Create Project
  """
  def create_project(data \\ %{}) do
    project =
      ProjectContext.new_project(%{
        name: data[:name],
        description: data[:description],
        slug: data[:slug],
        workspace_id: data[:workspace_id]
      })

    case ProjectContext.create_project(project) do
      {:ok, project} ->
        # Add team memberships
        team_ids = data[:team_ids] || []

        # Support single team_id for backward compatibility
        team_ids =
          if team_ids == [] and data[:team_id] do
            [TeamModule.get_team_id_with_uuid(data[:team_id])]
          else
            Enum.map(team_ids, &TeamModule.get_team_id_with_uuid/1)
          end

        for team_id <- team_ids, team_id != nil do
          ProjectContext.add_project_to_team(project.id, team_id)
        end

        {:ok, project}

      {:error, changeset} ->
        messages =
          changeset.errors()
          |> Enum.map(fn {field, {message, _options}} -> "#{field}: #{message}" end)

        {:error, Enum.at(messages, 0)}
    end
  end

  @doc """
  Delete Project By UUID
  """
  def delete_project_by_uuid(uuid) do
    case ProjectContext.get_project_by_uuid(uuid) do
      nil ->
        {:not_found, "Project with UUID #{uuid} not found"}

      project ->
        ProjectContext.delete_project(project)
        {:ok, "Project with UUID #{uuid} deleted successfully"}
    end
  end

  @doc """
  Count Team Projects
  """
  def count_projects_by_team(team_id) do
    ProjectContext.count_projects_by_team(team_id)
  end

  @doc """
  Check if a slug used with a team
  """
  def is_slug_used_in_team(slug, team_id) do
    case ProjectContext.get_project_by_slug_team_id(slug, team_id) do
      nil -> false
      _ -> true
    end
  end

  def get_project_id_with_uuid(uuid) do
    ProjectContext.get_project_id_with_uuid(uuid)
  end

  @doc """
  Get teams for a project
  """
  def get_project_teams(project_id) do
    ProjectContext.get_project_teams(project_id)
  end

  @doc """
  Get project team UUIDs
  """
  def get_project_team_uuids(project_id) do
    ProjectContext.get_project_teams(project_id)
    |> Enum.map(fn t -> t.uuid end)
  end

  @doc """
  Sync project team memberships
  """
  def sync_project_teams(project_id, team_uuids) do
    current_team_ids = ProjectContext.get_project_team_ids(project_id)

    future_team_ids =
      team_uuids
      |> Enum.map(&TeamModule.get_team_id_with_uuid/1)
      |> Enum.filter(&(&1 != nil))

    for id <- current_team_ids, id not in future_team_ids do
      ProjectContext.remove_project_from_team(project_id, id)
    end

    for id <- future_team_ids, id not in current_team_ids do
      ProjectContext.add_project_to_team(project_id, id)
    end
  end
end

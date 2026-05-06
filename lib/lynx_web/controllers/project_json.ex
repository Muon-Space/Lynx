# Copyright 2023 Clivern. All rights reserved.
# Use of this source code is governed by the MIT
# license that can be found in the LICENSE file.

defmodule LynxWeb.ProjectJSON do
  alias Lynx.Context.EnvironmentContext
  alias Lynx.Context.ProjectContext

  # Render projects list
  def render("list.json", %{projects: projects, metadata: metadata}) do
    %{
      projects: Enum.map(projects, &render_project/1),
      _metadata: %{
        limit: metadata.limit,
        offset: metadata.offset,
        totalCount: metadata.totalCount
      }
    }
  end

  # Render project
  def render("index.json", %{project: project}) do
    render_project(project)
  end

  # Render errors
  def render("error.json", %{message: message}) do
    %{errorMessage: message}
  end

  # Format project
  defp render_project(project) do
    teams = ProjectContext.get_project_teams(project.id)

    %{
      id: project.uuid,
      name: project.name,
      slug: project.slug,
      description: project.description,
      workspaceId: workspace_uuid(project),
      teams:
        Enum.map(teams, fn team ->
          %{id: team.uuid, name: team.name, slug: team.slug}
        end),
      # Backward compat: first team as "team"
      team:
        case teams do
          [first | _] -> %{id: first.uuid, name: first.name, slug: first.slug}
          [] -> nil
        end,
      envCount: EnvironmentContext.count_project_envs(project.id),
      createdAt: project.inserted_at,
      updatedAt: project.updated_at
    }
  end

  # Resolve the project's workspace UUID for the JSON response. Returns nil
  # for projects that have no workspace association.
  defp workspace_uuid(%{workspace_id: nil}), do: nil

  defp workspace_uuid(%{workspace_id: id}) do
    case Lynx.Context.WorkspaceContext.get_workspace_by_id(id) do
      nil -> nil
      ws -> ws.uuid
    end
  end
end

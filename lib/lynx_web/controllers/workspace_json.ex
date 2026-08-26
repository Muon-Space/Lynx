# Copyright 2023 Clivern. All rights reserved.
# Use of this source code is governed by the MIT
# license that can be found in the LICENSE file.

defmodule LynxWeb.WorkspaceJSON do
  alias Lynx.Context.ProjectContext

  # Render workspaces list
  def render("list.json", %{workspaces: workspaces, metadata: metadata}) do
    %{
      workspaces: Enum.map(workspaces, &render_workspace/1),
      _metadata: %{
        limit: metadata.limit,
        offset: metadata.offset,
        totalCount: metadata.totalCount
      }
    }
  end

  # Render workspace
  def render("index.json", %{workspace: workspace}) do
    render_workspace(workspace)
  end

  # Render errors
  def render("error.json", %{message: message}) do
    %{errorMessage: message}
  end

  # Format workspace
  defp render_workspace(workspace) do
    %{
      id: workspace.uuid,
      name: workspace.name,
      slug: workspace.slug,
      description: workspace.description,
      projectsCount: ProjectContext.count_projects_by_workspace(workspace.id),
      createdAt: workspace.inserted_at,
      updatedAt: workspace.updated_at
    }
  end
end

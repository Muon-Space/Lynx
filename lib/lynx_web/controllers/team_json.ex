# Copyright 2023 Clivern. All rights reserved.
# Use of this source code is governed by the MIT
# license that can be found in the LICENSE file.

defmodule LynxWeb.TeamJSON do
  alias Lynx.Context.UserContext
  alias Lynx.Context.TeamContext
  alias Lynx.Context.ProjectContext

  # Render teams list
  def render("list.json", %{teams: teams, metadata: metadata}) do
    %{
      teams: Enum.map(teams, &render_team/1),
      _metadata: %{
        limit: metadata.limit,
        offset: metadata.offset,
        totalCount: metadata.totalCount
      }
    }
  end

  # Render team
  def render("index.json", %{team: team}) do
    render_team(team)
  end

  # Render errors
  def render("error.json", %{message: message}) do
    %{errorMessage: message}
  end

  # Format team
  defp render_team(team) do
    %{
      id: team.uuid,
      name: team.name,
      slug: team.slug,
      usersCount: UserContext.count_team_users(team.id),
      projectsCount: ProjectContext.count_projects_by_team(team.id),
      description: team.description,
      members: TeamContext.get_team_members(team.id),
      createdAt: team.inserted_at,
      updatedAt: team.updated_at
    }
  end
end

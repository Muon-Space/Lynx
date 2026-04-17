# Copyright 2023 Clivern. All rights reserved.
# Use of this source code is governed by the MIT
# license that can be found in the LICENSE file.

defmodule Lynx.Context.ProjectContext do
  @moduledoc """
  Project Context Module
  """

  import Ecto.Query

  alias Lynx.Repo
  alias Lynx.Model.{ProjectMeta, Project, ProjectTeam}

  @doc """
  Get a new project
  """
  def new_project(attrs \\ %{}) do
    %{
      name: attrs.name,
      description: attrs.description,
      slug: attrs.slug,
      workspace_id: attrs[:workspace_id],
      uuid: Map.get(attrs, :uuid, Ecto.UUID.generate())
    }
  end

  @doc """
  Get a project meta
  """
  def new_meta(meta \\ %{}) do
    %{
      key: meta.key,
      value: meta.value,
      project_id: meta.project_id
    }
  end

  @doc """
  Create a new project
  """
  def create_project(attrs \\ %{}) do
    %Project{}
    |> Project.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Get Project ID with UUID
  """
  def get_project_id_with_uuid(uuid) do
    case get_project_by_uuid(uuid) do
      nil -> nil
      project -> project.id
    end
  end

  @doc """
  Retrieve a project by ID
  """
  def get_project_by_id(id) do
    Repo.get(Project, id)
  end

  @doc """
  Get project by UUID
  """
  def get_project_by_uuid(uuid) do
    from(p in Project, where: p.uuid == ^uuid)
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  Get project by slug within a team (via join table)
  """
  def get_project_by_slug(slug) do
    from(p in Project,
      where: p.slug == ^slug
    )
    |> limit(1)
    |> Repo.one()
  end

  def get_project_by_slug_and_workspace(slug, workspace_id) do
    from(p in Project,
      where: p.slug == ^slug,
      where: p.workspace_id == ^workspace_id
    )
    |> limit(1)
    |> Repo.one()
  end

  def get_project_by_slug_team_id(slug, team_id) do
    from(p in Project,
      join: pt in ProjectTeam,
      on: pt.project_id == p.id,
      where: p.slug == ^slug,
      where: pt.team_id == ^team_id
    )
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  Update a project
  """
  def update_project(project, attrs) do
    project
    |> Project.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Delete a project
  """
  def delete_project(project) do
    Repo.delete(project)
  end

  @doc """
  Retrieve all projects
  """
  def get_projects() do
    Repo.all(Project)
  end

  @doc """
  Get projects
  """
  def get_projects(offset, limit) do
    from(p in Project,
      order_by: [desc: p.inserted_at],
      limit: ^limit,
      offset: ^offset
    )
    |> Repo.all()
  end

  @doc """
  Count projects
  """
  def count_projects() do
    from(p in Project, select: count(p.id))
    |> Repo.one()
  end

  def get_projects_by_workspace(workspace_id, offset, limit) do
    from(p in Project,
      where: p.workspace_id == ^workspace_id,
      order_by: [desc: p.inserted_at],
      limit: ^limit,
      offset: ^offset
    )
    |> Repo.all()
  end

  def count_projects_by_workspace(workspace_id) do
    from(p in Project, select: count(p.id), where: p.workspace_id == ^workspace_id)
    |> Repo.one()
  end

  def get_projects_by_workspace_and_teams(workspace_id, teams_ids, offset, limit) do
    from(p in Project,
      join: pt in ProjectTeam,
      on: pt.project_id == p.id,
      where: p.workspace_id == ^workspace_id,
      where: pt.team_id in ^teams_ids,
      distinct: p.id,
      order_by: [desc: p.inserted_at],
      limit: ^limit,
      offset: ^offset
    )
    |> Repo.all()
  end

  def count_projects_by_workspace_and_teams(workspace_id, teams_ids) do
    from(p in Project,
      join: pt in ProjectTeam,
      on: pt.project_id == p.id,
      where: p.workspace_id == ^workspace_id,
      where: pt.team_id in ^teams_ids,
      select: count(p.id, :distinct)
    )
    |> Repo.one()
  end

  @doc """
  Get projects accessible by a set of team IDs
  """
  def get_projects_by_teams(teams_ids, offset, limit) do
    from(p in Project,
      join: pt in ProjectTeam,
      on: pt.project_id == p.id,
      where: pt.team_id in ^teams_ids,
      distinct: true,
      order_by: [desc: p.inserted_at],
      limit: ^limit,
      offset: ^offset
    )
    |> Repo.all()
  end

  @doc """
  Count projects accessible by a set of team IDs
  """
  def count_projects_by_teams(teams_ids) do
    from(p in Project,
      join: pt in ProjectTeam,
      on: pt.project_id == p.id,
      where: pt.team_id in ^teams_ids,
      distinct: true,
      select: count(p.id)
    )
    |> Repo.one()
  end

  @doc """
  Get projects belonging to a specific team
  """
  def get_projects_by_team(team_id, offset, limit) do
    from(p in Project,
      join: pt in ProjectTeam,
      on: pt.project_id == p.id,
      where: pt.team_id == ^team_id,
      order_by: [desc: p.inserted_at],
      limit: ^limit,
      offset: ^offset
    )
    |> Repo.all()
  end

  @doc """
  Count projects belonging to a specific team
  """
  def count_projects_by_team(team_id) do
    from(p in Project,
      join: pt in ProjectTeam,
      on: pt.project_id == p.id,
      where: pt.team_id == ^team_id,
      select: count(p.id)
    )
    |> Repo.one()
  end

  # -- Project-Team membership --

  @doc """
  Add a project to a team
  """
  def add_project_to_team(project_id, team_id) do
    %ProjectTeam{}
    |> ProjectTeam.changeset(%{
      project_id: project_id,
      team_id: team_id,
      uuid: Ecto.UUID.generate()
    })
    |> Repo.insert(on_conflict: :nothing)
  end

  @doc """
  Remove a project from a team
  """
  def remove_project_from_team(project_id, team_id) do
    from(pt in ProjectTeam,
      where: pt.project_id == ^project_id,
      where: pt.team_id == ^team_id
    )
    |> Repo.delete_all()
  end

  @doc """
  Get all team IDs for a project
  """
  def get_project_team_ids(project_id) do
    from(pt in ProjectTeam,
      where: pt.project_id == ^project_id,
      select: pt.team_id
    )
    |> Repo.all()
  end

  @doc """
  Get all teams for a project (returns team records)
  """
  def get_project_teams(project_id) do
    alias Lynx.Model.Team

    from(t in Team,
      join: pt in ProjectTeam,
      on: pt.team_id == t.id,
      where: pt.project_id == ^project_id
    )
    |> Repo.all()
  end

  @doc """
  Get project by UUID accessible by a set of team IDs
  """
  def get_project_by_uuid_teams(uuid, teams_ids) do
    from(p in Project,
      join: pt in ProjectTeam,
      on: pt.project_id == p.id,
      where: p.uuid == ^uuid,
      where: pt.team_id in ^teams_ids
    )
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  Get project by ID accessible by a set of team IDs
  """
  def get_project_by_id_teams(id, teams_ids) do
    from(p in Project,
      join: pt in ProjectTeam,
      on: pt.project_id == p.id,
      where: p.id == ^id,
      where: pt.team_id in ^teams_ids
    )
    |> limit(1)
    |> Repo.one()
  end

  # -- Project Meta --

  def create_project_meta(attrs \\ %{}) do
    %ProjectMeta{}
    |> ProjectMeta.changeset(attrs)
    |> Repo.insert()
  end

  def get_project_meta_by_id(id), do: Repo.get(ProjectMeta, id)

  def update_project_meta(project_meta, attrs) do
    project_meta
    |> ProjectMeta.changeset(attrs)
    |> Repo.update()
  end

  def delete_project_meta(project_meta), do: Repo.delete(project_meta)

  def get_project_meta_by_id_key(project_id, meta_key) do
    from(p in ProjectMeta,
      where: p.project_id == ^project_id,
      where: p.key == ^meta_key
    )
    |> Repo.one()
  end

  def get_project_metas(project_id) do
    from(p in ProjectMeta, where: p.project_id == ^project_id)
    |> Repo.all()
  end
end

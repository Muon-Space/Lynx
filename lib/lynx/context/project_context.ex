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
  Search projects by name or slug substring (case-insensitive). For
  autocomplete inputs. Returns at most `limit` matches ordered by name.
  """
  def search_projects(query, limit \\ 25) when is_binary(query) do
    pattern = "%#{escape_like(query)}%"

    from(p in Project,
      where: ilike(p.name, ^pattern) or ilike(p.slug, ^pattern),
      order_by: [asc: p.name],
      limit: ^limit
    )
    |> Repo.all()
  end

  @doc """
  Search projects scoped to a user — only projects whose teams the user belongs
  to. For non-super users in autocomplete inputs.
  """
  def search_projects_for_user(user_id, query, limit \\ 25) when is_binary(query) do
    teams_ids =
      user_id
      |> Lynx.Context.UserContext.get_user_teams()
      |> Enum.map(& &1.id)

    pattern = "%#{escape_like(query)}%"

    from(p in Project,
      join: pt in ProjectTeam,
      on: pt.project_id == p.id,
      where: pt.team_id in ^teams_ids,
      where: ilike(p.name, ^pattern) or ilike(p.slug, ^pattern),
      distinct: true,
      order_by: [asc: p.name],
      limit: ^limit
    )
    |> Repo.all()
  end

  defp escape_like(query),
    do:
      query
      |> String.replace("\\", "\\\\")
      |> String.replace("%", "\\%")
      |> String.replace("_", "\\_")

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
  Add a project to a team. If `role_id` is omitted, the seeded "applier" role
  is used so existing call sites preserve their full-access behavior.
  """
  def add_project_to_team(project_id, team_id, role_id \\ nil) do
    role_id = role_id || default_applier_role_id()

    %ProjectTeam{}
    |> ProjectTeam.changeset(%{
      project_id: project_id,
      team_id: team_id,
      role_id: role_id,
      uuid: Ecto.UUID.generate()
    })
    |> Repo.insert(on_conflict: :nothing)
  end

  @doc """
  Update the role for a (project, team) membership.
  """
  def set_project_team_role(project_id, team_id, role_id) do
    from(pt in ProjectTeam,
      where: pt.project_id == ^project_id and pt.team_id == ^team_id,
      update: [set: [role_id: ^role_id, updated_at: ^DateTime.utc_now()]]
    )
    |> Repo.update_all([])
  end

  @doc """
  Look up the role assignments for every team a user belongs to on this project.
  Returns a list of role_id integers (may contain duplicates if the user
  belongs to multiple teams attached to the same project).
  """
  def list_team_role_ids_for_user(project_id, user_team_ids) do
    from(pt in ProjectTeam,
      where: pt.project_id == ^project_id and pt.team_id in ^user_team_ids,
      select: pt.role_id
    )
    |> Repo.all()
  end

  defp default_applier_role_id do
    case Lynx.Context.RoleContext.get_role_by_name("applier") do
      nil -> raise "Seeded 'applier' role not found — run `mix ecto.migrate`"
      role -> role.id
    end
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
  List `{team, project_team_row}` pairs for a project — used to render the
  Access card with each team's current role.
  """
  def list_project_team_assignments(project_id) do
    alias Lynx.Model.Team

    from(pt in ProjectTeam,
      join: t in Team,
      on: t.id == pt.team_id,
      where: pt.project_id == ^project_id,
      order_by: [asc: t.name],
      select: {t, pt}
    )
    |> Repo.all()
  end

  @doc """
  List `{project, project_team_row}` pairs for a team — powers the Teams page
  "Projects & Roles" column so admins can see which projects a team is
  attached to and the role it holds on each.
  """
  def list_team_project_assignments(team_id) do
    from(pt in ProjectTeam,
      join: p in Project,
      on: p.id == pt.project_id,
      where: pt.team_id == ^team_id,
      order_by: [asc: p.name],
      select: {p, pt}
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

  # -- Tagged-tuple lookups (Phoenix `fetch_*` convention) --

  def fetch_project_by_id(id) do
    case get_project_by_id(id) do
      nil -> {:not_found, "Project with ID #{id} not found"}
      project -> {:ok, project}
    end
  end

  def fetch_project_by_uuid(uuid) do
    case get_project_by_uuid(uuid) do
      nil -> {:not_found, "Project with UUID #{uuid} not found"}
      project -> {:ok, project}
    end
  end

  # -- High-level orchestration (was ProjectModule) --

  @doc "Get user-scoped projects (paginated) — projects whose teams the user belongs to."
  def get_projects_for_user(user_id, offset, limit) do
    teams_ids =
      user_id
      |> Lynx.Context.UserContext.get_user_teams()
      |> Enum.map(& &1.id)

    get_projects_by_teams(teams_ids, offset, limit)
  end

  @doc "Count user-scoped projects."
  def count_projects_for_user(user_id) do
    teams_ids =
      user_id
      |> Lynx.Context.UserContext.get_user_teams()
      |> Enum.map(& &1.id)

    count_projects_by_teams(teams_ids)
  end

  def update_project_from_data(data \\ %{}) do
    case get_project_by_uuid(data[:uuid]) do
      nil ->
        {:not_found, "Project with ID #{data[:uuid]} not found"}

      project ->
        new_project = %{
          name: data[:name] || project.name,
          description: data[:description] || project.description,
          slug: data[:slug] || project.slug
        }

        case update_project(project, new_project) do
          {:ok, project} ->
            if data[:team_ids], do: sync_project_teams(project.id, data[:team_ids])
            {:ok, project}

          {:error, changeset} ->
            messages =
              changeset.errors
              |> Enum.map(fn {field, {message, _options}} -> "#{field}: #{message}" end)

            {:error, Enum.at(messages, 0)}
        end
    end
  end

  def create_project_from_data(data \\ %{}) do
    project =
      new_project(%{
        name: data[:name],
        description: data[:description],
        slug: data[:slug],
        workspace_id: data[:workspace_id]
      })

    case create_project(project) do
      {:ok, project} ->
        team_ids = data[:team_ids] || []

        team_ids =
          if team_ids == [] and data[:team_id] do
            [Lynx.Context.TeamContext.get_team_id_with_uuid(data[:team_id])]
          else
            Enum.map(team_ids, &Lynx.Context.TeamContext.get_team_id_with_uuid/1)
          end

        for team_id <- team_ids, team_id != nil do
          add_project_to_team(project.id, team_id)
        end

        {:ok, project}

      {:error, changeset} ->
        messages =
          changeset.errors
          |> Enum.map(fn {field, {message, _options}} -> "#{field}: #{message}" end)

        {:error, Enum.at(messages, 0)}
    end
  end

  def delete_project_by_uuid(uuid) do
    case get_project_by_uuid(uuid) do
      nil ->
        {:not_found, "Project with UUID #{uuid} not found"}

      project ->
        delete_project(project)
        {:ok, "Project with UUID #{uuid} deleted successfully"}
    end
  end

  def is_slug_used_in_team(slug, team_id) do
    case get_project_by_slug_team_id(slug, team_id) do
      nil -> false
      _ -> true
    end
  end

  def get_project_team_uuids(project_id) do
    get_project_teams(project_id) |> Enum.map(& &1.uuid)
  end

  @doc "Project teams as `[{name, uuid}, ...]` — combobox-friendly."
  def get_project_team_options(project_id) do
    get_project_teams(project_id) |> Enum.map(&{&1.name, &1.uuid})
  end

  @doc "Sync project team memberships. `team_uuids` are user-supplied UUIDs."
  def sync_project_teams(project_id, team_uuids) do
    current_team_ids = get_project_team_ids(project_id)

    future_team_ids =
      team_uuids
      |> Enum.map(&Lynx.Context.TeamContext.get_team_id_with_uuid/1)
      |> Enum.filter(&(&1 != nil))

    for id <- current_team_ids, id not in future_team_ids do
      remove_project_from_team(project_id, id)
    end

    for id <- future_team_ids, id not in current_team_ids do
      add_project_to_team(project_id, id)
    end
  end
end

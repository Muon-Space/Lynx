defmodule Lynx.Context.RoleContext do
  @moduledoc """
  Role / Permission context — the gatekeeper for per-project authorization.

  Permissions are atomic strings (e.g. `"state:read"`). Roles bundle
  permissions and are stored in the database so they can be customized
  in the future. The seeded system roles are `planner`, `applier`, `admin`.

  Default role bundles (after migration `20260421000008`):

    * `planner` — `state:read`, `state:lock`, `state:unlock`. Lock + unlock
      are included because Terraform's `plan` always acquires a state lock
      by default; without them, planner can't actually run `terraform plan`.
    * `applier` — planner's set + `state:write`, `snapshot:create`.
    * `admin`   — applier's set + `snapshot:restore`, `env:manage`,
      `project:manage`, `access:manage`, `oidc_rule:manage`.

  Effective permission resolution for a user on a project unions:
    1. Permissions from every team the user belongs to that is attached to
       the project (each `project_teams` row carries its own role).
    2. Permissions from the user's individual `user_projects` row (if any).

  Global `super` users bypass all per-project checks.
  """

  import Ecto.Query

  alias Lynx.Repo
  alias Lynx.Model.{Project, ProjectTeam, Role, RolePermission, User, UserTeam}
  alias Lynx.Context.UserProjectContext

  @permissions ~w(
    state:read
    state:write
    state:lock
    state:unlock
    snapshot:create
    snapshot:restore
    env:manage
    project:manage
    access:manage
    oidc_rule:manage
  )

  @default_roles ~w(planner applier admin)

  @doc "All known permission strings, in canonical order."
  def permissions, do: @permissions

  @doc "Names of the system-seeded default roles."
  def default_roles, do: @default_roles

  # -- Read-side: roles + their permission bundles --

  @doc "Return all roles ordered by name."
  def list_roles do
    from(r in Role, order_by: [asc: r.name])
    |> Repo.all()
  end

  @doc "Look up a role by its name (e.g. \"applier\")."
  def get_role_by_name(name) do
    from(r in Role, where: r.name == ^name)
    |> limit(1)
    |> Repo.one()
  end

  @doc "Look up a role by UUID."
  def get_role_by_uuid(uuid) do
    from(r in Role, where: r.uuid == ^uuid)
    |> limit(1)
    |> Repo.one()
  end

  @doc "Look up a role by primary key."
  def get_role_by_id(id), do: Repo.get(Role, id)

  @doc """
  Return the set of permission strings granted by a role.
  Accepts either a role struct, a role id, or nil.
  """
  def permissions_for(nil), do: MapSet.new()
  def permissions_for(%Role{id: id}), do: permissions_for(id)

  def permissions_for(role_id) when is_integer(role_id) do
    from(rp in RolePermission, where: rp.role_id == ^role_id, select: rp.permission)
    |> Repo.all()
    |> MapSet.new()
  end

  # -- Permission resolution for users + OIDC rules --

  @doc """
  Return the set of permission strings that a user has on a project.
  Returns an empty MapSet if the user has no grants.
  """
  def effective_permissions(%User{role: "super"}, _project_or_id), do: MapSet.new(@permissions)

  def effective_permissions(%User{} = user, %Project{id: project_id}) do
    effective_permissions(user, project_id)
  end

  def effective_permissions(%User{id: user_id}, project_id) when is_integer(project_id) do
    team_role_ids = team_role_ids_for_user(user_id, project_id)
    individual_role_id = UserProjectContext.get_role_id_for(user_id, project_id)

    role_ids =
      [individual_role_id | team_role_ids]
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    union_permissions(role_ids)
  end

  def effective_permissions(_, _), do: MapSet.new()

  @doc "Permission set granted by an OIDC access rule (resolved through its role)."
  def permissions_for_oidc_rule(%{role_id: role_id}) when not is_nil(role_id),
    do: permissions_for(role_id)

  def permissions_for_oidc_rule(_), do: MapSet.new()

  @doc """
  Permission set granted to a static environment credential (legacy auth).
  Preserves today's full-access behavior for `username`/`secret` clients.
  """
  def permissions_for_env_credentials, do: MapSet.new(@permissions)

  @doc "True if the role's permission set contains the given permission."
  def can?(role_or_id, permission) when is_binary(permission) do
    role_id =
      case role_or_id do
        %_{id: id} ->
          id

        id when is_integer(id) ->
          id

        nil ->
          nil

        name when is_binary(name) ->
          case get_role_by_name(name) do
            nil -> nil
            r -> r.id
          end
      end

    case role_id do
      nil -> false
      id -> MapSet.member?(permissions_for(id), permission)
    end
  end

  @doc "True if the user has `permission` on the given project (or project_id)."
  def can?(%User{} = user, project_or_id, permission) when is_binary(permission) do
    MapSet.member?(effective_permissions(user, project_or_id), permission)
  end

  def can?(_, _, _), do: false

  @doc "True if `permissions` (a MapSet or list) contains the given permission."
  def has?(permissions, permission) when is_binary(permission) do
    cond do
      is_struct(permissions, MapSet) -> MapSet.member?(permissions, permission)
      is_list(permissions) -> permission in permissions
      true -> false
    end
  end

  @doc """
  List every project a user has access to and their effective role on it.

  Aggregates two paths:
    * Direct grants in `user_projects`
    * Indirect grants via teams the user belongs to (`user_teams` -> `project_teams`)

  Returns `[%{project: %Project{}, role_name: "applier", sources: ["direct", "via Team A"]}]`,
  one entry per project, with the role determined by the highest-permission-count
  role across all paths (so an admin team grant + a planner direct grant => admin).

  Sorted by project name. Returns `[]` for super users (their access is global,
  not enumerable from this table). Caller can decide how to render that case.
  """
  def list_user_project_access(%User{role: "super"}), do: []
  def list_user_project_access(%User{id: user_id}), do: list_user_project_access(user_id)

  def list_user_project_access(user_id) when is_integer(user_id) do
    alias Lynx.Model.{Team, UserProject}

    direct =
      from(up in UserProject,
        join: p in Project,
        on: p.id == up.project_id,
        join: r in Role,
        on: r.id == up.role_id,
        where: up.user_id == ^user_id,
        select: %{project: p, role: r, source: "direct"}
      )
      |> Repo.all()

    via_teams =
      from(pt in ProjectTeam,
        join: ut in UserTeam,
        on: ut.team_id == pt.team_id,
        join: p in Project,
        on: p.id == pt.project_id,
        join: r in Role,
        on: r.id == pt.role_id,
        join: t in Team,
        on: t.id == pt.team_id,
        where: ut.user_id == ^user_id,
        select: %{project: p, role: r, source: t.name}
      )
      |> Repo.all()

    role_rank_cache = build_role_rank_cache(direct, via_teams)

    (direct ++ via_teams)
    |> Enum.group_by(& &1.project.id)
    |> Enum.map(fn {_pid, entries} ->
      winner = Enum.max_by(entries, fn e -> Map.get(role_rank_cache, e.role.id, 0) end)

      sources =
        entries
        |> Enum.map(fn
          %{source: "direct"} -> "direct"
          %{source: team_name} -> "via #{team_name}"
        end)
        |> Enum.uniq()

      %{project: winner.project, role_name: winner.role.name, sources: sources}
    end)
    |> Enum.sort_by(& &1.project.name)
  end

  defp team_role_ids_for_user(user_id, project_id) do
    from(pt in ProjectTeam,
      join: ut in UserTeam,
      on: ut.team_id == pt.team_id,
      where: pt.project_id == ^project_id and ut.user_id == ^user_id,
      select: pt.role_id
    )
    |> Repo.all()
  end

  # Build a {role_id => permission_count} map so a single role's "weight" is
  # cached across the dedup loop. Permission count is a stable proxy for role
  # rank that also handles future custom roles without hard-coding names.
  defp build_role_rank_cache(direct, via_teams) do
    (direct ++ via_teams)
    |> Enum.map(& &1.role.id)
    |> Enum.uniq()
    |> Map.new(fn role_id -> {role_id, MapSet.size(permissions_for(role_id))} end)
  end

  defp union_permissions([]), do: MapSet.new()

  defp union_permissions(role_ids) do
    role_ids
    |> Enum.reduce(MapSet.new(), fn role_id, acc ->
      MapSet.union(acc, permissions_for(role_id))
    end)
  end
end

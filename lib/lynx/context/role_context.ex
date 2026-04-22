defmodule Lynx.Context.RoleContext do
  @moduledoc """
  Role / Permission context — the gatekeeper for per-project authorization.

  Permissions are atomic strings (e.g. `"state:read"`). Roles bundle
  permissions and are stored in the database so they can be customized
  in the future. The seeded system roles are `planner`, `applier`, `admin`.

  Default role bundles (after migration `20260421000009`):

    * `planner` — `state:read`, `state:lock`, `state:unlock`. Lock + unlock
      are included because Terraform's `plan` always acquires a state lock
      by default; without them, planner can't actually run `terraform plan`.
    * `applier` — planner's set + `state:write`, `snapshot:create`.
    * `admin`   — applier's set + `state:force_unlock`, `snapshot:restore`,
      `env:manage`, `project:manage`, `access:manage`, `oidc_rule:manage`.

  Note: `state:unlock` is the routine post-apply unlock (Terraform calls it
  automatically). `state:force_unlock` is the destructive admin-button
  variant that clears another user's lock — admin only.

  Effective permission resolution for a user on a project unions:
    1. Permissions from every team the user belongs to that is attached to
       the project (each `project_teams` row carries its own role).
    2. Permissions from the user's individual `user_projects` row (if any).

  Global `super` users bypass all per-project checks.
  """

  import Ecto.Query

  alias Lynx.Repo
  alias Lynx.Model.{Project, ProjectTeam, Role, RolePermission, User, UserTeam}

  @permissions ~w(
    state:read
    state:write
    state:lock
    state:unlock
    state:force_unlock
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

  # -- Custom role CRUD --

  @doc """
  Create a custom role with the given permission set.

  Returns `{:ok, role}` on success, `{:error, msg}` if the name is taken or
  the permission list contains unknown permissions. New roles always have
  `is_system: false` — system roles can only be created via migrations.
  """
  def create_role(attrs \\ %{}) do
    name = attrs[:name] || attrs["name"]
    description = attrs[:description] || attrs["description"] || ""
    permissions = attrs[:permissions] || attrs["permissions"] || []

    with :ok <- validate_permissions(permissions),
         {:ok, role} <-
           %Role{}
           |> Role.changeset(%{
             uuid: Ecto.UUID.generate(),
             name: name,
             description: description,
             is_system: false
           })
           |> Repo.insert() do
      :ok = replace_role_permissions(role.id, permissions)
      {:ok, role}
    else
      :unknown_permission -> {:error, "Unknown permission(s) in selection"}
      {:error, %Ecto.Changeset{} = cs} -> {:error, format_changeset_error(cs)}
    end
  end

  @doc """
  Update a custom role's name, description, and permission set.

  System roles are protected — `{:error, :system_role}` is returned for them.
  Permission changes are an atomic replace (delete + insert) inside a
  transaction.
  """
  def update_role(%Role{is_system: true}, _attrs), do: {:error, :system_role}

  def update_role(%Role{} = role, attrs) do
    permissions = attrs[:permissions] || attrs["permissions"]
    name = attrs[:name] || attrs["name"] || role.name
    description = attrs[:description] || attrs["description"] || role.description

    with :ok <- validate_permissions(permissions || []) do
      Repo.transaction(fn ->
        case role
             |> Role.changeset(%{name: name, description: description})
             |> Repo.update() do
          {:ok, updated} ->
            if permissions, do: :ok = replace_role_permissions(role.id, permissions)
            updated

          {:error, cs} ->
            Repo.rollback(format_changeset_error(cs))
        end
      end)
    else
      :unknown_permission -> {:error, "Unknown permission(s) in selection"}
    end
  end

  @doc """
  Delete a custom role.

  Refuses to delete system roles. The `role_permissions` rows go away via
  `on_delete: :delete_all`; the `:restrict` foreign keys on `project_teams`,
  `user_projects`, and `oidc_access_rules` will surface as `{:error, msg}`
  if the role is still referenced anywhere.
  """
  def delete_role(%Role{is_system: true}), do: {:error, :system_role}

  def delete_role(%Role{} = role) do
    case Repo.delete(role) do
      {:ok, _} ->
        :ok

      {:error, %Ecto.Changeset{} = cs} ->
        # The on_delete: :restrict FKs surface as a constraint error here.
        {:error, format_changeset_error(cs)}
    end
  rescue
    Ecto.ConstraintError ->
      {:error, "Role is in use — remove all team / user / OIDC grants first"}
  end

  @doc """
  Replace a role's permission set with `new_permissions` (a list of
  permission strings). Atomic: deletes existing rows, inserts the new set.
  Caller is responsible for validating the permissions first.
  """
  def replace_role_permissions(role_id, new_permissions) when is_list(new_permissions) do
    Repo.transaction(fn ->
      from(rp in RolePermission, where: rp.role_id == ^role_id)
      |> Repo.delete_all()

      rows =
        new_permissions
        |> Enum.uniq()
        |> Enum.map(fn perm ->
          %{
            role_id: role_id,
            permission: perm,
            inserted_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second),
            updated_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
          }
        end)

      if rows != [], do: Repo.insert_all(RolePermission, rows)
      :ok
    end)
    |> case do
      {:ok, :ok} -> :ok
      other -> other
    end
  end

  defp validate_permissions(permissions) when is_list(permissions) do
    bad = Enum.reject(permissions, fn p -> p in @permissions end)
    if bad == [], do: :ok, else: :unknown_permission
  end

  defp validate_permissions(_), do: :unknown_permission

  @doc """
  Count active grants of `role_id` across `project_teams`, `user_projects`,
  and `oidc_access_rules`. Used to flag roles as "in use" in the admin UI
  so an admin understands why delete is blocked.
  """
  def count_role_usage(role_id) when is_integer(role_id) do
    alias Lynx.Model.{OIDCAccessRule, ProjectTeam, UserProject}

    [
      from(pt in ProjectTeam, select: count(pt.id), where: pt.role_id == ^role_id),
      from(up in UserProject, select: count(up.id), where: up.role_id == ^role_id),
      from(o in OIDCAccessRule, select: count(o.id), where: o.role_id == ^role_id)
    ]
    |> Enum.map(&Repo.one/1)
    |> Enum.sum()
  end

  defp format_changeset_error(%Ecto.Changeset{errors: errors}) do
    errors
    |> Enum.map(fn {field, {message, _}} -> "#{field}: #{message}" end)
    |> Enum.at(0)
  end

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
    team_role_ids = team_role_ids_for_user(user_id, project_id, nil)
    individual_role_id = active_user_project_role_id(user_id, project_id, nil)

    role_ids =
      [individual_role_id | team_role_ids]
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    union_permissions(role_ids)
  end

  def effective_permissions(_, _), do: MapSet.new()

  @doc """
  Env-aware effective permissions (#32 per-environment overrides).

  Resolution order:

    1. If env-specific grants exist for `(user, project, env)`, union those.
    2. Otherwise fall back to project-wide grants (env_id IS NULL) — the
       legacy behavior preserved by the migration.

  This means an env-specific grant overrides project-wide grants **for
  that env**, never partial-overrides them. So if Team A has an admin
  project-wide grant and a planner override on prod, Team A is planner on
  prod (not admin ∪ planner). This matches the issue spec; if we ever
  want union semantics across both scopes, change `else` → "project
  perms also" below.

  Super users get all permissions (unchanged).
  """
  def effective_permissions(%User{role: "super"}, _project_or_id, _env),
    do: MapSet.new(@permissions)

  def effective_permissions(%User{} = user, %Project{id: project_id}, env),
    do: effective_permissions(user, project_id, env)

  def effective_permissions(%User{id: user_id}, project_id, env)
      when is_integer(project_id) do
    env_id = resolve_env_id(env)

    if env_id do
      env_team_ids = team_role_ids_for_user(user_id, project_id, env_id)
      env_individual_id = active_user_project_role_id(user_id, project_id, env_id)
      env_role_ids = Enum.reject([env_individual_id | env_team_ids], &is_nil/1)

      if env_role_ids == [] do
        # No env-specific grants → fall back to project-wide.
        effective_permissions(%User{id: user_id, role: "regular"}, project_id)
      else
        union_permissions(Enum.uniq(env_role_ids))
      end
    else
      # No env in scope → project-wide grants only (legacy 2-arg behavior).
      effective_permissions(%User{id: user_id, role: "regular"}, project_id)
    end
  end

  def effective_permissions(_, _, _), do: MapSet.new()

  defp resolve_env_id(nil), do: nil
  defp resolve_env_id(%Lynx.Model.Environment{id: id}), do: id
  defp resolve_env_id(id) when is_integer(id), do: id
  defp resolve_env_id(_), do: nil

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

  # `env_id`: nil = project-wide grants only (env_id IS NULL); integer =
  # env-specific grants (env_id matches). Always filters expired rows.
  defp team_role_ids_for_user(user_id, project_id, env_id) do
    now = DateTime.utc_now()

    base =
      from(pt in ProjectTeam,
        join: ut in UserTeam,
        on: ut.team_id == pt.team_id,
        where: pt.project_id == ^project_id and ut.user_id == ^user_id,
        where: is_nil(pt.expires_at) or pt.expires_at > ^now,
        select: pt.role_id
      )

    base
    |> scope_to_env(env_id, :pt)
    |> Repo.all()
  end

  # User's direct grant on a project, filtered by expiry + env scope.
  defp active_user_project_role_id(user_id, project_id, env_id) do
    alias Lynx.Model.UserProject
    now = DateTime.utc_now()

    base =
      from(up in UserProject,
        where: up.user_id == ^user_id and up.project_id == ^project_id,
        where: is_nil(up.expires_at) or up.expires_at > ^now,
        select: up.role_id,
        limit: 1
      )

    base
    |> scope_to_env(env_id, :up)
    |> Repo.one()
  end

  defp scope_to_env(query, nil, _),
    do: from([row] in query, where: is_nil(row.environment_id))

  defp scope_to_env(query, env_id, _) when is_integer(env_id),
    do: from([row] in query, where: row.environment_id == ^env_id)

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

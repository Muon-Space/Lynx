defmodule Lynx.Module.RoleModule do
  @moduledoc """
  Role / Permission Module — the gatekeeper for per-project authorization.

  Permissions are atomic strings (e.g. `"state:read"`). Roles bundle
  permissions and are stored in the database so they can be customized
  in the future. The seeded system roles are `planner`, `applier`, `admin`.

  Effective permission resolution for a user on a project unions:
    1. Permissions from every team the user belongs to that is attached to
       the project (each `project_teams` row carries its own role).
    2. Permissions from the user's individual `user_projects` row (if any).

  Global `super` users bypass all per-project checks.
  """

  import Ecto.Query

  alias Lynx.Repo
  alias Lynx.Model.{UserTeam, ProjectTeam, User, Project}
  alias Lynx.Context.RoleContext
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

  @doc """
  Permission set granted by an OIDC access rule (resolved through its role).
  """
  def permissions_for_oidc_rule(%{role_id: role_id}) when not is_nil(role_id) do
    RoleContext.permissions_for(role_id)
  end

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
          RoleContext.get_role_by_name(name)
          |> case do
            nil -> nil
            r -> r.id
          end
      end

    case role_id do
      nil -> false
      id -> MapSet.member?(RoleContext.permissions_for(id), permission)
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

  defp team_role_ids_for_user(user_id, project_id) do
    from(pt in ProjectTeam,
      join: ut in UserTeam,
      on: ut.team_id == pt.team_id,
      where: pt.project_id == ^project_id and ut.user_id == ^user_id,
      select: pt.role_id
    )
    |> Repo.all()
  end

  defp union_permissions([]), do: MapSet.new()

  defp union_permissions(role_ids) do
    role_ids
    |> Enum.reduce(MapSet.new(), fn role_id, acc ->
      MapSet.union(acc, RoleContext.permissions_for(role_id))
    end)
  end
end

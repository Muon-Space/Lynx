defmodule Lynx.Context.RoleContext do
  @moduledoc """
  Role Context — read-side access to roles and their permission bundles.

  Roles are seeded by migration. Custom role CRUD is intentionally not
  exposed here yet; add it when the corresponding admin UI ships.
  """

  import Ecto.Query

  alias Lynx.Repo
  alias Lynx.Model.{Role, RolePermission}

  @doc """
  Return all roles ordered by name.
  """
  def list_roles do
    from(r in Role, order_by: [asc: r.name])
    |> Repo.all()
  end

  @doc """
  Look up a role by its name (e.g. "applier").
  """
  def get_role_by_name(name) do
    from(r in Role, where: r.name == ^name)
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  Look up a role by UUID.
  """
  def get_role_by_uuid(uuid) do
    from(r in Role, where: r.uuid == ^uuid)
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  Look up a role by primary key.
  """
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
end

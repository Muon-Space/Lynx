defmodule Lynx.Context.PolicyContext do
  @moduledoc """
  CRUD + lookup for OPA Rego policies attached to a project or env.
  Effective set for an env = its env-scoped policies ∪ its project's
  policies, both filtered to `enabled: true`.
  """

  import Ecto.Query

  alias Lynx.Repo
  alias Lynx.Model.{Environment, Policy}

  @doc "Build a new attrs map with a UUID stamped on. Mirrors the other contexts' new_X/1."
  def new_policy(attrs \\ %{}) do
    %{
      uuid: Map.get(attrs, :uuid, Ecto.UUID.generate()),
      name: attrs[:name],
      description: Map.get(attrs, :description, ""),
      rego_source: attrs[:rego_source],
      enabled: Map.get(attrs, :enabled, true),
      project_id: Map.get(attrs, :project_id),
      environment_id: Map.get(attrs, :environment_id)
    }
  end

  def create_policy(attrs) do
    %Policy{}
    |> Policy.changeset(attrs)
    |> Repo.insert()
  end

  def update_policy(%Policy{} = policy, attrs) do
    policy
    |> Policy.changeset(attrs)
    |> Repo.update()
  end

  def delete_policy(%Policy{} = policy), do: Repo.delete(policy)

  def get_policy_by_uuid(uuid) do
    from(p in Policy, where: p.uuid == ^uuid) |> Repo.one()
  end

  def get_policy_by_id(id), do: Repo.get(Policy, id)

  def list_policies_by_project(project_id) do
    from(p in Policy,
      where: p.project_id == ^project_id,
      order_by: [asc: p.name]
    )
    |> Repo.all()
  end

  def list_policies_by_environment(env_id) do
    from(p in Policy,
      where: p.environment_id == ^env_id,
      order_by: [asc: p.name]
    )
    |> Repo.all()
  end

  @doc """
  All enabled policies that apply to the given environment id — env-scoped
  + project-scoped (via the env's project), in stable order.
  """
  def list_effective_policies_for_env(env_id) when is_integer(env_id) do
    project_id_query = from(e in Environment, where: e.id == ^env_id, select: e.project_id)

    from(p in Policy,
      where:
        p.enabled == true and
          (p.environment_id == ^env_id or
             p.project_id in subquery(project_id_query)),
      order_by: [asc: p.name]
    )
    |> Repo.all()
  end

  def count_policies do
    from(p in Policy, select: count(p.id)) |> Repo.one()
  end

  @doc "All enabled policies — used by `OPABundle` to assemble the OPA tarball."
  def list_enabled_policies do
    from(p in Policy,
      where: p.enabled == true,
      order_by: [asc: p.uuid]
    )
    |> Repo.all()
  end

  @doc """
  Greatest `updated_at` across all enabled policies. The bundle controller
  uses this as the ETag so polling OPA short-circuits unchanged bodies
  without us re-zipping the tarball every poll.
  """
  def latest_enabled_update_at do
    from(p in Policy, where: p.enabled == true, select: max(p.updated_at)) |> Repo.one()
  end
end

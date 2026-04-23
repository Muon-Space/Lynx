defmodule Lynx.Context.PolicyContext do
  @moduledoc """
  CRUD + lookup for OPA Rego policies. A policy is attached at exactly
  one of four scopes — global / workspace / project / environment — and
  the effective set evaluated for an env unions all four.
  """

  import Ecto.Query
  require Logger

  alias Lynx.Repo
  alias Lynx.Model.{AuditEvent, Environment, PlanCheck, Policy, Project, Workspace}
  alias Lynx.Service.PolicyEngine

  @doc "Build a new attrs map with a UUID stamped on. Mirrors the other contexts' new_X/1."
  def new_policy(attrs \\ %{}) do
    %{
      uuid: Map.get(attrs, :uuid, Ecto.UUID.generate()),
      name: attrs[:name],
      description: Map.get(attrs, :description, ""),
      rego_source: attrs[:rego_source],
      enabled: Map.get(attrs, :enabled, true),
      workspace_id: Map.get(attrs, :workspace_id),
      project_id: Map.get(attrs, :project_id),
      environment_id: Map.get(attrs, :environment_id)
    }
  end

  def create_policy(attrs) do
    %Policy{}
    |> Policy.changeset(attrs)
    |> with_rego_validation()
    |> case do
      {:ok, changeset} -> Repo.insert(changeset)
      {:error, _} = err -> err
    end
  end

  def update_policy(%Policy{} = policy, attrs) do
    policy
    |> Policy.changeset(attrs)
    |> with_rego_validation()
    |> case do
      {:ok, changeset} -> Repo.update(changeset)
      {:error, _} = err -> err
    end
  end

  # Server-side defense-in-depth (issue #38). The UI live-validates while
  # the user types, but anything writing through the context (admin form,
  # future REST API, seeds, future SCIM-like provisioning) must also have
  # its rego compile-checked by OPA before we persist it.
  #
  # Strict fail-closed on every non-:ok result:
  #   * `:ok`           — continue with the regular changeset path
  #   * `{:invalid, _}` — OPA returned compile errors. Surface them on
  #     `:rego_source` as changeset errors.
  #   * `{:error, _}`   — OPA was unreachable. Block the save with a
  #     clear error so operators know we couldn't validate. Saving an
  #     unvalidated policy would just defer the failure to evaluation
  #     time, and could break the bundle for every other env. Better to
  #     surface the dependency on OPA explicitly.
  defp with_rego_validation(%Ecto.Changeset{valid?: false} = changeset),
    do: {:error, changeset}

  defp with_rego_validation(%Ecto.Changeset{} = changeset) do
    rego =
      Ecto.Changeset.get_change(changeset, :rego_source) ||
        Ecto.Changeset.get_field(changeset, :rego_source)

    case PolicyEngine.validate(rego || "") do
      :ok ->
        {:ok, changeset}

      {:invalid, errors} ->
        msg =
          errors
          |> Enum.map_join("; ", fn e ->
            loc =
              cond do
                e[:row] && e[:col] -> "line #{e.row}:#{e.col}: "
                e[:row] -> "line #{e.row}: "
                true -> ""
              end

            loc <> e.message
          end)

        {:error, Ecto.Changeset.add_error(changeset, :rego_source, msg)}

      {:error, reason} ->
        Logger.warning(
          "Policy save blocked: OPA unreachable (#{inspect(reason)}); refusing to save unvalidated rego"
        )

        {:error,
         Ecto.Changeset.add_error(
           changeset,
           :rego_source,
           "OPA is unreachable, can't validate this policy. Bring OPA back up before saving."
         )}
    end
  end

  def delete_policy(%Policy{} = policy), do: Repo.delete(policy)

  def get_policy_by_uuid(uuid) do
    from(p in Policy, where: p.uuid == ^uuid) |> Repo.one()
  end

  def get_policy_by_id(id), do: Repo.get(Policy, id)

  def list_policies_global do
    from(p in Policy,
      where: is_nil(p.workspace_id) and is_nil(p.project_id) and is_nil(p.environment_id),
      order_by: [asc: p.name]
    )
    |> Repo.all()
  end

  def list_policies_by_workspace(workspace_id) do
    from(p in Policy,
      where: p.workspace_id == ^workspace_id,
      order_by: [asc: p.name]
    )
    |> Repo.all()
  end

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
  All enabled policies that apply to the given environment id — unions
  global, workspace-scoped, project-scoped (via env's project), and
  env-scoped policies, in stable order.
  """
  def list_effective_policies_for_env(env_id) when is_integer(env_id) do
    project_id_query = from(e in Environment, where: e.id == ^env_id, select: e.project_id)

    workspace_id_query =
      from(e in Environment,
        join: pr in Project,
        on: pr.id == e.project_id,
        where: e.id == ^env_id,
        select: pr.workspace_id
      )

    from(p in Policy,
      where:
        p.enabled == true and
          (p.environment_id == ^env_id or
             p.project_id in subquery(project_id_query) or
             p.workspace_id in subquery(workspace_id_query) or
             (is_nil(p.workspace_id) and is_nil(p.project_id) and is_nil(p.environment_id))),
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

  @doc """
  For a list of policy UUIDs (e.g. ones extracted from plan_check
  violations), build `%{uuid => "/admin/.../policies?edit=<uuid>"}` so a
  caller can render each as a deep link to the exact edit page. Missing
  / deleted policies are omitted from the map.

  Three batched lookups (envs+projects join, projects, workspaces) — no
  N+1 even when the violations list spans every scope.
  """
  def get_link_targets_by_uuids([]), do: %{}

  def get_link_targets_by_uuids(uuids) when is_list(uuids) do
    policies = from(p in Policy, where: p.uuid in ^uuids) |> Repo.all()

    env_ids = Enum.flat_map(policies, &maybe_id(&1.environment_id))
    project_ids = Enum.flat_map(policies, &maybe_id(&1.project_id))
    workspace_ids = Enum.flat_map(policies, &maybe_id(&1.workspace_id))

    envs =
      from(e in Environment,
        join: pr in Project,
        on: pr.id == e.project_id,
        where: e.id in ^env_ids,
        select: {e.id, %{env_uuid: e.uuid, project_uuid: pr.uuid}}
      )
      |> Repo.all()
      |> Map.new()

    projects =
      from(p in Project, where: p.id in ^project_ids, select: {p.id, p.uuid})
      |> Repo.all()
      |> Map.new()

    workspaces =
      from(w in Workspace, where: w.id in ^workspace_ids, select: {w.id, w.uuid})
      |> Repo.all()
      |> Map.new()

    policies
    |> Enum.map(fn p -> {p.uuid, build_link_for(p, envs, projects, workspaces)} end)
    |> Enum.reject(fn {_, url} -> is_nil(url) end)
    |> Map.new()
  end

  defp maybe_id(nil), do: []
  defp maybe_id(id), do: [id]

  # Every scope routes to the same per-policy detail page. The detail
  # page knows how to navigate back to the scope-specific edit form via
  # an "Edit" button, so we don't need to encode scope in the URL here.
  defp build_link_for(%Policy{uuid: uuid}, _envs, _projects, _workspaces),
    do: "/admin/policies/#{uuid}"

  @doc """
  Recent block events that fired this policy. Returns a list of
  normalized `%{kind, when, env, sub_path, actor, messages, link}` maps
  blending two sources, sorted newest-first:

    * `plan_checks` rows whose `violations` JSON references this policy
      uuid (kind = `:plan_check`)
    * `audit_events` with `action = "apply_blocked"` whose `metadata.policies`
      list includes this policy (kind = `:apply_blocked`)

  Both sources store JSON in TEXT columns, so the lookup uses a `LIKE
  '%<uuid>%'` against the raw column text. Policy UUIDs are distinctive
  enough that false positives are vanishingly rare. Limit applied per
  source then merged.
  """
  def recent_blocks_for_policy(%Policy{uuid: uuid}, limit \\ 25) do
    pattern = "%#{uuid}%"

    # plan_checks: pull recent rows containing this policy's UUID in the
    # violations JSON. Join env+project+workspace so we can build a
    # back-link to the env page on display.
    plan_check_rows =
      from(p in PlanCheck,
        join: e in Environment,
        on: e.id == p.environment_id,
        join: pr in Project,
        on: pr.id == e.project_id,
        join: w in Workspace,
        on: w.id == pr.workspace_id,
        where:
          p.outcome != "passed" and
            ilike(p.violations, ^pattern),
        order_by: [desc: p.id],
        limit: ^limit,
        select: %{
          kind: "plan_check",
          when: p.inserted_at,
          env: e,
          project: pr,
          workspace: w,
          sub_path: p.sub_path,
          actor_name: p.actor_name,
          actor_type: p.actor_type,
          violations: p.violations,
          outcome: p.outcome,
          consumed_at: p.consumed_at
        }
      )
      |> Repo.all()

    apply_blocked_rows =
      from(a in AuditEvent,
        # `audit_events.resource_id` is a varchar (it sometimes carries
        # non-UUID slug paths from `/tf/*` events). For our apply_blocked
        # rows it's always env.uuid, but we still need to cast one side
        # explicitly so Postgres accepts the join — uuid → text avoids
        # any cast-failure risk on rows we don't care about.
        left_join: e in Environment,
        on: fragment("?::text = ?", e.uuid, a.resource_id),
        left_join: pr in Project,
        on: pr.id == e.project_id,
        left_join: w in Workspace,
        on: w.id == pr.workspace_id,
        where:
          a.action == "apply_blocked" and
            ilike(a.metadata, ^pattern),
        order_by: [desc: a.id],
        limit: ^limit,
        select: %{
          kind: "apply_blocked",
          when: a.inserted_at,
          env: e,
          project: pr,
          workspace: w,
          actor_name: a.actor_name,
          actor_type: a.actor_type,
          metadata: a.metadata
        }
      )
      |> Repo.all()

    (plan_check_rows ++ apply_blocked_rows)
    |> Enum.sort_by(& &1.when, {:desc, NaiveDateTime})
    |> Enum.take(limit)
  end
end

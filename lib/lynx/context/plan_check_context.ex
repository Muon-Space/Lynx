defmodule Lynx.Context.PlanCheckContext do
  @moduledoc """
  Records and queries `plan_checks` rows. Used by:

    * the `POST /tf/.../plan` endpoint to persist the eval outcome
    * the apply gate to find a recent passing check from the same actor
    * the env page's plan history card to render recent activity

  Single-use semantics: `consume!/1` atomically marks a row consumed via a
  conditional UPDATE so two concurrent state-writes can't both spend the
  same passing check.
  """

  import Ecto.Query

  alias Lynx.Repo
  alias Lynx.Model.PlanCheck

  def new_plan_check(attrs \\ %{}) do
    %{
      uuid: Map.get(attrs, :uuid, Ecto.UUID.generate()),
      environment_id: attrs[:environment_id],
      sub_path: Map.get(attrs, :sub_path, ""),
      outcome: attrs[:outcome],
      violations: Map.get(attrs, :violations, "[]"),
      plan_json: attrs[:plan_json],
      actor_signature: attrs[:actor_signature],
      actor_name: Map.get(attrs, :actor_name),
      actor_type: attrs[:actor_type],
      consumed_at: Map.get(attrs, :consumed_at)
    }
  end

  def create_plan_check(attrs) do
    %PlanCheck{}
    |> PlanCheck.changeset(attrs)
    |> Repo.insert()
  end

  def get_plan_check_by_uuid(uuid) do
    from(p in PlanCheck, where: p.uuid == ^uuid) |> Repo.one()
  end

  @doc """
  Same query as `latest_unconsumed_passing/3` but documented as a
  read-only peek — used by the lock-time pre-check that decides whether
  to even acquire the lock for an apply. The actual `consume/1` still
  fires later at state-write time so a failed apply doesn't waste the
  approval.
  """
  def peek_recent_passing(env_id, sub_path, actor_signature),
    do: latest_unconsumed_passing(env_id, sub_path, actor_signature)

  @doc """
  Most recent unconsumed passing check for `(env, sub_path, actor_signature)`.
  Returns nil if nothing matches.
  """
  def latest_unconsumed_passing(env_id, sub_path, actor_signature) do
    from(p in PlanCheck,
      where:
        p.environment_id == ^env_id and
          p.sub_path == ^sub_path and
          p.actor_signature == ^actor_signature and
          p.outcome == "passed" and
          is_nil(p.consumed_at),
      order_by: [desc: p.id],
      limit: 1
    )
    |> Repo.one()
  end

  @doc """
  Atomically mark a row consumed. Returns `{:ok, plan_check}` if the row
  was still available; `:already_consumed` if a concurrent caller spent
  it first. The conditional UPDATE means we never double-spend.
  """
  def consume(%PlanCheck{id: id}) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {count, _} =
      from(p in PlanCheck, where: p.id == ^id and is_nil(p.consumed_at))
      |> Repo.update_all(set: [consumed_at: now, updated_at: now])

    case count do
      1 -> {:ok, Repo.get!(PlanCheck, id)}
      0 -> :already_consumed
    end
  end

  @doc "Recent plan checks for an env, newest first. Used by the env page history card."
  def list_for_env(env_id, limit \\ 25) do
    from(p in PlanCheck,
      where: p.environment_id == ^env_id,
      order_by: [desc: p.id],
      limit: ^limit
    )
    |> Repo.all()
  end
end

defmodule Lynx.Service.StateRollback do
  @moduledoc """
  Roll a state (one environment root or unit) back to an earlier stored
  version.

  A rollback is a write, not a rewind, the same as `vault kv rollback`:
  it appends a new version whose body is a copy of the target version and
  leaves every existing row alone. The rollback is itself a version you
  can diff, and rolling back a rollback is just another rollback.

  Rules:

    * **Serial fixup.** The copied body would carry the target's old
      `serial`, lower than the current one. The new version gets
      `serial = current + 1` and keeps the current `lineage`, which is
      what `terraform state push -force` would otherwise have to paper
      over.
    * **Lock interlock.** Refused while an exclusive lock blocks the path
      (a running apply, or a manual lock). The write itself happens under
      a short exclusive lock of its own, so an apply that starts at the
      same moment gets a normal 423 instead of losing its update.
    * **Policies.** The new body is evaluated like a Terraform state push
      when `block_violating_apply` is on for the env, so nothing lands
      unevaluated.
    * **Retention.** The write goes through `StateContext.append_state/4`,
      so `state_retention_count` applies and each rollback evicts the
      oldest version when retention is on.

  Rolling back state does not touch infrastructure. The next plan sees the
  difference between the restored state and what actually exists.
  """

  import Ecto.Query

  alias Lynx.Context.{LockContext, StateContext}
  alias Lynx.Model.{Environment, State}
  alias Lynx.Repo
  alias Lynx.Service.PolicyGate

  @lock_operation "LynxStateRollback"

  @doc "The `Operation` recorded on the short lock a rollback write holds."
  def lock_operation, do: @lock_operation

  @doc """
  Roll `env`'s state back to the version identified by `target_uuid`.
  The version's own `sub_path` decides which unit is rolled back.

  Returns `{:ok, result}` where `result` has `:state` (the new version),
  `:source` (the copied version), `:previous` (the version that was
  current), `:serial`, `:source_version` and `:version` (1-based version
  numbers as the State Explorer shows them), or one of:

    * `{:error, :not_found}`: no such version in this environment
    * `{:error, :already_current}`: the target is already the latest
    * `{:error, {:invalid_state, message}}`: a body is not a JSON object
    * `{:error, {:locked, lock}}`: an exclusive lock blocks the path
    * `{:error, {:policy_violation, message, policies}}`
  """
  def rollback(%Environment{} = env, target_uuid, who) when is_binary(target_uuid) do
    with {:ok, target} <- fetch_target(env, target_uuid),
         {:ok, current} <- fetch_current(env, target.sub_path),
         :ok <- ensure_not_current(target, current),
         {:ok, body, serial} <- build_body(target, current),
         :ok <- ensure_unlocked(env, target.sub_path),
         :ok <- check_policies(env, body) do
      source_version = version_number(env.id, target)

      case write_under_lock(env, target, body, who) do
        {:ok, state} ->
          {:ok,
           %{
             state: state,
             source: target,
             previous: current,
             serial: serial,
             source_version: source_version,
             version: StateContext.count_states_by_path(env.id, target.sub_path)
           }}

        error ->
          error
      end
    end
  end

  def rollback(_env, _target_uuid, _who), do: {:error, :not_found}

  @doc """
  Metadata for the `state_rolled_back` audit event: which version was
  copied, which one was current, and the version that was written.
  """
  def audit_metadata(%{state: state, source: source, previous: previous} = result) do
    %{
      "sub_path" => state.sub_path || "",
      "from_state_uuid" => source.uuid,
      "from_version" => result.source_version,
      "previous_state_uuid" => previous.uuid,
      "new_state_uuid" => state.uuid,
      "new_version" => result.version,
      "serial" => result.serial
    }
  end

  @doc "Human-readable reason for a lock refusal."
  def lock_message(lock) do
    who = if lock.who in [nil, ""], do: "another client", else: lock.who

    "State is locked (#{lock.operation || "lock"} held by #{who}). Wait for it to finish or unlock it first."
  end

  defp fetch_target(env, uuid) do
    with {:ok, _} <- Ecto.UUID.cast(uuid),
         %State{environment_id: env_id} = state when env_id == env.id <-
           StateContext.get_state_by_uuid(uuid) do
      {:ok, state}
    else
      _ -> {:error, :not_found}
    end
  end

  defp fetch_current(env, sub_path) do
    case StateContext.get_latest_state_by_environment_and_path(env.id, sub_path || "") do
      nil -> {:error, :not_found}
      state -> {:ok, state}
    end
  end

  defp ensure_not_current(%State{id: id}, %State{id: id}), do: {:error, :already_current}
  defp ensure_not_current(_, _), do: :ok

  defp build_body(target, current) do
    with {:ok, target_map} <- decode(target.value, "target version"),
         {:ok, current_map} <- decode(current.value, "current version") do
      serial = max(int_or_zero(current_map["serial"]), int_or_zero(target_map["serial"])) + 1

      body =
        case current_map["lineage"] do
          lineage when is_binary(lineage) and lineage != "" ->
            Map.put(target_map, "lineage", lineage)

          _ ->
            target_map
        end
        |> Map.put("serial", serial)

      {:ok, body, serial}
    end
  end

  defp decode(value, label) do
    case Jason.decode(value || "") do
      {:ok, map} when is_map(map) -> {:ok, map}
      _ -> {:error, {:invalid_state, "The #{label} is not a JSON object"}}
    end
  end

  defp int_or_zero(n) when is_integer(n), do: n
  defp int_or_zero(_), do: 0

  defp ensure_unlocked(env, sub_path) do
    case LockContext.blocking_lock(env.id, sub_path) do
      nil -> :ok
      lock -> {:error, {:locked, lock}}
    end
  end

  defp check_policies(env, body) do
    case PolicyGate.state_violations(env, body) do
      :ok -> :ok
      {:blocked, msg, policies} -> {:error, {:policy_violation, msg, policies}}
    end
  end

  # Hold an exclusive lock on the path for the duration of the insert. The
  # partial unique index on active exclusive locks makes this the same
  # guarantee Terraform gets: if an apply locked the path after
  # `ensure_unlocked/2`, the insert loses and the caller gets `:locked`.
  defp write_under_lock(env, target, body, who) do
    sub_path = target.sub_path || ""

    lock_attrs =
      LockContext.new_lock(%{
        environment_id: env.id,
        operation: @lock_operation,
        info: "State rollback to #{target.uuid}",
        who: who || "",
        version: "lynx",
        path: "",
        sub_path: sub_path,
        uuid: Ecto.UUID.generate(),
        is_active: true
      })

    case LockContext.create_lock(lock_attrs) do
      {:ok, lock} ->
        try do
          case StateContext.append_state(
                 env.id,
                 sub_path,
                 target.name || "_tf_state_",
                 Jason.encode!(body)
               ) do
            {:ok, state} ->
              {:ok, state}

            {:error, changeset} ->
              messages =
                Enum.map(changeset.errors, fn {f, {m, _}} -> "#{f}: #{m}" end)

              {:error, {:invalid_state, Enum.at(messages, 0)}}
          end
        after
          LockContext.update_lock(lock, %{is_active: false})
        end

      {:error, _changeset} ->
        case LockContext.blocking_lock(env.id, sub_path) do
          nil -> {:error, {:invalid_state, "Could not lock the state for rollback"}}
          lock -> {:error, {:locked, lock}}
        end
    end
  end

  # 1-based position of `state` among its path's remaining versions, the
  # `vN` label the State Explorer shows.
  defp version_number(env_id, %State{id: id, sub_path: sub_path}) do
    from(s in State,
      select: count(s.id),
      where: s.environment_id == ^env_id,
      where: s.sub_path == ^(sub_path || ""),
      where: s.id <= ^id
    )
    |> Repo.one()
  end
end

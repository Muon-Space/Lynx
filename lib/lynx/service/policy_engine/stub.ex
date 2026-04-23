defmodule Lynx.Service.PolicyEngine.Stub do
  @moduledoc """
  In-memory PolicyEngine for tests.

  Tests register a `(policy_uuid, fn input -> [violations] end)` pair via
  `register/2`; calls to `eval_deny/2` look up the function and run it.
  Unregistered policies return `{:error, :unknown_policy}` so tests can
  also assert engine-level failure paths.

  State lives in an `Agent` registered under the module name so any test
  process can read or mutate it.
  """

  @behaviour Lynx.Service.PolicyEngine

  use Agent

  def start_link(_opts \\ []) do
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  @doc "Reset the stub between tests."
  def reset do
    ensure_started()
    Agent.update(__MODULE__, fn _ -> %{} end)
  end

  @doc """
  Register a policy by UUID. `deny_fn` receives the OPA `input` map and
  returns a list of violation strings.
  """
  def register(uuid, deny_fn) when is_binary(uuid) and is_function(deny_fn, 1) do
    ensure_started()
    Agent.update(__MODULE__, &Map.put(&1, uuid, deny_fn))
  end

  @doc """
  Force `eval_deny/2` to return `{:error, reason}` for a given policy
  UUID — useful for engine-failure tests.
  """
  def fail(uuid, reason \\ :stub_error) when is_binary(uuid) do
    ensure_started()
    Agent.update(__MODULE__, &Map.put(&1, uuid, {:fail, reason}))
  end

  @impl true
  def eval_deny(uuid, input) do
    ensure_started()

    case Agent.get(__MODULE__, &Map.get(&1, uuid)) do
      nil -> {:error, :unknown_policy}
      {:fail, reason} -> {:error, reason}
      fun when is_function(fun, 1) -> {:ok, List.wrap(fun.(input))}
    end
  end

  defp ensure_started do
    case Process.whereis(__MODULE__) do
      nil -> start_link([])
      _ -> :ok
    end
  end
end

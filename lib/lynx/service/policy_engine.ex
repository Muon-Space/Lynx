defmodule Lynx.Service.PolicyEngine do
  @moduledoc """
  Behaviour for the policy engine that evaluates a Terraform plan against
  a Lynx policy and returns the list of `deny[msg]` violation strings.

  Two implementations:

    * `Lynx.Service.PolicyEngine.OPA` — talks to a real OPA over HTTP via
      the bundle pattern. Production default.
    * `Lynx.Service.PolicyEngine.Stub` — in-memory, used in tests so the
      suite stays runnable without an OPA binary on PATH.

  Selected at runtime from `:lynx, :policy_engine`. Callers should use
  `eval_deny/2` here, not the impls directly, so tests can swap freely.
  """

  @type policy_uuid :: String.t()
  @type input :: map()
  @type violation :: String.t()
  @type validation_error :: %{message: String.t(), row: integer() | nil, col: integer() | nil}

  @callback eval_deny(policy_uuid, input) ::
              {:ok, [violation]} | {:error, term()}

  @callback validate(rego_source :: String.t()) ::
              :ok | {:invalid, [validation_error]} | {:error, term()}

  @doc """
  Evaluate `policy_uuid`'s `deny[msg]` rule against `input`. Returns
  `{:ok, []}` for a passing policy and `{:ok, [msg, ...]}` for violations.
  `{:error, reason}` for engine-level failures (OPA unreachable, policy
  unknown, etc.).
  """
  def eval_deny(policy_uuid, input) do
    impl().eval_deny(policy_uuid, input)
  end

  @doc """
  Validate Rego source. Returns `:ok` if the source compiles, `{:invalid,
  errors}` for parse/compile failures with line+column info, or
  `{:error, reason}` for engine-level failures (OPA unreachable). The UI
  treats `{:error, _}` as "couldn't validate, allow save with warning";
  `{:invalid, _}` blocks save.
  """
  def validate(rego_source) do
    impl().validate(rego_source)
  end

  @doc "The configured implementation. Tests swap via `Application.put_env/3`."
  def impl do
    Application.get_env(:lynx, :policy_engine, Lynx.Service.PolicyEngine.OPA)
  end
end

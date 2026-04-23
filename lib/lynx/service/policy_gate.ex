defmodule Lynx.Service.PolicyGate do
  @moduledoc """
  Resolves policy-enforcement settings into the effective values used at
  state-write time (issue #38 follow-up).

  Two orthogonal toggles, each with global default + per-env override:

    * **`require_passing_plan`** — apply must be preceded by a passing
      `POST /tf/.../plan` upload from the same actor.
    * **`block_violating_apply`** — at state-write, evaluate the new
      state body against effective policies; reject if any deny[msg].

  Resolution per env: explicit `true`/`false` on the env wins; otherwise
  fall back to the global config value (defaults to `false`). The
  per-env values are nullable booleans; nil means "inherit".

  Synthesizes a plan-shaped input from a Terraform JSON state body so
  the same policies authors wrote against `input.resource_changes[]` for
  plan-check also evaluate at apply-block time. All synthesised changes
  are tagged `actions: ["update"]` since we only have the after-state.
  """

  alias Lynx.Model.Environment
  alias Lynx.Service.Settings

  @global_keys [:require_passing_plan, :block_violating_apply]

  @doc """
  Effective gate settings for an env. Returns a map with both toggles
  resolved to a definite boolean + their inheritance source.
  """
  def effective(%Environment{} = env) do
    %{
      require_passing_plan: %{
        value: resolve(env.require_passing_plan, :require_passing_plan),
        source: source(env.require_passing_plan)
      },
      block_violating_apply: %{
        value: resolve(env.block_violating_apply, :block_violating_apply),
        source: source(env.block_violating_apply)
      },
      plan_max_age_seconds: env.plan_max_age_seconds
    }
  end

  @doc "Convenience: just the require_passing_plan boolean for an env."
  def require_passing_plan?(%Environment{} = env),
    do: resolve(env.require_passing_plan, :require_passing_plan)

  @doc "Convenience: just the block_violating_apply boolean for an env."
  def block_violating_apply?(%Environment{} = env),
    do: resolve(env.block_violating_apply, :block_violating_apply)

  @doc "Read a global default from the configs table; returns boolean."
  def global_default(key) when key in @global_keys do
    Settings.get_config(config_key(key), "false") == "true"
  end

  @doc "Update a global default. `value` is a boolean."
  def set_global_default(key, value) when key in @global_keys and is_boolean(value) do
    Settings.upsert_config(config_key(key), to_string(value))
  end

  @doc """
  Synthesize a plan-shaped OPA input from a Terraform JSON state body.
  Each resource instance becomes a `resource_changes[]` entry tagged as
  an "update" with the resource attributes as `change.after`. Lets
  policies that filter on `input.resource_changes[]` work for both
  plan-check AND apply-block enforcement.

  Accepts either a pre-decoded state map (state-write path already has
  the params parsed by Plug) or a JSON-encoded binary (other callers).
  """
  def state_to_plan_input(state_body) when is_binary(state_body) do
    case Jason.decode(state_body) do
      {:ok, state} when is_map(state) -> state_to_plan_input(state)
      _ -> empty_input()
    end
  end

  def state_to_plan_input(%{"resources" => resources} = state) when is_list(resources) do
    %{
      "format_version" => "1.2",
      "terraform_version" => Map.get(state, "terraform_version", "unknown"),
      "_lynx_synthetic" => true,
      "resource_changes" => Enum.flat_map(resources, &resource_to_changes/1)
    }
  end

  # Empty / malformed state — nothing to evaluate. Treat as no-op
  # (zero changes); policies that look only at resource_changes[]
  # produce no violations on this input.
  def state_to_plan_input(_), do: empty_input()

  defp empty_input do
    %{
      "format_version" => "1.2",
      "_lynx_synthetic" => true,
      "resource_changes" => []
    }
  end

  defp resource_to_changes(%{
         "mode" => mode,
         "type" => type,
         "name" => name,
         "instances" => instances
       })
       when is_list(instances) do
    Enum.map(instances, fn inst ->
      attrs = Map.get(inst, "attributes", %{})
      index_key = Map.get(inst, "index_key")
      address = build_address(type, name, index_key)

      %{
        "address" => address,
        "mode" => mode,
        "type" => type,
        "name" => name,
        "change" => %{
          "actions" => ["update"],
          "before" => nil,
          "after" => attrs,
          "after_unknown" => %{}
        }
      }
    end)
  end

  defp resource_to_changes(_), do: []

  defp build_address(type, name, nil), do: "#{type}.#{name}"
  defp build_address(type, name, key) when is_integer(key), do: "#{type}.#{name}[#{key}]"

  defp build_address(type, name, key) when is_binary(key),
    do: "#{type}.#{name}[\"#{key}\"]"

  defp build_address(type, name, _), do: "#{type}.#{name}"

  defp resolve(nil, key), do: global_default(key)
  defp resolve(value, _) when is_boolean(value), do: value

  defp source(nil), do: :inherited
  defp source(_), do: :explicit

  defp config_key(:require_passing_plan), do: "policy_default_require_passing_plan"
  defp config_key(:block_violating_apply), do: "policy_default_block_violating_apply"
end

defmodule Lynx.Service.PolicyEngine.OPA do
  @moduledoc """
  Real OPA integration. Talks to a sidecar / centralized OPA over HTTP via
  `Req`. The `OPABundle` module + bundle endpoint handle pushing policies
  to OPA via OPA's bundle-polling mechanism, so this module only has to
  evaluate — no PUT/DELETE per-policy plumbing needed.

  Each Lynx policy is namespaced as `lynx.policy_<uuid>` in the bundle, so
  the deny rule for a given policy lives at `data.lynx.policy_<uuid>.deny`.
  """

  @behaviour Lynx.Service.PolicyEngine

  require OpenTelemetry.Tracer, as: Tracer

  @impl true
  def eval_deny(policy_uuid, input) when is_binary(policy_uuid) and is_map(input) do
    suffix = Lynx.Service.OPABundle.package_suffix(policy_uuid)
    url = url("/v1/data/lynx/policy_#{suffix}/deny")

    Tracer.with_span "lynx.policy_engine.eval",
      attributes: %{
        "lynx.policy.uuid" => policy_uuid,
        "lynx.opa.url" => url
      } do
      case Req.post(url,
             json: %{input: input},
             headers: [{"content-type", "application/json"}],
             receive_timeout: timeout_ms(),
             retry: false
           ) do
        {:ok, %{status: 200, body: %{"result" => result}}} when is_list(result) ->
          {:ok, Enum.map(result, &to_string/1)}

        {:ok, %{status: 200, body: %{"result" => nil}}} ->
          # OPA returns `result: null` when the rule is undefined (i.e. no
          # `deny` defined or no terms matched). Treat as zero violations.
          {:ok, []}

        {:ok, %{status: 200, body: %{} = body}} ->
          # `result` key entirely missing — same meaning as nil.
          case Map.get(body, "result") do
            nil -> {:ok, []}
            other -> {:error, {:unexpected_result, other}}
          end

        {:ok, %{status: status, body: body}} ->
          Tracer.set_status(:error, "opa_http_#{status}")
          {:error, {:opa_status, status, body}}

        {:error, reason} ->
          Tracer.set_status(:error, "opa_unreachable")
          {:error, {:opa_unreachable, reason}}
      end
    end
  end

  @impl true
  def validate(rego_source) when is_binary(rego_source) do
    # OPA's PUT /v1/policies/<id> compiles the module and returns
    # 200 on success, 400 with `errors[]` on parse/compile failure. We
    # use a scratch policy id, then DELETE it on success so we don't
    # leak validation artifacts into OPA's policy store.
    scratch_id = "lynx_validate_#{System.unique_integer([:positive])}"

    case Req.put(url("/v1/policies/#{scratch_id}"),
           body: rego_source,
           headers: [{"content-type", "text/plain"}],
           receive_timeout: timeout_ms(),
           retry: false
         ) do
      {:ok, %{status: 200}} ->
        # Best-effort cleanup — don't block validation on the DELETE.
        Req.delete(url("/v1/policies/#{scratch_id}"),
          receive_timeout: timeout_ms(),
          retry: false
        )

        :ok

      {:ok, %{status: 400, body: %{"errors" => errors}}} when is_list(errors) ->
        {:invalid, Enum.map(errors, &normalize_error/1)}

      {:ok, %{status: status, body: body}} ->
        {:error, {:opa_status, status, body}}

      {:error, reason} ->
        {:error, {:opa_unreachable, reason}}
    end
  end

  # OPA error shape: %{"code","message","location" => %{"row","col","file"}}
  defp normalize_error(%{"message" => msg} = err) do
    loc = err["location"] || %{}
    %{message: msg, row: loc["row"], col: loc["col"]}
  end

  defp normalize_error(err), do: %{message: inspect(err), row: nil, col: nil}

  defp url(path) do
    base = Application.get_env(:lynx, :opa_url, "http://localhost:8181")
    base <> path
  end

  defp timeout_ms do
    Application.get_env(:lynx, :opa_timeout_ms, 5000)
  end
end

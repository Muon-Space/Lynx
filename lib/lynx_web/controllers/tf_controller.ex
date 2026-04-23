defmodule LynxWeb.TfController do
  use LynxWeb, :controller

  require Logger

  alias Lynx.Context.AuditContext
  alias Lynx.Context.StateContext
  alias Lynx.Context.LockContext
  alias Lynx.Context.EnvironmentContext
  alias Lynx.Context.PlanCheckContext
  alias Lynx.Context.PolicyContext
  alias Lynx.Context.RoleContext
  alias Lynx.Service.PolicyEngine

  require OpenTelemetry.Tracer, as: Tracer

  plug :auth

  defp auth(conn, _opts) do
    with {user, secret} <- Plug.BasicAuth.parse_basic_auth(conn) do
      w_slug = conn.params["w_slug"] || find_workspace_for_project(conn.params["p_slug"])

      result =
        EnvironmentContext.is_access_allowed(%{
          workspace_slug: w_slug,
          project_slug: conn.params["p_slug"],
          env_slug: conn.params["e_slug"],
          username: user,
          secret: secret
        })

      case result do
        {:error, msg} ->
          Logger.info(msg)

          conn
          |> put_status(:forbidden)
          |> put_view(LynxWeb.LockJSON)
          |> render(:error, %{message: "Access is forbidden"})
          |> halt

        {:ok, _project, _env, permissions, actor_type} ->
          conn
          |> assign(:tf_username, user)
          |> assign(:tf_permissions, permissions)
          |> assign(:tf_actor_type, actor_type)
      end
    else
      _ -> conn |> Plug.BasicAuth.request_basic_auth() |> halt()
    end
  end

  def handle_get(conn, %{
        "w_slug" => w_slug,
        "p_slug" => p_slug,
        "e_slug" => e_slug,
        "rest" => rest
      }) do
    {sub_path, action} = parse_rest(rest)

    case action do
      "state" ->
        Tracer.with_span "tf.state.get", attributes: tf_attrs(w_slug, p_slug, e_slug, sub_path) do
          require_permission(conn, "state:read", fn conn ->
            get_state(conn, w_slug, p_slug, e_slug, sub_path)
          end)
        end

      _ ->
        conn |> send_resp(404, "Not found")
    end
  end

  def handle_post(
        conn,
        %{"w_slug" => w_slug, "p_slug" => p_slug, "e_slug" => e_slug, "rest" => rest} = params
      ) do
    {sub_path, action} = parse_rest(rest)

    attrs = tf_attrs(w_slug, p_slug, e_slug, sub_path)

    case action do
      "state" ->
        Tracer.with_span "tf.state.push", attributes: attrs do
          require_permission(conn, "state:write", fn conn ->
            push_state(conn, w_slug, p_slug, e_slug, sub_path, params)
          end)
        end

      "lock" ->
        Tracer.with_span "tf.state.lock", attributes: attrs do
          require_permission(conn, "state:lock", fn conn ->
            lock(conn, w_slug, p_slug, e_slug, sub_path, params)
          end)
        end

      "unlock" ->
        Tracer.with_span "tf.state.unlock", attributes: attrs do
          require_permission(conn, "state:unlock", fn conn ->
            unlock(conn, w_slug, p_slug, e_slug, sub_path)
          end)
        end

      "plan" ->
        Tracer.with_span "tf.plan.check", attributes: attrs do
          require_permission(conn, "plan:check", fn conn ->
            check_plan(conn, w_slug, p_slug, e_slug, sub_path, params)
          end)
        end

      _ ->
        conn |> send_resp(404, "Not found")
    end
  end

  defp require_permission(conn, permission, then_fn) do
    if RoleContext.has?(conn.assigns[:tf_permissions] || MapSet.new(), permission) do
      then_fn.(conn)
    else
      Logger.info("tf access denied: user=#{conn.assigns[:tf_username]} missing #{permission}")

      conn
      |> put_status(:forbidden)
      |> put_view(LynxWeb.LockJSON)
      |> render(:error, %{message: "Insufficient role for #{permission}"})
      |> halt()
    end
  end

  def legacy_get(conn, %{"t_slug" => _t, "p_slug" => p, "e_slug" => e, "rest" => rest}) do
    w_slug = find_workspace_for_project(p)
    handle_get(conn, %{"w_slug" => w_slug, "p_slug" => p, "e_slug" => e, "rest" => rest})
  end

  def legacy_post(conn, %{"t_slug" => _t, "p_slug" => p, "e_slug" => e, "rest" => rest} = params) do
    w_slug = find_workspace_for_project(p)

    handle_post(
      conn,
      Map.merge(params, %{"w_slug" => w_slug, "p_slug" => p, "e_slug" => e, "rest" => rest})
    )
  end

  defp find_workspace_for_project(project_slug) do
    case Lynx.Context.ProjectContext.get_project_by_slug(project_slug) do
      nil ->
        "default"

      project ->
        case project.workspace_id &&
               Lynx.Context.WorkspaceContext.get_workspace_by_id(project.workspace_id) do
          nil -> "default"
          ws -> ws.slug
        end
    end
  end

  defp get_state(conn, w_slug, p_slug, e_slug, sub_path) do
    case StateContext.get_latest_state(%{
           w_slug: w_slug,
           p_slug: p_slug,
           e_slug: e_slug,
           sub_path: sub_path
         }) do
      {:not_found, _} ->
        conn
        |> put_status(:not_found)
        |> put_view(LynxWeb.LockJSON)
        |> render(:error, %{message: "Not found"})

      {:no_state, _} ->
        conn
        |> put_status(:not_found)
        |> put_view(LynxWeb.LockJSON)
        |> render(:error, %{message: "State not found"})

      {:state_found, state} ->
        conn |> put_resp_content_type("application/json") |> send_resp(200, state.value)
    end
  end

  defp push_state(conn, w_slug, p_slug, e_slug, sub_path, params) do
    case LockContext.is_locked(%{
           w_slug: w_slug,
           p_slug: p_slug,
           e_slug: e_slug,
           sub_path: sub_path
         }) do
      {:locked, lock} ->
        # Terraform always presents the lock UUID as `?ID=<uuid>` on the state
        # write that follows a successful lock. Allow the holder of the active
        # lock to push state — otherwise the canonical lock → push → unlock
        # cycle (used by `terraform apply` and `terraform import`) is impossible.
        # Anyone else (no ID, mismatched ID) is correctly rejected.
        if lock_holder?(conn, params, lock) do
          with_apply_gate(conn, w_slug, p_slug, e_slug, sub_path, params, fn conn ->
            do_push_state(conn, w_slug, p_slug, e_slug, sub_path, params)
          end)
        else
          conn
          |> put_status(:locked)
          |> put_view(LynxWeb.LockJSON)
          |> render(:error, %{message: "Environment is locked"})
        end

      _ ->
        with_apply_gate(conn, w_slug, p_slug, e_slug, sub_path, params, fn conn ->
          do_push_state(conn, w_slug, p_slug, e_slug, sub_path, params)
        end)
    end
  end

  # Apply gate (issue #38). When the env opts in, every state-write must
  # be preceded by a passing plan_check from the same actor within the
  # configured TTL. The plan_check row is consumed atomically here so two
  # concurrent applies can't both spend the same approval.
  defp with_apply_gate(conn, w_slug, p_slug, e_slug, sub_path, _params, then_fn) do
    case resolve_env(w_slug, p_slug, e_slug) do
      nil ->
        conn
        |> put_status(:not_found)
        |> put_view(LynxWeb.LockJSON)
        |> render(:error, %{message: "Environment not found"})

      env ->
        if env.require_passing_plan do
          case consume_recent_passing(env, sub_path, conn) do
            :ok ->
              then_fn.(conn)

            {:error, reason} ->
              Logger.info(
                "tf apply gate denied: env=#{e_slug} sub=#{sub_path} actor=#{conn.assigns[:tf_username]} reason=#{reason}"
              )

              conn
              |> put_status(:forbidden)
              |> put_view(LynxWeb.LockJSON)
              |> render(:error, %{message: "Apply gate: #{reason}"})
          end
        else
          then_fn.(conn)
        end
    end
  end

  defp consume_recent_passing(env, sub_path, conn) do
    actor_signature = actor_signature(conn)

    case PlanCheckContext.latest_unconsumed_passing(env.id, sub_path, actor_signature) do
      nil ->
        {:error, "no recent passing plan_check for this env / sub-path"}

      plan_check ->
        max_age = env.plan_max_age_seconds
        age = DateTime.diff(DateTime.utc_now(), to_datetime(plan_check.inserted_at), :second)

        cond do
          age > max_age ->
            {:error, "plan_check older than #{max_age}s (was #{age}s)"}

          true ->
            case PlanCheckContext.consume(plan_check) do
              {:ok, _} -> :ok
              :already_consumed -> {:error, "plan_check already consumed"}
            end
        end
    end
  end

  defp resolve_env(w_slug, p_slug, e_slug) do
    with %{id: ws_id} <- Lynx.Context.WorkspaceContext.get_workspace_by_slug(w_slug),
         %{id: project_id} <-
           Lynx.Context.ProjectContext.get_project_by_slug_and_workspace(p_slug, ws_id),
         env when not is_nil(env) <-
           EnvironmentContext.get_env_by_slug_project(project_id, e_slug) do
      env
    else
      _ -> nil
    end
  end

  defp to_datetime(%NaiveDateTime{} = ndt), do: DateTime.from_naive!(ndt, "Etc/UTC")
  defp to_datetime(%DateTime{} = dt), do: dt

  # Build the actor signature used to bind a passing plan_check to the
  # subsequent apply. Same credential = same signature; cross-credential
  # apply attempts won't see the row.
  defp actor_signature(conn) do
    "#{conn.assigns[:tf_actor_type] || "unknown"}:#{conn.assigns[:tf_username] || "unknown"}"
  end

  defp lock_holder?(conn, params, lock) do
    presented = conn.query_params["ID"] || params["ID"]
    is_binary(presented) and presented == lock.uuid
  end

  defp do_push_state(conn, w_slug, p_slug, e_slug, sub_path, params) do
    body = Map.drop(params, ["w_slug", "p_slug", "e_slug", "rest", "t_slug"]) |> Jason.encode!()

    case StateContext.add_state(%{
           w_slug: w_slug,
           p_slug: p_slug,
           e_slug: e_slug,
           sub_path: sub_path,
           name: "_tf_state_",
           value: body
         }) do
      {:not_found, _} ->
        conn
        |> put_status(:not_found)
        |> put_view(LynxWeb.LockJSON)
        |> render(:error, %{message: "Not found"})

      {:success, _} ->
        log_tf_event(conn, "state_pushed", w_slug, p_slug, e_slug, sub_path)
        conn |> put_resp_content_type("application/json") |> send_resp(200, body)

      {:error, msg} ->
        conn
        |> put_status(:bad_request)
        |> put_view(LynxWeb.LockJSON)
        |> render(:error, %{message: msg})
    end
  end

  defp lock(conn, w_slug, p_slug, e_slug, sub_path, params) do
    case LockContext.is_locked(%{
           w_slug: w_slug,
           p_slug: p_slug,
           e_slug: e_slug,
           sub_path: sub_path
         }) do
      {:locked, lock} ->
        conn
        |> put_status(:locked)
        |> put_view(LynxWeb.LockJSON)
        |> render(:lock_data, %{lock: lock})

      {:not_found, msg} ->
        conn
        |> put_status(:not_found)
        |> put_view(LynxWeb.LockJSON)
        |> render(:error, %{message: msg})

      {:success, _} ->
        action =
          LockContext.lock_action(%{
            w_slug: w_slug,
            p_slug: p_slug,
            e_slug: e_slug,
            sub_path: sub_path,
            uuid: params["ID"] || "",
            operation: params["Operation"] || "",
            info: params["Info"] || "",
            who: params["Who"] || "",
            version: params["Version"] || "",
            path: params["Path"] || ""
          })

        case action do
          {:success, _} ->
            log_tf_event(conn, "locked", w_slug, p_slug, e_slug, sub_path)
            conn |> put_status(:ok) |> put_view(LynxWeb.LockJSON) |> render(:lock, %{})

          {:not_found, msg} ->
            conn
            |> put_status(:not_found)
            |> put_view(LynxWeb.LockJSON)
            |> render(:error, %{message: msg})

          {:error, msg} ->
            conn
            |> put_status(:internal_server_error)
            |> put_view(LynxWeb.LockJSON)
            |> render(:error, %{message: msg})
        end
    end
  end

  defp unlock(conn, w_slug, p_slug, e_slug, sub_path) do
    case LockContext.unlock_action(%{
           w_slug: w_slug,
           p_slug: p_slug,
           e_slug: e_slug,
           sub_path: sub_path
         }) do
      {:success, _} ->
        log_tf_event(conn, "unlocked", w_slug, p_slug, e_slug, sub_path)
        conn |> put_status(:ok) |> put_view(LynxWeb.LockJSON) |> render(:unlock, %{})

      {:not_found, msg} ->
        conn
        |> put_status(:not_found)
        |> put_view(LynxWeb.LockJSON)
        |> render(:error, %{message: msg})

      {:error, msg} ->
        conn
        |> put_status(:internal_server_error)
        |> put_view(LynxWeb.LockJSON)
        |> render(:error, %{message: msg})
    end
  end

  defp parse_rest(rest) do
    case List.pop_at(rest, -1) do
      {action, []} -> {"", action}
      {action, path_parts} -> {Enum.join(path_parts, "/"), action}
    end
  end

  # POST /tf/.../plan — accepts `terraform show -json` output, evaluates
  # every effective policy for the env, persists a plan_check row, and
  # returns the verdict. Persists regardless of outcome so failed checks
  # are auditable + the env page's history card has something to render.
  defp check_plan(conn, _w_slug, _p_slug, e_slug, sub_path, params) do
    case resolve_env_for_plan(conn) do
      {:error, msg, status} ->
        conn
        |> put_status(status)
        |> Phoenix.Controller.json(%{"errorMessage" => msg})

      {:ok, env} ->
        plan_input =
          params
          |> Map.drop(["w_slug", "p_slug", "e_slug", "rest", "t_slug"])

        plan_json = Jason.encode!(plan_input)
        policies = PolicyContext.list_effective_policies_for_env(env.id)

        {outcome, violations} = evaluate_policies(policies, plan_input)

        actor_signature = actor_signature(conn)
        actor_type = conn.assigns[:tf_actor_type] || "unknown"
        actor_name = conn.assigns[:tf_username]

        attrs =
          PlanCheckContext.new_plan_check(%{
            environment_id: env.id,
            sub_path: sub_path,
            outcome: outcome,
            violations: Jason.encode!(violations),
            plan_json: plan_json,
            actor_signature: actor_signature,
            actor_name: actor_name,
            actor_type: actor_type
          })

        case PlanCheckContext.create_plan_check(attrs) do
          {:ok, record} ->
            log_plan_check_event(conn, env, sub_path, outcome, length(policies))

            conn
            |> put_status(:ok)
            |> Phoenix.Controller.json(%{
              "id" => record.uuid,
              "outcome" => outcome,
              "violations" => violations,
              "policiesEvaluated" => length(policies)
            })

          {:error, changeset} ->
            Logger.error("plan_check insert failed: #{inspect(changeset.errors)} env=#{e_slug}")

            conn
            |> put_status(:internal_server_error)
            |> Phoenix.Controller.json(%{"errorMessage" => "Failed to record plan check"})
        end
    end
  end

  defp resolve_env_for_plan(conn) do
    case resolve_env(conn.params["w_slug"], conn.params["p_slug"], conn.params["e_slug"]) do
      nil -> {:error, "Environment not found", :not_found}
      env -> {:ok, env}
    end
  end

  # Evaluate each policy serially. If any errors, the overall outcome is
  # `errored` so operators see something went wrong; otherwise the outcome
  # is `failed` if any policy returned violations, else `passed`. Returns
  # `{outcome, violation_records}` where each violation_record carries
  # the policy uuid + name + the messages.
  defp evaluate_policies([], _input), do: {"passed", []}

  defp evaluate_policies(policies, input) do
    {outcome, violations} =
      Enum.reduce(policies, {"passed", []}, fn policy, {acc_outcome, acc_violations} ->
        case PolicyEngine.eval_deny(policy.uuid, input) do
          {:ok, []} ->
            {acc_outcome, acc_violations}

          {:ok, msgs} when is_list(msgs) ->
            row = %{
              "policyId" => policy.uuid,
              "policyName" => policy.name,
              "messages" => msgs
            }

            new_outcome = if acc_outcome == "errored", do: "errored", else: "failed"
            {new_outcome, [row | acc_violations]}

          {:error, reason} ->
            row = %{
              "policyId" => policy.uuid,
              "policyName" => policy.name,
              "messages" => ["engine error: #{inspect(reason)}"]
            }

            {"errored", [row | acc_violations]}
        end
      end)

    {outcome, Enum.reverse(violations)}
  end

  # Audit-event sibling of `log_tf_event/6` for the plan-check action,
  # carrying outcome + policy count as JSON metadata.
  defp log_plan_check_event(conn, env, sub_path, outcome, policies_evaluated) do
    actor_name = conn.assigns[:tf_username] || "system"
    actor_type = conn.assigns[:tf_actor_type] || "system"

    path_label =
      if sub_path == "", do: "env:#{env.id}", else: "env:#{env.id}/#{sub_path}"

    AuditContext.create_event(%{
      actor_id: nil,
      actor_name: actor_name,
      actor_type: actor_type,
      action: "plan_checked",
      resource_type: "environment",
      resource_id: path_label,
      resource_name: nil,
      metadata:
        Jason.encode!(%{
          "outcome" => outcome,
          "policies_evaluated" => policies_evaluated,
          "sub_path" => sub_path
        })
    })
  end

  # Common OTel span attributes for `/tf/` actions. The path tuple is the
  # natural correlation key for an end-to-end trace of a Terraform run.
  defp tf_attrs(w_slug, p_slug, e_slug, sub_path) do
    %{
      "lynx.workspace.slug" => w_slug,
      "lynx.project.slug" => p_slug,
      "lynx.env.slug" => e_slug,
      "lynx.unit.sub_path" => sub_path
    }
  end

  # Single audit-emit path for /tf endpoint actions (state push, lock, unlock).
  # `actor_type` is determined at auth time (oidc / user / env_secret) so OIDC
  # pipeline activity is fully traceable in `/admin/audit`. Resource is the
  # workspace/project/env path so it groups naturally in the audit timeline.
  defp log_tf_event(conn, action, w_slug, p_slug, e_slug, sub_path) do
    actor_name = conn.assigns[:tf_username] || "system"
    actor_type = conn.assigns[:tf_actor_type] || "system"

    path_label =
      if sub_path == "",
        do: "#{w_slug}/#{p_slug}/#{e_slug}",
        else: "#{w_slug}/#{p_slug}/#{e_slug}/#{sub_path}"

    AuditContext.create_event(%{
      actor_id: nil,
      actor_name: actor_name,
      actor_type: actor_type,
      action: action,
      resource_type: "environment",
      resource_id: path_label,
      resource_name: nil,
      metadata: nil
    })
  end
end

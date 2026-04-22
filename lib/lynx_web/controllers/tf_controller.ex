defmodule LynxWeb.TfController do
  use LynxWeb, :controller

  require Logger

  alias Lynx.Context.AuditContext
  alias Lynx.Context.StateContext
  alias Lynx.Context.LockContext
  alias Lynx.Context.EnvironmentContext
  alias Lynx.Context.RoleContext

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
        require_permission(conn, "state:read", fn conn ->
          get_state(conn, w_slug, p_slug, e_slug, sub_path)
        end)

      _ ->
        conn |> send_resp(404, "Not found")
    end
  end

  def handle_post(
        conn,
        %{"w_slug" => w_slug, "p_slug" => p_slug, "e_slug" => e_slug, "rest" => rest} = params
      ) do
    {sub_path, action} = parse_rest(rest)

    case action do
      "state" ->
        require_permission(conn, "state:write", fn conn ->
          push_state(conn, w_slug, p_slug, e_slug, sub_path, params)
        end)

      "lock" ->
        require_permission(conn, "state:lock", fn conn ->
          lock(conn, w_slug, p_slug, e_slug, sub_path, params)
        end)

      "unlock" ->
        require_permission(conn, "state:unlock", fn conn ->
          unlock(conn, w_slug, p_slug, e_slug, sub_path)
        end)

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
          do_push_state(conn, w_slug, p_slug, e_slug, sub_path, params)
        else
          conn
          |> put_status(:locked)
          |> put_view(LynxWeb.LockJSON)
          |> render(:error, %{message: "Environment is locked"})
        end

      _ ->
        do_push_state(conn, w_slug, p_slug, e_slug, sub_path, params)
    end
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

defmodule LynxWeb.TfController do
  use LynxWeb, :controller

  require Logger

  alias Lynx.Module.StateModule
  alias Lynx.Module.LockModule
  alias Lynx.Module.EnvironmentModule
  alias Lynx.Module.RoleModule

  plug :auth

  defp auth(conn, _opts) do
    with {user, secret} <- Plug.BasicAuth.parse_basic_auth(conn) do
      w_slug = conn.params["w_slug"] || find_workspace_for_project(conn.params["p_slug"])

      result =
        EnvironmentModule.is_access_allowed(%{
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

        {:ok, _project, _env, permissions} ->
          conn
          |> assign(:tf_username, user)
          |> assign(:tf_permissions, permissions)
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
    if RoleModule.has?(conn.assigns[:tf_permissions] || MapSet.new(), permission) do
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
    case StateModule.get_latest_state(%{
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
    case LockModule.is_locked(%{
           w_slug: w_slug,
           p_slug: p_slug,
           e_slug: e_slug,
           sub_path: sub_path
         }) do
      {:locked, _} ->
        conn
        |> put_status(:locked)
        |> put_view(LynxWeb.LockJSON)
        |> render(:error, %{message: "Environment is locked"})

      _ ->
        do_push_state(conn, w_slug, p_slug, e_slug, sub_path, params)
    end
  end

  defp do_push_state(conn, w_slug, p_slug, e_slug, sub_path, params) do
    body = Map.drop(params, ["w_slug", "p_slug", "e_slug", "rest", "t_slug"]) |> Jason.encode!()

    case StateModule.add_state(%{
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
        path_label =
          if sub_path == "", do: "#{p_slug}/#{e_slug}", else: "#{p_slug}/#{e_slug}/#{sub_path}"

        actor_name = conn.assigns[:tf_username] || "system"

        Lynx.Context.AuditContext.create_event(%{
          actor_id: nil,
          actor_name: actor_name,
          actor_type: if(String.contains?(actor_name, "@"), do: "user", else: "system"),
          action: "state_pushed",
          resource_type: "environment",
          resource_id: path_label,
          resource_name: nil,
          metadata: nil
        })

        conn |> put_resp_content_type("application/json") |> send_resp(200, body)

      {:error, msg} ->
        conn
        |> put_status(:bad_request)
        |> put_view(LynxWeb.LockJSON)
        |> render(:error, %{message: msg})
    end
  end

  defp lock(conn, w_slug, p_slug, e_slug, sub_path, params) do
    case LockModule.is_locked(%{
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
          LockModule.lock_action(%{
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
    case LockModule.unlock_action(%{
           w_slug: w_slug,
           p_slug: p_slug,
           e_slug: e_slug,
           sub_path: sub_path
         }) do
      {:success, _} ->
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
end

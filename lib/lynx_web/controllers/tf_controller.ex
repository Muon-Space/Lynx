defmodule LynxWeb.TfController do
  use LynxWeb, :controller

  require Logger

  alias Lynx.Module.StateModule
  alias Lynx.Module.LockModule
  alias Lynx.Module.EnvironmentModule

  plug :auth

  defp auth(conn, _opts) do
    with {user, secret} <- Plug.BasicAuth.parse_basic_auth(conn) do
      result =
        EnvironmentModule.is_access_allowed(%{
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

        {:ok, _, _} ->
          conn
      end
    else
      _ -> conn |> Plug.BasicAuth.request_basic_auth() |> halt()
    end
  end

  def handle_get(conn, %{"p_slug" => p_slug, "e_slug" => e_slug, "rest" => rest}) do
    {sub_path, action} = parse_rest(rest)

    case action do
      "state" -> get_state(conn, p_slug, e_slug, sub_path)
      _ -> conn |> send_resp(404, "Not found")
    end
  end

  def handle_post(conn, %{"p_slug" => p_slug, "e_slug" => e_slug, "rest" => rest} = params) do
    {sub_path, action} = parse_rest(rest)

    case action do
      "state" -> push_state(conn, p_slug, e_slug, sub_path, params)
      "lock" -> lock(conn, p_slug, e_slug, sub_path, params)
      "unlock" -> unlock(conn, p_slug, e_slug, sub_path)
      _ -> conn |> send_resp(404, "Not found")
    end
  end

  def legacy_get(conn, %{"t_slug" => _t, "p_slug" => p, "e_slug" => e, "rest" => rest}) do
    handle_get(conn, %{"p_slug" => p, "e_slug" => e, "rest" => rest})
  end

  def legacy_post(conn, %{"t_slug" => _t, "p_slug" => p, "e_slug" => e, "rest" => rest} = params) do
    handle_post(conn, Map.merge(params, %{"p_slug" => p, "e_slug" => e, "rest" => rest}))
  end

  defp get_state(conn, p_slug, e_slug, sub_path) do
    case StateModule.get_latest_state(%{p_slug: p_slug, e_slug: e_slug, sub_path: sub_path}) do
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

  defp push_state(conn, p_slug, e_slug, sub_path, params) do
    body = Map.drop(params, ["p_slug", "e_slug", "rest", "t_slug"]) |> Jason.encode!()

    case StateModule.add_state(%{
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

        Lynx.Module.AuditModule.log_system("state_pushed", "environment", path_label)
        conn |> put_resp_content_type("application/json") |> send_resp(200, body)

      {:error, msg} ->
        conn
        |> put_status(:bad_request)
        |> put_view(LynxWeb.LockJSON)
        |> render(:error, %{message: msg})
    end
  end

  defp lock(conn, p_slug, e_slug, sub_path, params) do
    case LockModule.is_locked(%{p_slug: p_slug, e_slug: e_slug, sub_path: sub_path}) do
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

  defp unlock(conn, p_slug, e_slug, sub_path) do
    case LockModule.unlock_action(%{p_slug: p_slug, e_slug: e_slug, sub_path: sub_path}) do
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

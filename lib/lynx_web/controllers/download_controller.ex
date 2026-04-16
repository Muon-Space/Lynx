defmodule LynxWeb.DownloadController do
  use LynxWeb, :controller

  alias Lynx.Module.PermissionModule
  alias Lynx.Module.StateModule

  def state(conn, %{"uuid" => uuid}) do
    case conn.assigns[:is_logged] do
      false ->
        redirect(conn, to: "/login")

      true ->
        if not PermissionModule.can_access_snapshot_uuid(
             :snapshot,
             conn.assigns[:user_role],
             uuid,
             conn.assigns[:user_id]
           ) do
          redirect(conn, to: "/404")
        else
          case StateModule.get_state_by_uuid(uuid) do
            nil ->
              redirect(conn, to: "/404")

            state ->
              conn
              |> put_resp_content_type("application/octet-stream")
              |> put_resp_header(
                "content-disposition",
                "attachment; filename=\"state.#{uuid}.json\""
              )
              |> send_resp(200, state.value)
          end
        end
    end
  end

  def environment(conn, %{"uuid" => uuid}) do
    case conn.assigns[:is_logged] do
      false ->
        redirect(conn, to: "/login")

      true ->
        if not PermissionModule.can_access_environment_uuid(
             :environment,
             conn.assigns[:user_role],
             uuid,
             conn.assigns[:user_id]
           ) do
          redirect(conn, to: "/404")
        else
          case StateModule.get_latest_state_by_env_uuid(uuid) do
            nil ->
              redirect(conn, to: "/404")

            state ->
              conn
              |> put_resp_content_type("application/octet-stream")
              |> put_resp_header(
                "content-disposition",
                "attachment; filename=\"state.#{state.uuid}.json\""
              )
              |> send_resp(200, state.value)
          end
        end
    end
  end
end

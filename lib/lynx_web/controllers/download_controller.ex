defmodule LynxWeb.DownloadController do
  use LynxWeb, :controller

  alias Lynx.Module.PermissionModule
  alias Lynx.Module.StateModule
  alias Lynx.Context.EnvironmentContext
  alias Lynx.Context.StateContext

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

  def environment(conn, %{"uuid" => uuid} = params) do
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
          sub_path = params["sub_path"] || ""

          case EnvironmentContext.get_env_by_uuid(uuid) do
            nil ->
              redirect(conn, to: "/404")

            env ->
              case StateContext.get_latest_state_by_environment_and_path(env.id, sub_path) do
                nil ->
                  redirect(conn, to: "/404")

                state ->
                  filename =
                    if sub_path == "",
                      do: "state.#{state.uuid}.json",
                      else: "state.#{String.replace(sub_path, "/", "-")}.#{state.uuid}.json"

                  conn
                  |> put_resp_content_type("application/octet-stream")
                  |> put_resp_header(
                    "content-disposition",
                    "attachment; filename=\"#{filename}\""
                  )
                  |> send_resp(200, state.value)
              end
          end
        end
    end
  end
end

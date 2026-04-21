defmodule LynxWeb.SessionController do
  use LynxWeb, :controller

  import Plug.Conn

  alias Lynx.Service.AuthService
  alias Lynx.Service.ValidatorService
  alias Lynx.Service.SSO

  def logout(conn, _params) do
    AuthService.logout(conn.assigns[:user_id])

    conn
    |> clear_session()
    |> redirect(to: "/")
  end

  def auth(conn, params) do
    if not SSO.is_password_enabled?() do
      conn
      |> put_status(:bad_request)
      |> put_view(LynxWeb.MiscJSON)
      |> render(:error, %{message: "Password authentication is disabled. Please use SSO."})
    else
      auth_with_password(conn, params)
    end
  end

  defp auth_with_password(conn, params) do
    err = "Invalid email or password!"

    with {:ok, _} <- ValidatorService.is_string?(params["password"], err),
         {:ok, password} <- ValidatorService.is_password?(params["password"], err),
         {:ok, _} <- ValidatorService.is_string?(params["email"], err),
         {:ok, email} <- ValidatorService.is_email?(params["email"], err) do
      case AuthService.login(email, password) do
        {:success, session} ->
          Lynx.Context.AuditContext.log_system("login", "user", nil, params["email"], %{
            method: "password"
          })

          conn = fetch_session(conn)

          conn =
            conn
            |> put_session(:token, session.value)
            |> put_session(:uid, session.user_id)

          if get_req_header(conn, "x-requested-with") == ["XMLHttpRequest"] do
            conn
            |> put_status(:ok)
            |> put_view(LynxWeb.MiscJSON)
            |> render(:token_success, %{message: "User logged in successfully!"})
          else
            conn
            |> redirect(to: "/admin/workspaces")
          end

        {:error, message} ->
          conn
          |> put_status(:bad_request)
          |> put_view(LynxWeb.MiscJSON)
          |> render(:error, %{message: message})
      end
    else
      {:error, reason} ->
        conn
        |> put_status(:bad_request)
        |> put_view(LynxWeb.MiscJSON)
        |> render(:error, %{message: reason})
    end
  end
end

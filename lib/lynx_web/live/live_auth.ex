defmodule LynxWeb.LiveAuth do
  @moduledoc """
  LiveView authentication hook. Checks session and loads user into socket assigns.
  """

  import Phoenix.LiveView
  import Phoenix.Component

  alias Lynx.Context.UserContext
  alias Lynx.Service.AuthService

  def on_mount(:require_auth, _params, session, socket) do
    socket = assign_current_user(socket, session)

    if socket.assigns.current_user do
      {:cont, socket}
    else
      {:halt, redirect(socket, to: "/login")}
    end
  end

  def on_mount(:require_super, _params, session, socket) do
    socket = assign_current_user(socket, session)

    if socket.assigns.current_user && socket.assigns.current_user.role == "super" do
      {:cont, socket}
    else
      {:halt, redirect(socket, to: "/login")}
    end
  end

  def on_mount(:optional_auth, _params, session, socket) do
    {:cont, assign_current_user(socket, session)}
  end

  defp assign_current_user(socket, session) do
    token = session["token"]
    uid = session["uid"]

    user =
      case AuthService.is_authenticated(uid, token) do
        false ->
          nil

        {true, user_session} ->
          case UserContext.get_user_by_id(user_session.user_id) do
            nil -> nil
            user -> if user.is_active, do: user, else: nil
          end
      end

    assign(socket, :current_user, user)
  end
end

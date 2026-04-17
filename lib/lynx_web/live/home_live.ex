defmodule LynxWeb.HomeLive do
  use LynxWeb, :live_view

  alias Lynx.Module.InstallModule

  on_mount {LynxWeb.LiveAuth, :optional_auth}

  @impl true
  def mount(_params, _session, socket) do
    if not InstallModule.is_installed() do
      {:ok, redirect(socket, to: "/install")}
    else
      if socket.assigns.current_user do
        {:ok, redirect(socket, to: "/admin/workspaces")}
      else
        {:ok, redirect(socket, to: "/login")}
      end
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen flex items-center justify-center">
      <p>Redirecting...</p>
    </div>
    """
  end
end

defmodule LynxWeb.LoginLive do
  use LynxWeb, :live_view

  alias Lynx.Module.InstallModule
  alias Lynx.Module.SSOModule

  @impl true
  def mount(_params, session, socket) do
    if not InstallModule.is_installed() do
      {:ok, redirect(socket, to: "/install")}
    else
      # Check if already logged in
      token = session["token"]
      uid = session["uid"]

      case Lynx.Service.AuthService.is_authenticated(uid, token) do
        {true, _} ->
          {:ok, redirect(socket, to: "/admin/projects")}

        _ ->
          socket =
            socket
            |> assign(:sso_enabled, SSOModule.is_sso_enabled?())
            |> assign(:password_enabled, SSOModule.is_password_enabled?())
            |> assign(:sso_login_label, SSOModule.get_sso_login_label())
            |> assign(:error, nil)

          {:ok, socket}
      end
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen flex items-center justify-center bg-gray-50 dark:bg-gray-950 py-12 px-4">
      <div class="absolute top-4 right-4">
        <button id="dark-mode-toggle-login" phx-hook="DarkMode" class="text-lg cursor-pointer leading-none" title="Toggle dark mode"></button>
      </div>
      <div class="max-w-md w-full space-y-8">
        <div class="text-center">
          <img src="/images/ico.png" alt="Lynx" class="mx-auto h-12 dark:hidden" />
          <img src="/images/ico-dark.png" alt="Lynx" class="mx-auto h-12 hidden dark:block" />
          <h2 class="mt-6 text-3xl font-bold text-gray-900 dark:text-white">Sign in</h2>
        </div>

        <.card>
          <form :if={@password_enabled} action="/action/auth" method="post" class="space-y-4">
            <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
            <.input name="email" label="Email" type="email" value="" required />
            <.input name="password" label="Password" type="password" value="" required />
            <.button type="submit" variant="primary" class="w-full">Sign in</.button>
          </form>

          <div :if={@sso_enabled && @password_enabled} class="my-6 flex items-center">
            <div class="flex-1 border-t border-gray-200 dark:border-gray-700"></div>
            <span class="px-4 text-sm text-gray-400 dark:text-gray-500">or</span>
            <div class="flex-1 border-t border-gray-200 dark:border-gray-700"></div>
          </div>

          <a :if={@sso_enabled} href="/auth/sso" class="flex items-center justify-center w-full px-4 py-2 border border-gray-300 dark:border-gray-600 rounded-lg text-sm font-medium text-gray-700 dark:text-gray-300 hover:bg-gray-50 dark:hover:bg-gray-800 transition-colors">
            Sign in with {@sso_login_label}
          </a>
        </.card>
      </div>
    </div>
    """
  end
end

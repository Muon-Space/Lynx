defmodule LynxWeb.LoginLive do
  use LynxWeb, :live_view

  alias Lynx.Context.UserContext
  alias Lynx.Service.Install
  alias Lynx.Service.SSO

  @impl true
  def mount(_params, session, socket) do
    if not Install.is_installed() do
      {:ok, redirect(socket, to: "/install")}
    else
      # Check if already logged in. We require BOTH a valid session row
      # AND an active user — a stale session against a deactivated user
      # must fall through to the login form, otherwise we'd send them
      # straight to /admin/workspaces only for `LiveAuth` to bounce them
      # right back to /login (redirect loop).
      token = session["token"]
      uid = session["uid"]

      with {true, user_session} <- Lynx.Service.AuthService.is_authenticated(uid, token),
           %{is_active: true} <- UserContext.get_user_by_id(user_session.user_id) do
        # Canonical post-login landing is the workspaces list. The bare
        # `/admin/projects` path doesn't exist (only `/admin/projects/:uuid`).
        {:ok, redirect(socket, to: "/admin/workspaces")}
      else
        _ ->
          socket =
            socket
            |> assign(:sso_enabled, SSO.is_sso_enabled?())
            |> assign(:password_enabled, SSO.is_password_enabled?())
            |> assign(:sso_login_label, SSO.get_sso_login_label())
            |> assign(:error, nil)

          {:ok, socket}
      end
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen flex items-center justify-center bg-page py-12 px-4">
      <div class="absolute top-4 right-4">
        <.dark_mode_toggle id="dark-mode-toggle-login" />
      </div>
      <div class="max-w-md w-full space-y-8">
        <div class="text-center">
          <div class="flex justify-center"><.logo class="h-12" /></div>
          <h2 class="mt-6 text-3xl font-bold text-foreground">Sign in</h2>
        </div>

        <.card>
          <form :if={@password_enabled} action="/action/auth" method="post" class="space-y-4">
            <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
            <.input name="email" label="Email" type="email" value="" required />
            <.input name="password" label="Password" type="password" value="" required />
            <.button type="submit" variant="primary" class="w-full">Sign in</.button>
          </form>

          <div :if={@sso_enabled && @password_enabled} class="my-6 flex items-center">
            <div class="flex-1 border-t border-border"></div>
            <span class="px-4 text-sm text-muted">or</span>
            <div class="flex-1 border-t border-border"></div>
          </div>

          <a :if={@sso_enabled} href="/auth/sso" class="flex items-center justify-center w-full px-4 py-2 border border-border-input rounded-lg text-sm font-medium text-secondary hover:bg-surface-secondary transition-colors">
            Sign in with {@sso_login_label}
          </a>
        </.card>
      </div>
    </div>
    """
  end
end

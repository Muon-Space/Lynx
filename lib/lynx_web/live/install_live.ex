defmodule LynxWeb.InstallLive do
  use LynxWeb, :live_view

  alias Lynx.Module.InstallModule

  @impl true
  def mount(_params, _session, socket) do
    if InstallModule.is_installed() do
      {:ok, redirect(socket, to: "/")}
    else
      {:ok, assign(socket, form: to_form(%{}, as: :install), error: nil)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen flex items-center justify-center bg-gray-50 dark:bg-gray-950 py-12 px-4">
      <div class="absolute top-4 right-4">
        <button id="dark-mode-toggle-install" phx-hook="DarkMode" class="text-lg cursor-pointer leading-none" title="Toggle dark mode"></button>
      </div>
      <div class="max-w-md w-full space-y-8">
        <div class="text-center">
          <img src="/images/ico.png" alt="Lynx" class="mx-auto h-12" />
          <h2 class="mt-6 text-3xl font-bold text-gray-900 dark:text-white">Setup Lynx</h2>
          <p class="mt-2 text-sm text-gray-500 dark:text-gray-400">Configure your Terraform backend</p>
        </div>

        <.card>
          <p :if={@error} class="mb-4 text-sm text-red-600 bg-red-50 dark:bg-red-900/20 rounded-lg px-4 py-3">{@error}</p>

          <form phx-submit="install" class="space-y-4">
            <.input name="app_name" label="Application Name" value="" required placeholder="Lynx" />
            <.input name="app_url" label="Application URL" type="url" value="" required placeholder="https://lynx.example.com" />
            <.input name="app_email" label="Application Email" type="email" value="" required placeholder="admin@example.com" />

            <hr class="my-4 border-gray-200 dark:border-gray-700" />

            <.input name="admin_name" label="Admin Name" value="" required placeholder="John Doe" />
            <.input name="admin_email" label="Admin Email" type="email" value="" required placeholder="admin@example.com" />
            <.input name="admin_password" label="Admin Password" type="password" value="" required />

            <.button type="submit" variant="primary" class="w-full">Install</.button>
          </form>
        </.card>
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("install", params, socket) do
    app_key = InstallModule.get_app_key()

    InstallModule.store_configs(%{
      app_name: params["app_name"] || "Lynx",
      app_url: params["app_url"] || "http://lynx.sh",
      app_email: params["app_email"] || "no_reply@lynx.sh",
      app_key: app_key
    })

    case InstallModule.create_admin(%{
           admin_name: params["admin_name"] || "",
           admin_email: params["admin_email"] || "",
           admin_password: params["admin_password"] || "",
           app_key: app_key
         }) do
      {:success, _} ->
        {:noreply, redirect(socket, to: "/login")}

      {:error, msg} ->
        {:noreply, assign(socket, error: msg)}
    end
  end
end

defmodule LynxWeb.ProfileLive do
  use LynxWeb, :live_view

  alias Lynx.Context.UserContext
  alias Lynx.Service.AuthService

  @impl true
  def mount(_params, _session, socket) do
    _user = socket.assigns.current_user

    socket =
      socket
      |> assign(:api_key, "••••••••••••••••")
      |> assign(:api_key_visible, false)

    socket = assign(socket, :confirm, nil)
    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.confirm_dialog :if={@confirm} message={@confirm.message} confirm_event={@confirm.event} confirm_value={@confirm.value} />
    <.nav current_user={@current_user} active="profile" />
    <div class="max-w-3xl mx-auto px-6 pb-16">
      <.page_header title="Profile" subtitle="Manage your account and API access" />

      <.card class="mb-6">
        <h3 class="text-lg font-semibold mb-4">Update Profile</h3>
        <form phx-submit="update_profile" class="space-y-4">
          <.input name="name" label="Name" value={@current_user.name} required />
          <.input name="email" label="Email" type="email" value={@current_user.email} required />
          <.input name="password" label="New Password (leave blank to keep)" type="password" value="" />
          <.button type="submit" variant="primary">Save</.button>
        </form>
      </.card>

      <.card>
        <h3 class="text-lg font-semibold mb-4">API Key</h3>
        <div class="flex items-center gap-4">
          <code id="api-key-content" class="flex-1 bg-inset text-foreground px-4 py-2 rounded-lg text-sm font-mono">{@api_key}</code>
          <.button :if={!@api_key_visible} phx-click="show_api_key" variant="secondary" size="sm" class="w-14">Show</.button>
          <.button :if={@api_key_visible} phx-click="hide_api_key" variant="secondary" size="sm" class="w-14">Hide</.button>
          <button id="copy-api-key" phx-hook=".CopyApiKey" phx-click="copy_api_key" class="px-3 py-1.5 text-xs rounded-lg bg-input text-secondary border border-border-input hover:bg-surface-secondary cursor-pointer">Copy</button>
          <.button phx-click="confirm_action" phx-value-event="rotate_api_key" phx-value-message="Rotate API key? The old key will stop working immediately." variant="danger" size="sm">Rotate</.button>
        </div>
      </.card>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".CopyApiKey">
        export default {
          mounted() {
            this.handleEvent("copy_api_key", ({value}) => {
              if (!value) return
              navigator.clipboard.writeText(value).then(() => {
                let orig = this.el.textContent
                this.el.textContent = "Copied!"
                setTimeout(() => { this.el.textContent = orig }, 1500)
              })
            })
          }
        }
      </script>
    </div>
    """
  end

  @impl true
  def handle_event("confirm_action", params, socket) do
    {:noreply,
     assign(socket, :confirm, %{
       message: params["message"],
       event: params["event"],
       value: %{uuid: params["uuid"]}
     })}
  end

  def handle_event("cancel_confirm", _, socket), do: {:noreply, assign(socket, :confirm, nil)}

  def handle_event("update_profile", params, socket) do
    case UserContext.update_user_from_data(%{
           uuid: socket.assigns.current_user.uuid,
           name: params["name"],
           email: params["email"],
           password: params["password"]
         }) do
      {:ok, user} ->
        {:noreply, socket |> assign(:current_user, user) |> put_flash(:info, "Profile updated")}

      {:error, msg} ->
        {:noreply, put_flash(socket, :error, msg)}
    end
  end

  def handle_event("show_api_key", _, socket) do
    {:noreply,
     assign(socket, api_key: socket.assigns.current_user.api_key, api_key_visible: true)}
  end

  def handle_event("copy_api_key", _, socket) do
    # Send the key over the LV socket on demand instead of embedding it in
    # the rendered HTML; the CopyApiKey hook receives it and writes to the
    # clipboard. The key still crosses the wire, but never sits in the DOM.
    {:noreply, push_event(socket, "copy_api_key", %{value: socket.assigns.current_user.api_key})}
  end

  def handle_event("hide_api_key", _, socket) do
    {:noreply, assign(socket, api_key: "••••••••••••••••", api_key_visible: false)}
  end

  def handle_event("rotate_api_key", _, socket) do
    socket = assign(socket, :confirm, nil)
    new_key = AuthService.get_uuid()

    case UserContext.rotate_api_key(socket.assigns.current_user.uuid, new_key) do
      {:ok, user} ->
        {:noreply,
         socket
         |> assign(:current_user, user)
         |> assign(:api_key, new_key)
         |> assign(:api_key_visible, true)
         |> put_flash(:info, "API key rotated")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to rotate API key")}
    end
  end
end

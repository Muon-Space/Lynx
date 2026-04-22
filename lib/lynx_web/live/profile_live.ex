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
          <button id="copy-api-key" phx-hook=".CopyApiKey" type="button" class="px-3 py-1.5 text-xs rounded-lg bg-input text-secondary border border-border-input hover:bg-surface-secondary cursor-pointer">Copy</button>
          <.button phx-click="confirm_action" phx-value-event="rotate_api_key" phx-value-message="Rotate API key? The old key will stop working immediately." variant="danger" size="sm">Rotate</.button>
        </div>
      </.card>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".CopyApiKey">
        // Browsers gate `navigator.clipboard.writeText` on a recent user
        // activation (the click event). After an async LV roundtrip the
        // activation has expired, so a fetch-then-copy chain silently fails
        // in Safari/Firefox. Solution: prefetch the key on mount and on
        // hover/focus into a hook-local variable, then the click handler
        // writes synchronously while the activation is still live. The key
        // sits in the hook closure (not the DOM); it crosses the wire on
        // page entry, but the user is already viewing their own profile.
        export default {
          mounted() {
            this.apiKey = null
            this.fetching = false

            const prefetch = () => {
              if (this.apiKey || this.fetching) return
              this.fetching = true
              this.pushEvent("copy_api_key", {}, (reply) => {
                this.apiKey = reply && reply.value
                this.fetching = false
              })
            }

            // Eager prefetch + warm again on hover in case it ever races.
            prefetch()
            this.el.addEventListener("mouseenter", prefetch)
            this.el.addEventListener("focus", prefetch)

            // Server pushes the new key after `rotate_api_key`, so the next
            // click copies the rotated value (not the stale pre-rotation cache).
            this.handleEvent("copy_api_key_set", ({value}) => {
              this.apiKey = value
            })

            this.el.addEventListener("click", (e) => {
              e.preventDefault()
              const value = this.apiKey
              if (!value) {
                // Click landed before prefetch. Trigger one and ask the user
                // to retry — silent failure was the original bug.
                prefetch()
                const orig = this.el.textContent
                this.el.textContent = "Loading…"
                setTimeout(() => { this.el.textContent = orig }, 800)
                return
              }
              navigator.clipboard.writeText(value).then(() => {
                const orig = this.el.textContent
                this.el.textContent = "Copied!"
                setTimeout(() => { this.el.textContent = orig }, 1500)
              }, () => {
                const orig = this.el.textContent
                this.el.textContent = "Copy failed"
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
    # Reply (correlated) instead of push_event (broadcast). The CopyApiKey
    # hook calls `pushEvent("copy_api_key", {}, reply => …)` and writes the
    # returned key to the clipboard. The key crosses the wire on demand and
    # never sits in the DOM.
    {:reply, %{value: socket.assigns.current_user.api_key}, socket}
  end

  def handle_event("hide_api_key", _, socket) do
    {:noreply, assign(socket, api_key: "••••••••••••••••", api_key_visible: false)}
  end

  def handle_event("rotate_api_key", _, socket) do
    socket = assign(socket, :confirm, nil)
    new_key = AuthService.get_uuid()

    case UserContext.rotate_api_key(socket.assigns.current_user.uuid, new_key) do
      {:ok, user} ->
        # Push the new key to the CopyApiKey hook so its cached value is
        # current. Without this, the click handler's prefetched cache still
        # holds the old key and Copy returns the pre-rotation value.
        {:noreply,
         socket
         |> assign(:current_user, user)
         |> assign(:api_key, new_key)
         |> assign(:api_key_visible, true)
         |> put_flash(:info, "API key rotated")
         |> push_event("copy_api_key_set", %{value: new_key})}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to rotate API key")}
    end
  end
end

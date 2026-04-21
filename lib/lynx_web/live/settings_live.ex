defmodule LynxWeb.SettingsLive do
  use LynxWeb, :live_view

  alias Lynx.Service.Settings
  alias Lynx.Context.SCIMTokenContext
  alias Lynx.Service.OIDCBackend
  alias Lynx.Context.AuditContext

  @impl true
  def mount(_params, _session, socket) do
    app_url =
      Settings.get_config("app_url", "http://localhost:4000") |> String.trim_trailing("/")

    socket =
      socket
      |> assign(:app_name, Settings.get_config("app_name", ""))
      |> assign(:app_url, app_url)
      |> assign(:app_email, Settings.get_config("app_email", ""))
      |> assign(:state_retention, Settings.get_config("state_retention_count", "0"))
      # SSO
      |> assign(
        :password_enabled,
        Settings.get_sso_config("auth_password_enabled", "true") == "true"
      )
      |> assign(
        :sso_enabled,
        Settings.get_sso_config("auth_sso_enabled", "false") == "true"
      )
      |> assign(:jit_enabled, Settings.get_sso_config("sso_jit_enabled", "true") == "true")
      |> assign(:sso_protocol, Settings.get_sso_config("sso_protocol", "oidc"))
      |> assign(:sso_login_label, Settings.get_sso_config("sso_login_label", "SSO"))
      |> assign(:sso_issuer, Settings.get_sso_config("sso_issuer", ""))
      |> assign(:sso_client_id, Settings.get_sso_config("sso_client_id", ""))
      |> assign(:sso_client_secret, Settings.get_sso_config("sso_client_secret", ""))
      |> assign(:saml_idp_sso_url, Settings.get_sso_config("sso_saml_idp_sso_url", ""))
      |> assign(:saml_idp_issuer, Settings.get_sso_config("sso_saml_idp_issuer", ""))
      |> assign(:saml_idp_cert, Settings.get_sso_config("sso_saml_idp_cert", ""))
      |> assign(
        :saml_idp_metadata_url,
        Settings.get_sso_config("sso_saml_idp_metadata_url", "")
      )
      |> assign(:saml_sp_entity_id, Settings.get_sso_config("sso_saml_sp_entity_id", ""))
      |> assign(
        :saml_sign_requests,
        Settings.get_sso_config("sso_saml_sign_requests", "false") == "true"
      )
      |> assign(:saml_sp_cert, Settings.get_sso_config("sso_saml_sp_cert", ""))
      # SCIM
      |> assign(:scim_enabled, Settings.get_sso_config("scim_enabled", "false") == "true")
      |> assign(:scim_tokens, SCIMTokenContext.list_tokens())
      |> assign(:new_token, nil)
      # OIDC Providers
      |> assign(:oidc_providers, OIDCBackend.list_providers())
      |> assign(:show_add_provider, false)
      # Computed
      |> assign(:oidc_redirect_uri, app_url <> "/auth/sso/callback")
      |> assign(:oidc_signout_uri, app_url <> "/logout")
      |> assign(:saml_acs_url, app_url <> "/auth/sso/saml_callback")

    socket = socket |> assign(:confirm, nil) |> assign(:tab, "general")
    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, assign(socket, :tab, normalize_tab(params["tab"]))}
  end

  defp normalize_tab(tab) when tab in ~w(general sso scim oidc), do: tab
  defp normalize_tab(_), do: "general"

  @tabs [
    {"general", "General"},
    {"sso", "SSO"},
    {"scim", "SCIM"},
    {"oidc", "OIDC Providers"}
  ]

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :tabs, @tabs)

    ~H"""
    <.confirm_dialog :if={@confirm} message={@confirm.message} confirm_event={@confirm.event} confirm_value={@confirm.value} />
    <.nav current_user={@current_user} active="settings" />
    <div class="max-w-7xl mx-auto px-6 pb-16">
      <.page_header title="Settings" subtitle="Configure authentication, SSO, and system preferences" />

      <div class="border-b border-border mb-6 flex gap-1">
        <.link
          :for={{id, label} <- @tabs}
          patch={"/admin/settings?tab=#{id}"}
          class={[
            "px-4 py-2 text-sm font-medium border-b-2 -mb-px transition-colors",
            @tab == id && "border-accent text-foreground",
            @tab != id && "border-transparent text-secondary hover:text-foreground hover:border-border"
          ]}
        >
          {label}
        </.link>
      </div>

      <%!-- General Settings --%>
      <.card :if={@tab == "general"} class="mb-6">
        <h3 class="text-lg font-semibold mb-4">General</h3>
        <form phx-submit="save_general" class="space-y-4">
          <.input name="app_name" label="Application Name" value={@app_name} required />
          <.input name="app_url" label="Application URL" type="url" value={@app_url} required />
          <.input name="app_email" label="Application Email" type="email" value={@app_email} required />
          <.input name="state_retention" label="State Retention (versions per unit)" type="number" value={@state_retention} hint="Number of state versions to keep per unit. Set to 0 to keep all versions." />
          <.button type="submit" variant="primary">Save</.button>
        </form>
      </.card>

      <%!-- SSO Settings --%>
      <.card :if={@tab == "sso"} class="mb-6">
        <h3 class="text-lg font-semibold mb-4">Single Sign-On (SSO)</h3>
        <form phx-submit="save_sso" phx-change="sso_form_change" class="space-y-4">
          <.input name="auth_password_enabled" type="checkbox" label="Password Login Enabled" checked={@password_enabled} />
          <.input name="auth_sso_enabled" type="checkbox" label="SSO Login Enabled" checked={@sso_enabled} />
          <.input name="sso_jit_enabled" type="checkbox" label="JIT User Provisioning" checked={@jit_enabled} hint="Auto-create users on first SSO login. Disable if users should be provisioned via SCIM only." />

          <.input name="sso_protocol" label="Protocol" type="select" value={@sso_protocol} options={[{"OIDC", "oidc"}, {"SAML", "saml"}]} />
          <.input name="sso_login_label" label="Login Button Label" value={@sso_login_label} />

          <%!-- OIDC fields --%>
          <div :if={@sso_protocol == "oidc"}>
            <div class="bg-badge-info-bg rounded-lg p-4 text-sm space-y-1 mb-4">
              <p class="font-medium">Use in your Identity Provider:</p>
              <p>Sign-in redirect URI: <code class="bg-input px-1 rounded">{@oidc_redirect_uri}</code></p>
              <p>Sign-out redirect URI: <code class="bg-input px-1 rounded">{@oidc_signout_uri}</code></p>
              <p>Grant type: Authorization Code (no Refresh Token needed)</p>
            </div>
            <div class="space-y-4">
              <.input name="sso_issuer" label="Issuer URL" type="url" value={@sso_issuer} placeholder="https://your-idp.com" />
              <.input name="sso_client_id" label="Client ID" value={@sso_client_id} />
              <.input name="sso_client_secret" label="Client Secret" type="password" value={@sso_client_secret} />
            </div>
          </div>

          <%!-- SAML fields --%>
          <div :if={@sso_protocol == "saml"}>
            <div class="bg-badge-info-bg rounded-lg p-4 text-sm space-y-1 mb-4">
              <p class="font-medium">Use in your Identity Provider:</p>
              <p>SP Metadata URL: <code class="bg-input px-1 rounded">{@app_url}/saml/metadata</code></p>
              <p>ACS URL: <code class="bg-input px-1 rounded">{@saml_acs_url}</code></p>
              <p>Audience URI (SP Entity ID): <code class="bg-input px-1 rounded">{if @saml_sp_entity_id == "", do: "#{@app_url}/saml/metadata", else: @saml_sp_entity_id}</code></p>
              <p>NameID format: EmailAddress</p>
            </div>
            <div class="space-y-4">
              <.input name="sso_saml_idp_sso_url" label="IdP SSO URL" type="url" value={@saml_idp_sso_url} placeholder="https://idp.example.com/sso" />
              <.input name="sso_saml_idp_issuer" label="IdP Issuer / Entity ID" value={@saml_idp_issuer} />
              <.input name="sso_saml_idp_cert" label="IdP X.509 Certificate (PEM)" type="textarea" value={@saml_idp_cert} />
              <.input name="sso_saml_idp_metadata_url" label="IdP Metadata URL (optional)" type="url" value={@saml_idp_metadata_url} />
              <.input name="sso_saml_sp_entity_id" label="SP Entity ID / Audience URI (optional)" value={@saml_sp_entity_id} placeholder={"#{@app_url}/saml/metadata"} hint={"Defaults to #{@app_url}/saml/metadata if left blank"} />
              <.input name="sso_saml_sign_requests" type="checkbox" label="Sign AuthnRequests" checked={@saml_sign_requests} />
              <div :if={@saml_sign_requests} class="mt-3 space-y-3">
                <div :if={@saml_sp_cert == ""}>
                  <.button type="button" phx-click="generate_saml_cert" variant="primary" size="sm">Generate SP Certificate</.button>
                </div>
                <div :if={@saml_sp_cert != ""}>
                  <label class="block text-sm font-medium text-secondary mb-1">SP Certificate (PEM)</label>
                  <pre id="saml-cert-content" class="bg-inset rounded-lg p-3 text-xs font-mono whitespace-pre-wrap break-all max-h-40 overflow-auto">{@saml_sp_cert}</pre>
                  <div class="flex gap-2 mt-2">
                    <.copy_button id="copy-cert" target="#saml-cert-content">Copy</.copy_button>
                    <a href={"data:application/x-pem-file;base64,#{Base.encode64(@saml_sp_cert)}"} download="lynx-sp-cert.pem" class="px-3 py-1.5 text-xs rounded-lg bg-input text-secondary border border-border-input hover:bg-surface-secondary cursor-pointer">Download</a>
                    <.button type="button" phx-click="confirm_action" phx-value-event="regenerate_saml_cert" phx-value-message="Regenerate certificate? The old certificate will be invalidated." phx-value-uuid="" variant="secondary" size="sm">Regenerate</.button>
                  </div>
                </div>
              </div>
            </div>
          </div>

          <.button type="submit" variant="primary">Save SSO Settings</.button>
        </form>
      </.card>

      <%!-- SCIM Settings --%>
      <.card :if={@tab == "scim"} class="mb-6">
        <h3 class="text-lg font-semibold mb-4">SCIM Provisioning</h3>
        <div class="space-y-4">
          <label class="flex items-center gap-3 cursor-pointer" phx-click="toggle_scim">
            <input type="checkbox" checked={@scim_enabled} class="rounded" />
            <span class="text-sm font-medium">SCIM Enabled</span>
          </label>

          <div :if={@scim_enabled}>
            <div class="bg-badge-info-bg rounded-lg p-4 text-sm space-y-1 mb-4">
              <p>SCIM Base URL: <code class="bg-input px-1 rounded">{@app_url}/scim/v2</code></p>
              <p>Unique identifier: <code class="bg-input px-1 rounded">userName</code></p>
              <p>Auth: HTTP Header (Bearer token)</p>
            </div>

            <div class="flex items-center justify-between mb-3">
              <span class="text-sm font-medium">Bearer Tokens</span>
              <.button phx-click="generate_scim_token" variant="primary" size="sm">Generate Token</.button>
            </div>

            <div :if={@new_token} class="bg-flash-success-bg border border-flash-success-border rounded-lg p-4 mb-4">
              <p class="text-sm font-medium text-flash-success-text">New token (copy now, won't be shown again):</p>
              <code id="scim-token-content" class="text-sm break-all">{@new_token}</code>
              <div class="mt-2">
                <.copy_button id="copy-scim-token" target="#scim-token-content">Copy</.copy_button>
              </div>
            </div>

            <.table rows={@scim_tokens} empty_message="No tokens generated yet.">
              <:col :let={t} label="Token"><code class="text-xs">{t.token_prefix}</code></:col>
              <:col :let={t} label="Description">{t.description || "-"}</:col>
              <:col :let={t} label="Status">
                <.badge color={if t.is_active, do: "green", else: "gray"}>{if t.is_active, do: "Active", else: "Revoked"}</.badge>
              </:col>
              <:col :let={t} label="Last Used">{if t.last_used_at, do: Calendar.strftime(t.last_used_at, "%Y-%m-%d %H:%M"), else: "Never"}</:col>
              <:action :let={t}>
                <.button :if={t.is_active} phx-click="confirm_action" phx-value-event="revoke_token" phx-value-message="Revoke this token?" phx-value-uuid={t.uuid} variant="ghost" size="sm">Revoke</.button>
              </:action>
            </.table>
          </div>
        </div>
      </.card>

      <%!-- OIDC Providers --%>
      <.card :if={@tab == "oidc"}>
        <h3 class="text-lg font-semibold mb-2">OIDC Providers (Terraform Backend Auth)</h3>
        <p class="text-sm text-muted mb-4">The provider name is used as the HTTP Basic Auth username, and the OIDC JWT token is the password.</p>

        <div :if={@show_add_provider} class="border border-border rounded-lg p-4 mb-4">
          <form phx-submit="create_provider" class="space-y-4">
            <.input name="name" label="Provider Name" value="" required placeholder="github-actions" hint="Used as HTTP Basic Auth username in Terraform" />
            <.input name="discovery_url" label="Discovery URL" type="url" value="" required placeholder="https://token.actions.githubusercontent.com" />
            <.input name="audience" label="Audience (optional)" value="" placeholder="lynx" />
            <div class="flex gap-3">
              <.button type="submit" variant="primary" size="sm">Save</.button>
              <.button phx-click="hide_add_provider" variant="secondary" size="sm">Cancel</.button>
            </div>
          </form>
        </div>

        <div :if={!@show_add_provider} class="flex justify-end mb-3">
          <.button phx-click="show_add_provider" variant="primary" size="sm">Add Provider</.button>
        </div>

        <.table rows={@oidc_providers} empty_message="No OIDC providers configured.">
          <:col :let={p} label="Name (username)"><code class="text-xs">{p.name}</code></:col>
          <:col :let={p} label="Discovery URL"><span class="text-xs truncate max-w-xs block">{p.discovery_url}</span></:col>
          <:col :let={p} label="Audience">{p.audience || "-"}</:col>
          <:action :let={p}>
            <.button phx-click="confirm_action" phx-value-event="delete_provider" phx-value-message="Delete this provider and all its rules?" phx-value-uuid={p.uuid} variant="ghost" size="sm">Delete</.button>
          </:action>
        </.table>

        <p class="text-xs text-muted mt-3">
          Common discovery URLs:<br />
          GitHub Actions: <code>https://token.actions.githubusercontent.com</code><br />
          GitLab CI: <code>https://gitlab.com</code>
        </p>
      </.card>
    </div>
    """
  end

  # -- General --
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

  def handle_event("save_general", params, socket) do
    old = %{
      app_name: socket.assigns.app_name,
      app_url: socket.assigns.app_url,
      app_email: socket.assigns.app_email,
      state_retention: socket.assigns.state_retention
    }

    Settings.update_configs(%{
      app_name: params["app_name"],
      app_url: params["app_url"],
      app_email: params["app_email"]
    })

    retention =
      case params["state_retention"] do
        nil -> "0"
        "" -> "0"
        v -> v
      end

    Settings.upsert_config("state_retention_count", retention)

    changed =
      []
      |> then(fn l -> if params["app_name"] != old.app_name, do: ["app_name" | l], else: l end)
      |> then(fn l -> if params["app_url"] != old.app_url, do: ["app_url" | l], else: l end)
      |> then(fn l -> if params["app_email"] != old.app_email, do: ["app_email" | l], else: l end)
      |> then(fn l ->
        if retention != old.state_retention, do: ["state_retention" | l], else: l
      end)

    label =
      if changed == [], do: "general (no changes)", else: "general (#{Enum.join(changed, ", ")})"

    AuditContext.log_user(socket.assigns.current_user, "updated", "settings", nil, label)

    {:noreply,
     socket
     |> assign(:app_name, params["app_name"])
     |> assign(:app_url, params["app_url"])
     |> assign(:app_email, params["app_email"])
     |> assign(:state_retention, retention)
     |> put_flash(:info, "Settings saved")}
  end

  # -- SSO --
  def handle_event("sso_form_change", params, socket) do
    protocol = params["sso_protocol"] || socket.assigns.sso_protocol
    sign_requests = params["sso_saml_sign_requests"] == "true"

    {:noreply,
     socket
     |> assign(:sso_protocol, protocol)
     |> assign(:saml_sign_requests, sign_requests)}
  end

  def handle_event("generate_saml_cert", _, socket) do
    case Lynx.Service.SAMLService.generate_sp_certificate() do
      {:ok, %{cert_pem: cert_pem, key_pem: key_pem}} ->
        Settings.upsert_config("sso_saml_sp_cert", cert_pem)
        Settings.upsert_config("sso_saml_sp_key", key_pem)
        Settings.upsert_config("sso_saml_sign_requests", "true")
        AuditContext.log_user(socket.assigns.current_user, "generated", "saml_certificate")

        {:noreply,
         socket
         |> assign(:saml_sp_cert, cert_pem)
         |> assign(:saml_sign_requests, true)
         |> put_flash(:info, "SP certificate generated")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to generate certificate")}
    end
  end

  def handle_event("regenerate_saml_cert", _, socket) do
    socket = assign(socket, :confirm, nil)

    case Lynx.Service.SAMLService.generate_sp_certificate() do
      {:ok, %{cert_pem: cert_pem, key_pem: key_pem}} ->
        Settings.upsert_config("sso_saml_sp_cert", cert_pem)
        Settings.upsert_config("sso_saml_sp_key", key_pem)
        AuditContext.log_user(socket.assigns.current_user, "generated", "saml_certificate")

        {:noreply,
         socket
         |> assign(:saml_sp_cert, cert_pem)
         |> put_flash(:info, "SP certificate regenerated")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to regenerate certificate")}
    end
  end

  def handle_event("save_sso", params, socket) do
    protocol = params["sso_protocol"] || socket.assigns.sso_protocol

    configs = %{
      "auth_password_enabled" =>
        if(params["auth_password_enabled"] == "true", do: "true", else: "false"),
      "auth_sso_enabled" => if(params["auth_sso_enabled"] == "true", do: "true", else: "false"),
      "sso_jit_enabled" => if(params["sso_jit_enabled"] == "true", do: "true", else: "false"),
      "sso_protocol" => protocol,
      "sso_login_label" => params["sso_login_label"] || socket.assigns.sso_login_label,
      # OIDC fields — preserve existing when SAML tab is active
      "sso_issuer" => Map.get(params, "sso_issuer", socket.assigns.sso_issuer),
      "sso_client_id" => Map.get(params, "sso_client_id", socket.assigns.sso_client_id),
      "sso_client_secret" =>
        Map.get(params, "sso_client_secret", socket.assigns.sso_client_secret),
      # SAML fields — preserve existing when OIDC tab is active
      "sso_saml_idp_sso_url" =>
        Map.get(params, "sso_saml_idp_sso_url", socket.assigns.saml_idp_sso_url),
      "sso_saml_idp_issuer" =>
        Map.get(params, "sso_saml_idp_issuer", socket.assigns.saml_idp_issuer),
      "sso_saml_idp_cert" => Map.get(params, "sso_saml_idp_cert", socket.assigns.saml_idp_cert),
      "sso_saml_idp_metadata_url" =>
        Map.get(params, "sso_saml_idp_metadata_url", socket.assigns.saml_idp_metadata_url),
      "sso_saml_sp_entity_id" =>
        Map.get(params, "sso_saml_sp_entity_id", socket.assigns.saml_sp_entity_id),
      "sso_saml_sign_requests" =>
        if(Map.has_key?(params, "sso_saml_sign_requests"),
          do: if(params["sso_saml_sign_requests"] == "true", do: "true", else: "false"),
          else: to_string(socket.assigns.saml_sign_requests)
        )
    }

    old_sso = %{
      "auth_password_enabled" => to_string(socket.assigns.password_enabled),
      "auth_sso_enabled" => to_string(socket.assigns.sso_enabled),
      "sso_protocol" => socket.assigns.sso_protocol,
      "sso_login_label" => socket.assigns.sso_login_label,
      "sso_issuer" => socket.assigns.sso_issuer,
      "sso_client_id" => socket.assigns.sso_client_id,
      "sso_saml_idp_sso_url" => socket.assigns.saml_idp_sso_url,
      "sso_saml_idp_issuer" => socket.assigns.saml_idp_issuer,
      "sso_saml_idp_cert" => socket.assigns.saml_idp_cert,
      "sso_saml_idp_metadata_url" => socket.assigns.saml_idp_metadata_url,
      "sso_saml_sp_entity_id" => socket.assigns.saml_sp_entity_id,
      "sso_saml_sign_requests" => to_string(socket.assigns.saml_sign_requests)
    }

    changed =
      Enum.filter(configs, fn {k, v} -> Map.get(old_sso, k) != v end)
      |> Enum.map(fn {k, _} -> k end)

    label = if changed == [], do: "sso (no changes)", else: "sso (#{Enum.join(changed, ", ")})"

    Settings.update_sso_configs(configs)
    AuditContext.log_user(socket.assigns.current_user, "updated", "settings", nil, label)

    {:noreply,
     socket
     |> put_flash(:info, "SSO settings saved")
     |> assign(:password_enabled, configs["auth_password_enabled"] == "true")
     |> assign(:sso_enabled, configs["auth_sso_enabled"] == "true")
     |> assign(:sso_protocol, protocol)
     |> assign(:saml_idp_sso_url, configs["sso_saml_idp_sso_url"])
     |> assign(:saml_idp_issuer, configs["sso_saml_idp_issuer"])
     |> assign(:saml_idp_cert, configs["sso_saml_idp_cert"])
     |> assign(:saml_idp_metadata_url, configs["sso_saml_idp_metadata_url"])
     |> assign(:saml_sp_entity_id, configs["sso_saml_sp_entity_id"])
     |> assign(:saml_sign_requests, configs["sso_saml_sign_requests"] == "true")}
  end

  # -- SCIM --
  def handle_event("toggle_scim", _, socket) do
    new_val = !socket.assigns.scim_enabled
    Settings.update_sso_configs(%{"scim_enabled" => if(new_val, do: "true", else: "false")})
    {:noreply, assign(socket, :scim_enabled, new_val)}
  end

  def handle_event("generate_scim_token", _, socket) do
    case SCIMTokenContext.generate_token("") do
      {:ok, result} ->
        AuditContext.log_user(socket.assigns.current_user, "generated", "scim_token", result.uuid)

        {:noreply,
         socket
         |> assign(:new_token, result.token)
         |> assign(:scim_tokens, SCIMTokenContext.list_tokens())}

      {:error, msg} ->
        {:noreply, put_flash(socket, :error, msg)}
    end
  end

  def handle_event("revoke_token", %{"uuid" => uuid}, socket) do
    socket = assign(socket, :confirm, nil)
    SCIMTokenContext.revoke_token_by_uuid(uuid)
    AuditContext.log_user(socket.assigns.current_user, "revoked", "scim_token", uuid)

    {:noreply,
     socket
     |> assign(:scim_tokens, SCIMTokenContext.list_tokens())
     |> put_flash(:info, "Token revoked")}
  end

  # -- OIDC Providers --
  def handle_event("show_add_provider", _, socket),
    do: {:noreply, assign(socket, :show_add_provider, true)}

  def handle_event("hide_add_provider", _, socket),
    do: {:noreply, assign(socket, :show_add_provider, false)}

  def handle_event("create_provider", params, socket) do
    case OIDCBackend.create_provider(%{
           name: params["name"],
           discovery_url: params["discovery_url"],
           audience: params["audience"]
         }) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:show_add_provider, false)
         |> assign(:oidc_providers, OIDCBackend.list_providers())
         |> put_flash(:info, "Provider created")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to create provider")}
    end
  end

  def handle_event("delete_provider", %{"uuid" => uuid}, socket) do
    socket = assign(socket, :confirm, nil)
    OIDCBackend.delete_provider(uuid)

    {:noreply,
     socket
     |> assign(:oidc_providers, OIDCBackend.list_providers())
     |> put_flash(:info, "Provider deleted")}
  end
end

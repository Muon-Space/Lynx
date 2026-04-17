defmodule LynxWeb.SettingsLive do
  use LynxWeb, :live_view

  alias Lynx.Module.SettingsModule
  alias Lynx.Module.SCIMTokenModule
  alias Lynx.Module.OIDCBackendModule
  alias Lynx.Module.AuditModule

  on_mount {LynxWeb.LiveAuth, :require_super}

  @impl true
  def mount(_params, _session, socket) do
    app_url =
      SettingsModule.get_config("app_url", "http://localhost:4000") |> String.trim_trailing("/")

    socket =
      socket
      |> assign(:app_name, SettingsModule.get_config("app_name", ""))
      |> assign(:app_url, app_url)
      |> assign(:app_email, SettingsModule.get_config("app_email", ""))
      |> assign(:state_retention, SettingsModule.get_config("state_retention_count", "0"))
      # SSO
      |> assign(
        :password_enabled,
        SettingsModule.get_sso_config("auth_password_enabled", "true") == "true"
      )
      |> assign(
        :sso_enabled,
        SettingsModule.get_sso_config("auth_sso_enabled", "false") == "true"
      )
      |> assign(:jit_enabled, SettingsModule.get_sso_config("sso_jit_enabled", "true") == "true")
      |> assign(:sso_protocol, SettingsModule.get_sso_config("sso_protocol", "oidc"))
      |> assign(:sso_login_label, SettingsModule.get_sso_config("sso_login_label", "SSO"))
      |> assign(:sso_issuer, SettingsModule.get_sso_config("sso_issuer", ""))
      |> assign(:sso_client_id, SettingsModule.get_sso_config("sso_client_id", ""))
      |> assign(:sso_client_secret, SettingsModule.get_sso_config("sso_client_secret", ""))
      |> assign(:saml_idp_sso_url, SettingsModule.get_sso_config("sso_saml_idp_sso_url", ""))
      |> assign(:saml_idp_issuer, SettingsModule.get_sso_config("sso_saml_idp_issuer", ""))
      |> assign(:saml_idp_cert, SettingsModule.get_sso_config("sso_saml_idp_cert", ""))
      |> assign(
        :saml_idp_metadata_url,
        SettingsModule.get_sso_config("sso_saml_idp_metadata_url", "")
      )
      |> assign(:saml_sp_entity_id, SettingsModule.get_sso_config("sso_saml_sp_entity_id", ""))
      |> assign(
        :saml_sign_requests,
        SettingsModule.get_sso_config("sso_saml_sign_requests", "false") == "true"
      )
      |> assign(:saml_sp_cert, SettingsModule.get_sso_config("sso_saml_sp_cert", ""))
      # SCIM
      |> assign(:scim_enabled, SettingsModule.get_sso_config("scim_enabled", "false") == "true")
      |> assign(:scim_tokens, SCIMTokenModule.list_tokens())
      |> assign(:new_token, nil)
      # OIDC Providers
      |> assign(:oidc_providers, OIDCBackendModule.list_providers())
      |> assign(:show_add_provider, false)
      # Computed
      |> assign(:oidc_redirect_uri, app_url <> "/auth/sso/callback")
      |> assign(:oidc_signout_uri, app_url <> "/logout")
      |> assign(:saml_acs_url, app_url <> "/auth/sso/saml_callback")

    socket = assign(socket, :confirm, nil)
    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.confirm_dialog :if={@confirm} message={@confirm.message} confirm_event={@confirm.event} confirm_value={@confirm.value} />
    <.nav current_user={@current_user} active="settings" />
    <div class="max-w-7xl mx-auto px-6 pb-16">
      <.page_header title="Settings" subtitle="Configure authentication, SSO, and system preferences" />

      <%!-- General Settings --%>
      <.card class="mb-6">
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
      <.card class="mb-6">
        <h3 class="text-lg font-semibold mb-4">Single Sign-On (SSO)</h3>
        <form phx-submit="save_sso" phx-change="sso_form_change" class="space-y-4">
          <.input name="auth_password_enabled" type="checkbox" label="Password Login Enabled" checked={@password_enabled} />
          <.input name="auth_sso_enabled" type="checkbox" label="SSO Login Enabled" checked={@sso_enabled} />
          <.input name="sso_jit_enabled" type="checkbox" label="JIT User Provisioning" checked={@jit_enabled} hint="Auto-create users on first SSO login. Disable if users should be provisioned via SCIM only." />

          <.input name="sso_protocol" label="Protocol" type="select" value={@sso_protocol} options={[{"OIDC", "oidc"}, {"SAML", "saml"}]} />
          <.input name="sso_login_label" label="Login Button Label" value={@sso_login_label} />

          <%!-- OIDC fields --%>
          <div :if={@sso_protocol == "oidc"}>
            <div class="bg-blue-50 dark:bg-blue-900/20 rounded-lg p-4 text-sm space-y-1 mb-4">
              <p class="font-medium">Use in your Identity Provider:</p>
              <p>Sign-in redirect URI: <code class="bg-white dark:bg-gray-800 px-1 rounded">{@oidc_redirect_uri}</code></p>
              <p>Sign-out redirect URI: <code class="bg-white dark:bg-gray-800 px-1 rounded">{@oidc_signout_uri}</code></p>
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
            <div class="bg-blue-50 dark:bg-blue-900/20 rounded-lg p-4 text-sm space-y-1 mb-4">
              <p class="font-medium">Use in your Identity Provider:</p>
              <p>ACS URL: <code class="bg-white dark:bg-gray-800 px-1 rounded">{@saml_acs_url}</code></p>
              <p>Audience URI (SP Entity ID): <code class="bg-white dark:bg-gray-800 px-1 rounded">{@saml_sp_entity_id}</code></p>
              <p>NameID format: EmailAddress</p>
            </div>
            <div class="space-y-4">
              <.input name="sso_saml_idp_sso_url" label="IdP SSO URL" type="url" value={@saml_idp_sso_url} placeholder="https://idp.example.com/sso" />
              <.input name="sso_saml_idp_issuer" label="IdP Issuer / Entity ID" value={@saml_idp_issuer} />
              <.input name="sso_saml_idp_cert" label="IdP X.509 Certificate (PEM)" type="textarea" value={@saml_idp_cert} />
              <.input name="sso_saml_idp_metadata_url" label="IdP Metadata URL (optional)" type="url" value={@saml_idp_metadata_url} />
              <.input name="sso_saml_sp_entity_id" label="SP Entity ID / Audience URI" value={@saml_sp_entity_id} />
              <.input name="sso_saml_sign_requests" type="checkbox" label="Sign AuthnRequests" checked={@saml_sign_requests} />
              <div :if={@saml_sign_requests} class="mt-3 space-y-3">
                <div :if={@saml_sp_cert == ""}>
                  <.button type="button" phx-click="generate_saml_cert" variant="primary" size="sm">Generate SP Certificate</.button>
                </div>
                <div :if={@saml_sp_cert != ""}>
                  <label class="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">SP Certificate (PEM)</label>
                  <pre id="saml-cert-content" class="bg-gray-100 dark:bg-gray-800 rounded-lg p-3 text-xs font-mono whitespace-pre-wrap break-all max-h-40 overflow-auto">{@saml_sp_cert}</pre>
                  <div class="flex gap-2 mt-2">
                    <button type="button" id="copy-cert" phx-hook="CopyToClipboard" data-target="#saml-cert-content" class="px-3 py-1.5 text-xs rounded-lg bg-white dark:bg-gray-800 text-gray-700 dark:text-gray-300 border border-gray-300 dark:border-gray-600 hover:bg-gray-50 dark:hover:bg-gray-700 cursor-pointer">Copy</button>
                    <a href={"data:application/x-pem-file;base64,#{Base.encode64(@saml_sp_cert)}"} download="lynx-sp-cert.pem" class="px-3 py-1.5 text-xs rounded-lg bg-white dark:bg-gray-800 text-gray-700 dark:text-gray-300 border border-gray-300 dark:border-gray-600 hover:bg-gray-50 dark:hover:bg-gray-700 cursor-pointer">Download</a>
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
      <.card class="mb-6">
        <h3 class="text-lg font-semibold mb-4">SCIM Provisioning</h3>
        <div class="space-y-4">
          <label class="flex items-center gap-3 cursor-pointer" phx-click="toggle_scim">
            <input type="checkbox" checked={@scim_enabled} class="rounded" />
            <span class="text-sm font-medium">SCIM Enabled</span>
          </label>

          <div :if={@scim_enabled}>
            <div class="bg-blue-50 dark:bg-blue-900/20 rounded-lg p-4 text-sm space-y-1 mb-4">
              <p>SCIM Base URL: <code class="bg-white dark:bg-gray-800 px-1 rounded">{@app_url}/scim/v2</code></p>
              <p>Unique identifier: <code class="bg-white dark:bg-gray-800 px-1 rounded">userName</code></p>
              <p>Auth: HTTP Header (Bearer token)</p>
            </div>

            <div class="flex items-center justify-between mb-3">
              <span class="text-sm font-medium">Bearer Tokens</span>
              <.button phx-click="generate_scim_token" variant="primary" size="sm">Generate Token</.button>
            </div>

            <div :if={@new_token} class="bg-emerald-50 dark:bg-emerald-900/20 border border-emerald-200 dark:border-emerald-800 rounded-lg p-4 mb-4">
              <p class="text-sm font-medium text-emerald-800">New token (copy now, won't be shown again):</p>
              <code class="text-sm break-all">{@new_token}</code>
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
      <.card>
        <h3 class="text-lg font-semibold mb-2">OIDC Providers (Terraform Backend Auth)</h3>
        <p class="text-sm text-gray-500 mb-4">The provider name is used as the HTTP Basic Auth username, and the OIDC JWT token is the password.</p>

        <div :if={@show_add_provider} class="border border-gray-200 dark:border-gray-700 rounded-lg p-4 mb-4">
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

        <p class="text-xs text-gray-400 mt-3">
          Common: GitHub Actions: <code>https://token.actions.githubusercontent.com</code> · GitLab CI: <code>https://gitlab.com</code>
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
    SettingsModule.update_configs(%{
      app_name: params["app_name"],
      app_url: params["app_url"],
      app_email: params["app_email"]
    })

    retention = params["state_retention"] || "0"
    SettingsModule.upsert_config("state_retention_count", retention)

    AuditModule.log_user(socket.assigns.current_user, "updated", "settings", nil, "general")

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
      {:ok, %{cert_pem: cert_pem}} ->
        SettingsModule.upsert_config("sso_saml_sp_cert", cert_pem)
        SettingsModule.upsert_config("sso_saml_sign_requests", "true")
        AuditModule.log_user(socket.assigns.current_user, "generated", "saml_certificate")

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
      {:ok, %{cert_pem: cert_pem}} ->
        SettingsModule.upsert_config("sso_saml_sp_cert", cert_pem)
        AuditModule.log_user(socket.assigns.current_user, "generated", "saml_certificate")

        {:noreply,
         socket
         |> assign(:saml_sp_cert, cert_pem)
         |> put_flash(:info, "SP certificate regenerated")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to regenerate certificate")}
    end
  end

  def handle_event("save_sso", params, socket) do
    configs = %{
      "auth_password_enabled" =>
        if(params["auth_password_enabled"] == "true", do: "true", else: "false"),
      "auth_sso_enabled" => if(params["auth_sso_enabled"] == "true", do: "true", else: "false"),
      "sso_jit_enabled" => if(params["sso_jit_enabled"] == "true", do: "true", else: "false"),
      "sso_protocol" => params["sso_protocol"],
      "sso_login_label" => params["sso_login_label"],
      "sso_issuer" => params["sso_issuer"] || "",
      "sso_client_id" => params["sso_client_id"] || "",
      "sso_client_secret" => params["sso_client_secret"] || ""
    }

    SettingsModule.update_sso_configs(configs)
    AuditModule.log_user(socket.assigns.current_user, "updated", "settings", nil, "sso")

    {:noreply,
     socket
     |> put_flash(:info, "SSO settings saved")
     |> assign(:password_enabled, configs["auth_password_enabled"] == "true")
     |> assign(:sso_enabled, configs["auth_sso_enabled"] == "true")}
  end

  # -- SCIM --
  def handle_event("toggle_scim", _, socket) do
    new_val = !socket.assigns.scim_enabled
    SettingsModule.update_sso_configs(%{"scim_enabled" => if(new_val, do: "true", else: "false")})
    {:noreply, assign(socket, :scim_enabled, new_val)}
  end

  def handle_event("generate_scim_token", _, socket) do
    case SCIMTokenModule.generate_token("") do
      {:ok, result} ->
        AuditModule.log_user(socket.assigns.current_user, "generated", "scim_token", result.uuid)

        {:noreply,
         socket
         |> assign(:new_token, result.token)
         |> assign(:scim_tokens, SCIMTokenModule.list_tokens())}

      {:error, msg} ->
        {:noreply, put_flash(socket, :error, msg)}
    end
  end

  def handle_event("revoke_token", %{"uuid" => uuid}, socket) do
    socket = assign(socket, :confirm, nil)
    SCIMTokenModule.revoke_token(uuid)
    AuditModule.log_user(socket.assigns.current_user, "revoked", "scim_token", uuid)

    {:noreply,
     socket
     |> assign(:scim_tokens, SCIMTokenModule.list_tokens())
     |> put_flash(:info, "Token revoked")}
  end

  # -- OIDC Providers --
  def handle_event("show_add_provider", _, socket),
    do: {:noreply, assign(socket, :show_add_provider, true)}

  def handle_event("hide_add_provider", _, socket),
    do: {:noreply, assign(socket, :show_add_provider, false)}

  def handle_event("create_provider", params, socket) do
    case OIDCBackendModule.create_provider(%{
           name: params["name"],
           discovery_url: params["discovery_url"],
           audience: params["audience"]
         }) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:show_add_provider, false)
         |> assign(:oidc_providers, OIDCBackendModule.list_providers())
         |> put_flash(:info, "Provider created")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to create provider")}
    end
  end

  def handle_event("delete_provider", %{"uuid" => uuid}, socket) do
    socket = assign(socket, :confirm, nil)
    OIDCBackendModule.delete_provider(uuid)

    {:noreply,
     socket
     |> assign(:oidc_providers, OIDCBackendModule.list_providers())
     |> put_flash(:info, "Provider deleted")}
  end
end

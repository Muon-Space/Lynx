defmodule LynxWeb.SettingsLive do
  use LynxWeb, :live_view

  alias Lynx.Module.SettingsModule
  alias Lynx.Module.SSOModule
  alias Lynx.Module.SCIMTokenModule
  alias Lynx.Module.OIDCBackendModule
  alias Lynx.Module.AuditModule

  on_mount {LynxWeb.LiveAuth, :require_super}

  @impl true
  def mount(_params, _session, socket) do
    app_url = SettingsModule.get_config("app_url", "http://localhost:4000") |> String.trim_trailing("/")

    socket =
      socket
      |> assign(:app_name, SettingsModule.get_config("app_name", ""))
      |> assign(:app_url, app_url)
      |> assign(:app_email, SettingsModule.get_config("app_email", ""))
      # SSO
      |> assign(:password_enabled, SettingsModule.get_sso_config("auth_password_enabled", "true") == "true")
      |> assign(:sso_enabled, SettingsModule.get_sso_config("auth_sso_enabled", "false") == "true")
      |> assign(:jit_enabled, SettingsModule.get_sso_config("sso_jit_enabled", "true") == "true")
      |> assign(:sso_protocol, SettingsModule.get_sso_config("sso_protocol", "oidc"))
      |> assign(:sso_login_label, SettingsModule.get_sso_config("sso_login_label", "SSO"))
      |> assign(:sso_issuer, SettingsModule.get_sso_config("sso_issuer", ""))
      |> assign(:sso_client_id, SettingsModule.get_sso_config("sso_client_id", ""))
      |> assign(:sso_client_secret, SettingsModule.get_sso_config("sso_client_secret", ""))
      |> assign(:saml_idp_sso_url, SettingsModule.get_sso_config("sso_saml_idp_sso_url", ""))
      |> assign(:saml_idp_issuer, SettingsModule.get_sso_config("sso_saml_idp_issuer", ""))
      |> assign(:saml_idp_cert, SettingsModule.get_sso_config("sso_saml_idp_cert", ""))
      |> assign(:saml_idp_metadata_url, SettingsModule.get_sso_config("sso_saml_idp_metadata_url", ""))
      |> assign(:saml_sp_entity_id, SettingsModule.get_sso_config("sso_saml_sp_entity_id", ""))
      |> assign(:saml_sign_requests, SettingsModule.get_sso_config("sso_saml_sign_requests", "false") == "true")
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

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.nav current_user={@current_user} active="settings" />
    <div class="max-w-4xl mx-auto px-6">
      <.page_header title="Settings" />

      <%!-- General Settings --%>
      <.card class="mb-6">
        <h3 class="text-lg font-semibold mb-4">General</h3>
        <form phx-submit="save_general" class="space-y-4">
          <.input name="app_name" label="Application Name" value={@app_name} required />
          <.input name="app_url" label="Application URL" type="url" value={@app_url} required />
          <.input name="app_email" label="Application Email" type="email" value={@app_email} required />
          <.button type="submit" variant="primary">Save</.button>
        </form>
      </.card>

      <%!-- SSO Settings --%>
      <.card class="mb-6">
        <h3 class="text-lg font-semibold mb-4">Single Sign-On (SSO)</h3>
        <form phx-submit="save_sso" class="space-y-4">
          <.input name="auth_password_enabled" type="checkbox" label="Password Login Enabled" checked={@password_enabled} />
          <.input name="auth_sso_enabled" type="checkbox" label="SSO Login Enabled" checked={@sso_enabled} />
          <.input name="sso_jit_enabled" type="checkbox" label="JIT User Provisioning" checked={@jit_enabled} hint="Auto-create users on first SSO login. Disable if users should be provisioned via SCIM only." />

          <.input name="sso_protocol" label="Protocol" type="select" value={@sso_protocol} options={[{"OIDC", "oidc"}, {"SAML", "saml"}]} />
          <.input name="sso_login_label" label="Login Button Label" value={@sso_login_label} />

          <%!-- OIDC fields --%>
          <div class="bg-blue-50 rounded-lg p-4 text-sm space-y-1">
            <p class="font-medium">Use in your Identity Provider:</p>
            <p>Sign-in redirect URI: <code class="bg-white px-1 rounded">{@oidc_redirect_uri}</code></p>
            <p>Sign-out redirect URI: <code class="bg-white px-1 rounded">{@oidc_signout_uri}</code></p>
            <p>Grant type: Authorization Code (no Refresh Token needed)</p>
          </div>

          <.input name="sso_issuer" label="Issuer URL" type="url" value={@sso_issuer} placeholder="https://your-idp.com" />
          <.input name="sso_client_id" label="Client ID" value={@sso_client_id} />
          <.input name="sso_client_secret" label="Client Secret" type="password" value={@sso_client_secret} />

          <.button type="submit" variant="primary">Save SSO Settings</.button>
        </form>
      </.card>

      <%!-- SCIM Settings --%>
      <.card class="mb-6">
        <h3 class="text-lg font-semibold mb-4">SCIM Provisioning</h3>
        <div class="space-y-4">
          <div class="flex items-center gap-3">
            <input type="checkbox" checked={@scim_enabled} phx-click="toggle_scim" class="rounded" />
            <span class="text-sm font-medium">SCIM Enabled</span>
          </div>

          <div :if={@scim_enabled}>
            <div class="bg-blue-50 rounded-lg p-4 text-sm space-y-1 mb-4">
              <p>SCIM Base URL: <code class="bg-white px-1 rounded">{@app_url}/scim/v2</code></p>
              <p>Unique identifier: <code class="bg-white px-1 rounded">userName</code></p>
              <p>Auth: HTTP Header (Bearer token)</p>
            </div>

            <div class="flex items-center justify-between mb-3">
              <span class="text-sm font-medium">Bearer Tokens</span>
              <.button phx-click="generate_scim_token" variant="primary" size="sm">Generate Token</.button>
            </div>

            <div :if={@new_token} class="bg-emerald-50 border border-emerald-200 rounded-lg p-4 mb-4">
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
                <.button :if={t.is_active} phx-click="revoke_token" phx-value-uuid={t.uuid} variant="ghost" size="sm" data-confirm="Revoke this token?">Revoke</.button>
              </:action>
            </.table>
          </div>
        </div>
      </.card>

      <%!-- OIDC Providers --%>
      <.card>
        <h3 class="text-lg font-semibold mb-2">OIDC Providers (Terraform Backend Auth)</h3>
        <p class="text-sm text-gray-500 mb-4">The provider name is used as the HTTP Basic Auth username, and the OIDC JWT token is the password.</p>

        <div :if={@show_add_provider} class="border rounded-lg p-4 mb-4">
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
            <.button phx-click="delete_provider" phx-value-uuid={p.uuid} variant="ghost" size="sm" data-confirm="Delete this provider and all its rules?">Delete</.button>
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
  def handle_event("save_general", params, socket) do
    SettingsModule.update_configs(%{app_name: params["app_name"], app_url: params["app_url"], app_email: params["app_email"]})
    AuditModule.log_system("updated", "settings", nil, "general")
    {:noreply, socket |> assign(:app_name, params["app_name"]) |> assign(:app_url, params["app_url"]) |> assign(:app_email, params["app_email"]) |> put_flash(:info, "Settings saved")}
  end

  # -- SSO --
  def handle_event("save_sso", params, socket) do
    configs = %{
      "auth_password_enabled" => if(params["auth_password_enabled"], do: "true", else: "false"),
      "auth_sso_enabled" => if(params["auth_sso_enabled"], do: "true", else: "false"),
      "sso_jit_enabled" => if(params["sso_jit_enabled"], do: "true", else: "false"),
      "sso_protocol" => params["sso_protocol"],
      "sso_login_label" => params["sso_login_label"],
      "sso_issuer" => params["sso_issuer"] || "",
      "sso_client_id" => params["sso_client_id"] || "",
      "sso_client_secret" => params["sso_client_secret"] || ""
    }
    SettingsModule.update_sso_configs(configs)
    AuditModule.log_system("updated", "settings", nil, "sso")
    {:noreply, socket |> put_flash(:info, "SSO settings saved") |> assign(:password_enabled, configs["auth_password_enabled"] == "true") |> assign(:sso_enabled, configs["auth_sso_enabled"] == "true")}
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
        AuditModule.log_system("generated", "scim_token", result.uuid)
        {:noreply, socket |> assign(:new_token, result.token) |> assign(:scim_tokens, SCIMTokenModule.list_tokens())}
      {:error, msg} ->
        {:noreply, put_flash(socket, :error, msg)}
    end
  end

  def handle_event("revoke_token", %{"uuid" => uuid}, socket) do
    SCIMTokenModule.revoke_token(uuid)
    AuditModule.log_system("revoked", "scim_token", uuid)
    {:noreply, socket |> assign(:scim_tokens, SCIMTokenModule.list_tokens()) |> put_flash(:info, "Token revoked")}
  end

  # -- OIDC Providers --
  def handle_event("show_add_provider", _, socket), do: {:noreply, assign(socket, :show_add_provider, true)}
  def handle_event("hide_add_provider", _, socket), do: {:noreply, assign(socket, :show_add_provider, false)}

  def handle_event("create_provider", params, socket) do
    case OIDCBackendModule.create_provider(%{name: params["name"], discovery_url: params["discovery_url"], audience: params["audience"]}) do
      {:ok, _} ->
        {:noreply, socket |> assign(:show_add_provider, false) |> assign(:oidc_providers, OIDCBackendModule.list_providers()) |> put_flash(:info, "Provider created")}
      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to create provider")}
    end
  end

  def handle_event("delete_provider", %{"uuid" => uuid}, socket) do
    OIDCBackendModule.delete_provider(uuid)
    {:noreply, socket |> assign(:oidc_providers, OIDCBackendModule.list_providers()) |> put_flash(:info, "Provider deleted")}
  end
end

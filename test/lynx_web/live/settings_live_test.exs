defmodule LynxWeb.SettingsLiveTest do
  use LynxWeb.LiveCase

  alias Lynx.Module.OIDCBackendModule
  alias Lynx.Module.SettingsModule

  setup %{conn: conn} do
    # save_general updates configs that must already exist (app_name, etc.)
    mark_installed()
    user = create_super()
    {:ok, conn: log_in_user(conn, user), user: user}
  end

  describe "mount" do
    test "renders Settings title and key sections", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin/settings")
      assert html =~ "Settings"
      assert html =~ "General"
      assert html =~ "Single Sign-On"
      assert html =~ "OIDC"
    end

    test "non-super user is redirected", %{conn: conn} do
      regular = create_user()
      conn = log_in_user(conn, regular)
      assert {:error, {:redirect, %{to: "/login"}}} = live(conn, "/admin/settings")
    end
  end

  describe "save_general" do
    test "persists app_name, app_url, app_email, state retention", %{conn: conn} do
      {:ok, view, _} = live(conn, "/admin/settings")

      render_submit(view, "save_general", %{
        "app_name" => "Lynx Prod",
        "app_url" => "https://lynx.prod",
        "app_email" => "ops@lynx.prod",
        "state_retention" => "5"
      })

      assert render(view) =~ "Settings saved"
      assert SettingsModule.get_config("app_name", "") == "Lynx Prod"
      assert SettingsModule.get_config("app_url", "") == "https://lynx.prod"
      assert SettingsModule.get_config("state_retention_count", "") == "5"
    end

    test "treats empty state_retention as 0", %{conn: conn} do
      {:ok, view, _} = live(conn, "/admin/settings")

      render_submit(view, "save_general", %{
        "app_name" => "Lynx",
        "app_url" => "https://x",
        "app_email" => "a@b.c",
        "state_retention" => ""
      })

      assert SettingsModule.get_config("state_retention_count", "") == "0"
    end
  end

  describe "save_sso" do
    test "saves SSO checkbox toggles and protocol", %{conn: conn} do
      {:ok, view, _} = live(conn, "/admin/settings")

      render_submit(view, "save_sso", %{
        "auth_password_enabled" => "true",
        "auth_sso_enabled" => "true",
        "sso_jit_enabled" => "true",
        "sso_protocol" => "saml",
        "sso_login_label" => "Acme",
        "sso_issuer" => "",
        "sso_client_id" => "",
        "sso_client_secret" => "",
        "sso_saml_idp_sso_url" => "",
        "sso_saml_idp_issuer" => "",
        "sso_saml_idp_cert" => "",
        "sso_saml_idp_metadata_url" => "",
        "sso_saml_sp_entity_id" => ""
      })

      assert render(view) =~ "SSO settings saved"
      assert SettingsModule.get_sso_config("auth_sso_enabled", "false") == "true"
      assert SettingsModule.get_sso_config("sso_protocol", "oidc") == "saml"
      assert SettingsModule.get_sso_config("sso_login_label", "") == "Acme"
    end

    test "sso_form_change toggles protocol display in real time", %{conn: conn} do
      {:ok, view, _} = live(conn, "/admin/settings")

      # Default protocol is oidc — OIDC fields visible
      assert render(view) =~ "Issuer URL"

      render_change(view, "sso_form_change", %{
        "sso_protocol" => "saml",
        "sso_saml_sign_requests" => "false"
      })

      html = render(view)
      assert html =~ "IdP SSO URL"
      refute html =~ "Issuer URL"
    end
  end

  describe "OIDC providers" do
    test "show_add_provider opens form", %{conn: conn} do
      {:ok, view, _} = live(conn, "/admin/settings")

      render_click(view, "show_add_provider", %{})
      assert has_element?(view, "form[phx-submit=\"create_provider\"]")

      render_click(view, "hide_add_provider", %{})
      refute has_element?(view, "form[phx-submit=\"create_provider\"]")
    end

    test "create_provider persists and shows in table", %{conn: conn} do
      {:ok, view, _} = live(conn, "/admin/settings")
      render_click(view, "show_add_provider", %{})

      render_submit(view, "create_provider", %{
        "name" => "github-actions",
        "discovery_url" => "https://token.actions.githubusercontent.com",
        "audience" => "lynx"
      })

      assert render(view) =~ "Provider created"
      assert render(view) =~ "github-actions"
      assert OIDCBackendModule.list_providers() |> Enum.any?(&(&1.name == "github-actions"))
    end

    test "delete_provider removes it", %{conn: conn} do
      {:ok, provider} =
        OIDCBackendModule.create_provider(%{
          name: "to-delete",
          discovery_url: "https://example.com/.well-known/openid-configuration",
          audience: "x"
        })

      {:ok, view, _} = live(conn, "/admin/settings")
      render_click(view, "delete_provider", %{"uuid" => provider.uuid})

      assert render(view) =~ "Provider deleted"
      assert OIDCBackendModule.list_providers() |> Enum.find(&(&1.uuid == provider.uuid)) == nil
    end
  end

  describe "SCIM" do
    test "toggle_scim flips the config", %{conn: conn} do
      {:ok, view, _} = live(conn, "/admin/settings")

      render_click(view, "toggle_scim", %{})
      assert SettingsModule.get_sso_config("scim_enabled", "false") == "true"

      render_click(view, "toggle_scim", %{})
      assert SettingsModule.get_sso_config("scim_enabled", "false") == "false"
    end

    test "generate_scim_token creates a token", %{conn: conn} do
      {:ok, view, _} = live(conn, "/admin/settings")

      render_click(view, "generate_scim_token", %{})

      tokens = Lynx.Module.SCIMTokenModule.list_tokens()
      assert tokens != []
    end
  end
end

# Copyright 2023 Clivern. All rights reserved.
# Use of this source code is governed by the MIT
# license that can be found in the LICENSE file.

defmodule LynxWeb.PageController do
  @moduledoc """
  Page Controller
  """
  use LynxWeb, :controller

  alias Lynx.Module.InstallModule
  alias Lynx.Service.AuthService
  alias Lynx.Module.SettingsModule
  alias Lynx.Module.PermissionModule
  alias Lynx.Module.StateModule
  alias Lynx.Module.SSOModule

  @doc """
  Login Page
  """
  def login(conn, _params) do
    is_installed = InstallModule.is_installed()

    case {is_installed, conn.assigns[:is_logged]} do
      {false, _} ->
        conn
        |> redirect(to: "/install")

      {_, true} ->
        conn
        |> redirect(to: "/admin/projects")

      {true, _} ->
        conn
        |> render("login.html",
          data: %{
            is_logged: conn.assigns[:is_logged],
            is_super: conn.assigns[:is_super],
            user_id: conn.assigns[:user_id],
            user_role: conn.assigns[:user_role],
            user_name: conn.assigns[:user_name],
            user_email: conn.assigns[:user_email],
            app_name: SettingsModule.get_config("app_name", ""),
            app_url: SettingsModule.get_config("app_url", "") |> add_backslash_to_url,
            sso_enabled: SSOModule.is_sso_enabled?(),
            password_enabled: SSOModule.is_password_enabled?(),
            sso_login_url: "/auth/sso",
            sso_login_label: SSOModule.get_sso_login_label()
          }
        )
    end
  end

  @doc """
  Logout Action
  """
  def logout(conn, _params) do
    AuthService.logout(conn.assigns[:user_id])

    conn
    |> clear_session()
    |> redirect(to: "/")
  end

  @doc """
  Install Page
  """
  def install(conn, _params) do
    is_installed = InstallModule.is_installed()

    case is_installed do
      true ->
        conn
        |> redirect(to: "/")

      false ->
        conn
        |> render("install.html",
          data: %{
            app_name: SettingsModule.get_config("app_name", "Lynx")
          }
        )
    end
  end

  @doc """
  Home Page
  """
  def home(conn, _params) do
    is_installed = InstallModule.is_installed()

    case is_installed do
      false ->
        conn
        |> redirect(to: "/install")

      true ->
        conn
        |> render("home.html",
          data: %{
            is_logged: conn.assigns[:is_logged],
            is_super: conn.assigns[:is_super],
            user_id: conn.assigns[:user_id],
            user_role: conn.assigns[:user_role],
            user_name: conn.assigns[:user_name],
            user_email: conn.assigns[:user_email],
            avatar_url: get_gavatar(conn.assigns[:user_email]),
            app_name: SettingsModule.get_config("app_name", ""),
            app_url: SettingsModule.get_config("app_url", "") |> add_backslash_to_url
          }
        )
    end
  end

  @doc """
  Not Found Page
  """
  def not_found(conn, _params) do
    is_installed = InstallModule.is_installed()

    case is_installed do
      false ->
        conn
        |> redirect(to: "/install")

      true ->
        conn
        |> render("404.html",
          data: %{
            is_logged: conn.assigns[:is_logged],
            is_super: conn.assigns[:is_super],
            user_id: conn.assigns[:user_id],
            user_role: conn.assigns[:user_role],
            user_name: conn.assigns[:user_name],
            user_email: conn.assigns[:user_email],
            avatar_url: get_gavatar(conn.assigns[:user_email]),
            app_name: SettingsModule.get_config("app_name", ""),
            app_url: SettingsModule.get_config("app_url", "") |> add_backslash_to_url
          }
        )
    end
  end

  @doc """
  Profile Page
  """
  def profile(conn, _params) do
    case conn.assigns[:is_logged] do
      false ->
        conn
        |> redirect(to: "/login")

      true ->
        conn
        |> render("profile.html",
          data: %{
            is_logged: conn.assigns[:is_logged],
            is_super: conn.assigns[:is_super],
            user_id: conn.assigns[:user_id],
            user_role: conn.assigns[:user_role],
            user_name: conn.assigns[:user_name],
            user_email: conn.assigns[:user_email],
            user_api_key: conn.assigns[:user_api_key],
            avatar_url: get_gavatar(conn.assigns[:user_email]),
            app_name: SettingsModule.get_config("app_name", ""),
            app_url: SettingsModule.get_config("app_url", "") |> add_backslash_to_url
          }
        )
    end
  end

  @doc """
  Users Page
  """
  def users(conn, _params) do
    case conn.assigns[:is_super] do
      false ->
        conn
        |> redirect(to: "/login")

      true ->
        conn
        |> render("users.html",
          data: %{
            is_logged: conn.assigns[:is_logged],
            is_super: conn.assigns[:is_super],
            user_id: conn.assigns[:user_id],
            user_role: conn.assigns[:user_role],
            user_name: conn.assigns[:user_name],
            user_email: conn.assigns[:user_email],
            avatar_url: get_gavatar(conn.assigns[:user_email]),
            app_name: SettingsModule.get_config("app_name", ""),
            app_url: SettingsModule.get_config("app_url", "") |> add_backslash_to_url
          }
        )
    end
  end

  @doc """
  Teams Page
  """
  def teams(conn, _params) do
    case conn.assigns[:is_super] do
      false ->
        conn
        |> redirect(to: "/login")

      true ->
        conn
        |> render("teams.html",
          data: %{
            is_logged: conn.assigns[:is_logged],
            is_super: conn.assigns[:is_super],
            user_id: conn.assigns[:user_id],
            user_role: conn.assigns[:user_role],
            user_name: conn.assigns[:user_name],
            user_email: conn.assigns[:user_email],
            avatar_url: get_gavatar(conn.assigns[:user_email]),
            app_name: SettingsModule.get_config("app_name", ""),
            app_url: SettingsModule.get_config("app_url", "") |> add_backslash_to_url
          }
        )
    end
  end

  @doc """
  Settings Page
  """
  def settings(conn, _params) do
    case conn.assigns[:is_super] do
      false ->
        conn
        |> redirect(to: "/login")

      true ->
        conn
        |> render("settings.html",
          data: %{
            is_logged: conn.assigns[:is_logged],
            is_super: conn.assigns[:is_super],
            user_id: conn.assigns[:user_id],
            user_role: conn.assigns[:user_role],
            user_name: conn.assigns[:user_name],
            user_email: conn.assigns[:user_email],
            avatar_url: get_gavatar(conn.assigns[:user_email]),
            app_name: SettingsModule.get_config("app_name", ""),
            app_url: SettingsModule.get_config("app_url", "") |> add_backslash_to_url,
            app_email: SettingsModule.get_config("app_email", ""),
            auth_password_enabled: SettingsModule.get_sso_config("auth_password_enabled", "true"),
            auth_sso_enabled: SettingsModule.get_sso_config("auth_sso_enabled", "false"),
            sso_protocol: SettingsModule.get_sso_config("sso_protocol", "oidc"),
            sso_login_label: SettingsModule.get_sso_config("sso_login_label", "SSO"),
            sso_issuer: SettingsModule.get_sso_config("sso_issuer", ""),
            sso_client_id: SettingsModule.get_sso_config("sso_client_id", ""),
            sso_client_secret: SettingsModule.get_sso_config("sso_client_secret", ""),
            sso_saml_idp_sso_url: SettingsModule.get_sso_config("sso_saml_idp_sso_url", ""),
            sso_saml_idp_issuer: SettingsModule.get_sso_config("sso_saml_idp_issuer", ""),
            sso_saml_idp_cert: SettingsModule.get_sso_config("sso_saml_idp_cert", ""),
            sso_saml_idp_metadata_url: SettingsModule.get_sso_config("sso_saml_idp_metadata_url", ""),
            sso_saml_sp_entity_id: SettingsModule.get_sso_config("sso_saml_sp_entity_id", ""),
            sso_saml_sp_cert: SettingsModule.get_sso_config("sso_saml_sp_cert", ""),
            sso_saml_sign_requests: SettingsModule.get_sso_config("sso_saml_sign_requests", "false"),
            scim_enabled: SettingsModule.get_sso_config("scim_enabled", "false"),
            computed_app_base_url: SettingsModule.get_config("app_url", "http://localhost:4000") |> add_backslash_to_url
          }
        )
    end
  end

  @doc """
  Projects Page
  """
  def projects(conn, _params) do
    case conn.assigns[:is_logged] do
      false ->
        conn
        |> redirect(to: "/login")

      true ->
        conn
        |> render("projects.html",
          data: %{
            is_logged: conn.assigns[:is_logged],
            is_super: conn.assigns[:is_super],
            user_id: conn.assigns[:user_id],
            user_role: conn.assigns[:user_role],
            user_name: conn.assigns[:user_name],
            user_email: conn.assigns[:user_email],
            avatar_url: get_gavatar(conn.assigns[:user_email]),
            app_name: SettingsModule.get_config("app_name", ""),
            app_url: SettingsModule.get_config("app_url", "") |> add_backslash_to_url
          }
        )
    end
  end

  @doc """
  Snapshots Page
  """
  def snapshots(conn, _params) do
    case conn.assigns[:is_logged] do
      false ->
        conn
        |> redirect(to: "/login")

      true ->
        conn
        |> render("snapshots.html",
          data: %{
            is_logged: conn.assigns[:is_logged],
            is_super: conn.assigns[:is_super],
            user_id: conn.assigns[:user_id],
            user_role: conn.assigns[:user_role],
            user_name: conn.assigns[:user_name],
            user_email: conn.assigns[:user_email],
            avatar_url: get_gavatar(conn.assigns[:user_email]),
            app_name: SettingsModule.get_config("app_name", ""),
            app_url: SettingsModule.get_config("app_url", "") |> add_backslash_to_url
          }
        )
    end
  end

  @doc """
  Project Page
  """
  def project(conn, %{"uuid" => uuid}) do
    case conn.assigns[:is_logged] do
      false ->
        conn
        |> redirect(to: "/login")

      true ->
        if not PermissionModule.can_access_project_uuid(
             :project,
             conn.assigns[:user_role],
             uuid,
             conn.assigns[:user_id]
           ) do
          conn
          |> redirect(to: "/404")
        else
          conn
          |> render("project.html",
            data: %{
              is_logged: conn.assigns[:is_logged],
              is_super: conn.assigns[:is_super],
              user_id: conn.assigns[:user_id],
              user_role: conn.assigns[:user_role],
              user_name: conn.assigns[:user_name],
              user_email: conn.assigns[:user_email],
              avatar_url: get_gavatar(conn.assigns[:user_email]),
              app_name: SettingsModule.get_config("app_name", ""),
              app_url: add_backslash_to_url(SettingsModule.get_config("app_url", "")),
              uuid: uuid
            }
          )
        end
    end
  end

  @doc """
  State Download Page
  """
  def state(conn, %{"uuid" => uuid}) do
    case conn.assigns[:is_logged] do
      false ->
        conn
        |> redirect(to: "/login")

      true ->
        if not PermissionModule.can_access_snapshot_uuid(
             :snapshot,
             conn.assigns[:user_role],
             uuid,
             conn.assigns[:user_id]
           ) do
          conn
          |> redirect(to: "/404")
        else
          case StateModule.get_state_by_uuid(uuid) do
            nil ->
              conn
              |> redirect(to: "/404")

            state ->
              conn
              |> put_resp_content_type("application/octet-stream")
              |> put_resp_header(
                "content-disposition",
                "attachment; filename=\"state.#{uuid}.json\""
              )
              |> send_resp(200, state.value)
          end
        end
    end
  end

  @doc """
  Environment State Download Page
  """
  def environment(conn, %{"uuid" => uuid}) do
    case conn.assigns[:is_logged] do
      false ->
        conn
        |> redirect(to: "/login")

      true ->
        if not PermissionModule.can_access_environment_uuid(
             :environment,
             conn.assigns[:user_role],
             uuid,
             conn.assigns[:user_id]
           ) do
          conn
          |> redirect(to: "/404")
        else
          case StateModule.get_latest_state_by_env_uuid(uuid) do
            nil ->
              conn
              |> redirect(to: "/404")

            state ->
              conn
              |> put_resp_content_type("application/octet-stream")
              |> put_resp_header(
                "content-disposition",
                "attachment; filename=\"state.#{state.uuid}.json\""
              )
              |> send_resp(200, state.value)
          end
        end
    end
  end

  defp get_gavatar(nil) do
    ""
  end

  defp get_gavatar(email) do
    hash = Base.encode16(:crypto.hash(:sha256, email)) |> String.downcase()
    "https://gravatar.com/avatar/#{hash}?s=200"
  end

  defp add_backslash_to_url(nil) do
    ""
  end

  defp add_backslash_to_url(url) do
    if String.last(url) == "/" do
      String.slice(url, 0..-2//1)
    else
      url
    end
  end
end

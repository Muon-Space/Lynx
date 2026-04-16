# Copyright 2023 Clivern. All rights reserved.
# Use of this source code is governed by the MIT
# license that can be found in the LICENSE file.

defmodule LynxWeb.SSOController do
  @moduledoc """
  SSO Controller - handles OIDC and SAML authentication flows.

  OIDC: initiate -> redirect to IdP -> callback (code exchange) -> finalize session.
  SAML: initiate -> redirect to IdP -> POST callback (assertion validation) -> finalize session.

  Both use a two-step session handoff via a signed Lax cookie to work with
  SameSite=Strict session cookies.
  """

  use LynxWeb, :controller

  require Logger

  import Plug.Conn

  alias Lynx.Module.SSOModule
  alias Lynx.Service.SSOService
  alias Lynx.Service.SAMLService

  @doc """
  Initiate SSO login - redirects to the IdP
  """
  def initiate(conn, _params) do
    if not SSOModule.is_sso_enabled?() do
      conn
      |> put_status(:bad_request)
      |> json(%{errorMessage: "SSO is not enabled"})
    else
      case SSOModule.get_sso_protocol() do
        :oidc -> initiate_oidc(conn)
        :saml -> initiate_saml(conn)
      end
    end
  end

  @doc """
  Handle OIDC callback (GET)
  """
  def callback_get(conn, %{"code" => code, "state" => state} = _params) do
    stored_state = conn.cookies["_lynx_sso_state"]

    if stored_state == nil or state != stored_state do
      Logger.warning("OIDC callback: state mismatch")

      conn
      |> put_status(:bad_request)
      |> json(%{errorMessage: "Invalid state parameter"})
    else
      conn = delete_resp_cookie(conn, "_lynx_sso_state")

      case SSOService.oidc_callback(code) do
        {:ok, claims} ->
          complete_sso_login(conn, claims, "oidc")

        {:error, reason} ->
          Logger.error("OIDC callback failed: #{reason}")

          conn
          |> put_status(:unauthorized)
          |> json(%{errorMessage: reason})
      end
    end
  end

  def callback_get(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{errorMessage: "Missing code or state parameter"})
  end

  @doc """
  Handle SAML callback (POST binding).
  The IdP posts the SAMLResponse here after authentication.
  """
  def saml_callback(conn, %{"SAMLResponse" => saml_response} = _params) do
    case SAMLService.validate_response(saml_response) do
      {:ok, claims} ->
        complete_sso_login(conn, claims, "saml")

      {:error, reason} ->
        Logger.error("SAML callback failed: #{reason}")

        conn
        |> put_status(:unauthorized)
        |> json(%{errorMessage: "SAML authentication failed: #{reason}"})
    end
  end

  def saml_callback(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{errorMessage: "Missing SAMLResponse parameter"})
  end

  @doc """
  Finalize SSO login - reads the signed SSO cookie and creates the session.
  This runs in the :browser pipeline so SameSite=Strict session cookies work.
  """
  def finalize(conn, _params) do
    case conn.cookies["_lynx_sso_payload"] do
      nil ->
        conn
        |> redirect(to: "/login")

      signed_payload ->
        case Phoenix.Token.verify(LynxWeb.Endpoint, "sso_payload", signed_payload, max_age: 60) do
          {:ok, %{token: token, uid: uid}} ->
            conn
            |> put_session(:token, token)
            |> put_session(:uid, uid)
            |> delete_resp_cookie("_lynx_sso_payload")
            |> put_resp_content_type("text/html")
            |> send_resp(200, """
            <!DOCTYPE html>
            <html>
            <head><meta http-equiv="refresh" content="0;url=/admin/projects"></head>
            <body><p>Signing in...</p></body>
            </html>
            """)

          {:error, _} ->
            conn
            |> delete_resp_cookie("_lynx_sso_payload")
            |> redirect(to: "/login")
        end
    end
  end

  @doc """
  Serve SAML SP metadata XML (for IdP configuration).
  """
  def metadata(conn, _params) do
    if SSOModule.is_sso_enabled?() and SSOModule.get_sso_protocol() == :saml do
      conn
      |> put_status(:not_found)
      |> json(%{errorMessage: "SP metadata not yet implemented for runtime SAML"})
    else
      conn
      |> put_status(:not_found)
      |> json(%{errorMessage: "SAML is not enabled"})
    end
  end

  # -- Private --

  defp initiate_oidc(conn) do
    state = Lynx.Service.AuthService.get_random_salt(16)

    case SSOService.oidc_authorize_url(state) do
      {:ok, url} ->
        conn
        |> put_resp_cookie("_lynx_sso_state", state,
          http_only: true,
          max_age: 600,
          same_site: "Lax"
        )
        |> redirect(external: url)

      {:error, reason} ->
        Logger.error("Failed to build OIDC auth URL: #{reason}")

        conn
        |> put_status(:internal_server_error)
        |> json(%{errorMessage: reason})
    end
  end

  defp initiate_saml(conn) do
    case SAMLService.build_authn_request() do
      {:ok, redirect_url} ->
        conn
        |> redirect(external: redirect_url)

      {:error, reason} ->
        Logger.error("Failed to build SAML AuthnRequest: #{reason}")

        conn
        |> put_status(:internal_server_error)
        |> json(%{errorMessage: reason})
    end
  end

  defp complete_sso_login(conn, claims, auth_method) do
    case SSOModule.find_or_create_sso_user(claims, auth_method) do
      {:ok, user} ->
        case SSOModule.create_sso_session(user, auth_method) do
          {:success, session} ->
            payload =
              Phoenix.Token.sign(LynxWeb.Endpoint, "sso_payload", %{
                token: session.value,
                uid: session.user_id
              })

            conn
            |> put_resp_cookie("_lynx_sso_payload", payload,
              http_only: true,
              max_age: 60,
              same_site: "Lax"
            )
            |> redirect(to: "/auth/sso/finalize")

          {:error, reason} ->
            Logger.error("SSO session creation failed: #{reason}")

            conn
            |> put_status(:internal_server_error)
            |> json(%{errorMessage: "Failed to create session"})
        end

      {:error, reason} ->
        Logger.error("SSO user provisioning failed: #{reason}")

        conn
        |> put_status(:unauthorized)
        |> json(%{errorMessage: reason})
    end
  end
end

# Copyright 2023 Clivern. All rights reserved.
# Use of this source code is governed by the MIT
# license that can be found in the LICENSE file.

defmodule LynxWeb.SSOController do
  @moduledoc """
  SSO Controller - handles OIDC and SAML authentication flows.

  OIDC: Full flow handled here (initiate -> redirect -> callback).
  SAML: Samly handles the SAML protocol via its own router (forwarded at /sso).
        After Samly authenticates, it redirects to /auth/sso/saml_callback
        where we extract the assertion from the session and do JIT provisioning.
  """

  use LynxWeb, :controller

  require Logger

  import Plug.Conn

  alias Lynx.Module.SSOModule
  alias Lynx.Service.SSOService

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
      Logger.warning("OIDC callback: state mismatch (stored=#{inspect(stored_state)}, got=#{inspect(state)})")

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
  Handle SAML callback - called after Samly processes the SAML assertion.
  Samly stores the assertion in the session; we read it and do JIT provisioning.
  """
  def saml_callback(conn, _params) do
    conn = fetch_session(conn)
    assertion = Samly.get_active_assertion(conn)

    case assertion do
      nil ->
        Logger.warning("SAML callback: no active assertion in session")

        conn
        |> put_status(:unauthorized)
        |> json(%{errorMessage: "SAML authentication failed"})

      assertion ->
        case SSOService.saml_assertion_to_attrs(assertion) do
          {:ok, claims} ->
            complete_sso_login(conn, claims, "saml")

          {:error, reason} ->
            Logger.error("SAML attribute extraction failed: #{reason}")

            conn
            |> put_status(:unauthorized)
            |> json(%{errorMessage: reason})
        end
    end
  end

  @doc """
  Serve SAML SP metadata (for IdP configuration).
  Delegates to Samly's metadata endpoint.
  """
  def metadata(conn, _params) do
    if SSOModule.is_sso_enabled?() and SSOModule.get_sso_protocol() == :saml do
      # Samly serves metadata at /sso/sp/metadata/:idp_id
      conn
      |> redirect(to: "/sso/sp/metadata/default")
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
        |> json(%{errorMessage: "Failed to initiate SSO"})
    end
  end

  defp initiate_saml(conn) do
    # Samly's signin route with target_url set to our callback
    redirect(conn,
      to: "/sso/auth/signin/default?target_url=#{URI.encode_www_form("/auth/sso/saml_callback")}"
    )
  end

  @doc """
  Finalize SSO login - reads the signed SSO cookie (set during the cross-site
  callback) and creates the actual session. This is a same-site request so the
  SameSite=Strict session cookie will be accepted by the browser.
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

  defp complete_sso_login(conn, claims, auth_method) do
    case SSOModule.find_or_create_sso_user(claims, auth_method) do
      {:ok, user} ->
        case SSOModule.create_sso_session(user, auth_method) do
          {:success, session} ->
            # Store session data in a signed, short-lived Lax cookie.
            # The browser won't accept the SameSite=Strict session cookie
            # on a cross-site redirect from the IdP, so we bounce through
            # a same-site /auth/sso/finalize endpoint that reads this cookie
            # and sets the real session.
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

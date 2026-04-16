# Copyright 2023 Clivern. All rights reserved.
# Use of this source code is governed by the MIT
# license that can be found in the LICENSE file.

defmodule LynxWeb.SettingsController do
  @moduledoc """
  Settings Controller
  """

  use LynxWeb, :controller

  require Logger

  @app_name_min_length 2
  @app_name_max_length 60

  alias Lynx.Module.SettingsModule
  alias Lynx.Module.SCIMTokenModule
  alias Lynx.Service.ValidatorService

  plug :super_user
       when action in [
              :update,
              :update_sso,
              :generate_saml_cert,
              :generate_scim_token,
              :revoke_scim_token,
              :list_scim_tokens
            ]

  defp super_user(conn, _opts) do
    Logger.info("Validate user permissions")

    if not conn.assigns[:is_super] do
      Logger.info("User doesn't have the right access permissions")

      conn
      |> put_status(:forbidden)
      |> render("error.json", %{message: "Forbidden Access"})
      |> halt
    else
      Logger.info("User has the right access permissions")

      conn
    end
  end

  @doc """
  Update Action Endpoint
  """
  def update(conn, params) do
    case validate_update_request(params) do
      {:ok, _} ->
        SettingsModule.update_configs(%{
          app_name: params["app_name"],
          app_url: params["app_url"],
          app_email: params["app_email"]
        })

        conn
        |> put_status(:ok)
        |> render("success.json", %{message: "Settings updated successfully"})

      {:error, reason} ->
        conn
        |> put_status(:bad_request)
        |> render("error.json", %{message: reason})
    end
  end

  @doc """
  Update SSO/SCIM Settings Endpoint
  """
  def update_sso(conn, params) do
    # Only update keys that are actually present in the request,
    # so toggling one setting doesn't reset others to defaults
    configs =
      params
      |> Map.take([
        "auth_password_enabled",
        "auth_sso_enabled",
        "sso_protocol",
        "sso_login_label",
        "sso_issuer",
        "sso_client_id",
        "sso_client_secret",
        "sso_saml_idp_sso_url",
        "sso_saml_idp_issuer",
        "sso_saml_idp_cert",
        "sso_saml_idp_metadata_url",
        "sso_saml_sp_entity_id",
        "sso_saml_sp_cert",
        "sso_saml_sp_key",
        "sso_saml_sign_requests",
        "scim_enabled"
      ])

    SettingsModule.update_sso_configs(configs)

    # Write SAML cert/key to temp files if provided
    write_saml_temp_files(params["sso_saml_sp_cert"], params["sso_saml_sp_key"])

    conn
    |> put_status(:ok)
    |> render("success.json", %{message: "SSO/SCIM settings updated successfully"})
  end

  defp write_saml_temp_files(cert, key) do
    if cert != nil and cert != "" do
      path = Path.join(System.tmp_dir!(), "lynx_saml_sp_cert.pem")
      File.write!(path, cert)
    end

    if key != nil and key != "" do
      path = Path.join(System.tmp_dir!(), "lynx_saml_sp_key.pem")
      File.write!(path, key)
    end
  end

  @doc """
  Generate SAML SP Certificate Endpoint
  """
  def generate_saml_cert(conn, _params) do
    case Lynx.Service.SAMLService.generate_sp_certificate() do
      {:ok, %{cert_pem: cert_pem, key_pem: key_pem}} ->
        SettingsModule.upsert_config("sso_saml_sp_cert", cert_pem)
        SettingsModule.upsert_config("sso_saml_sp_key", key_pem)
        SettingsModule.upsert_config("sso_saml_sign_requests", "true")

        conn
        |> put_status(:ok)
        |> json(%{
          successMessage: "SP certificate generated successfully",
          cert_pem: cert_pem
        })

      {:error, msg} ->
        conn
        |> put_status(:internal_server_error)
        |> render("error.json", %{message: msg})
    end
  end

  @doc """
  Generate SCIM Token Endpoint
  """
  def generate_scim_token(conn, params) do
    description = params["description"] || ""

    case SCIMTokenModule.generate_token(description) do
      {:ok, result} ->
        conn
        |> put_status(:created)
        |> json(%{
          uuid: result.uuid,
          token: result.token,
          description: result.description
        })

      {:error, msg} ->
        conn
        |> put_status(:bad_request)
        |> render("error.json", %{message: msg})
    end
  end

  @doc """
  List SCIM Tokens Endpoint
  """
  def list_scim_tokens(conn, _params) do
    tokens = SCIMTokenModule.list_tokens()

    conn
    |> put_status(:ok)
    |> json(%{tokens: tokens})
  end

  @doc """
  Revoke SCIM Token Endpoint
  """
  def revoke_scim_token(conn, %{"uuid" => uuid}) do
    case SCIMTokenModule.revoke_token(uuid) do
      {:ok, _} ->
        conn
        |> put_status(:ok)
        |> render("success.json", %{message: "Token revoked"})

      {:not_found, _} ->
        conn
        |> put_status(:not_found)
        |> render("error.json", %{message: "Token not found"})
    end
  end

  defp validate_update_request(params) do
    errs = %{
      app_name_required: "Application name is required",
      app_name_invalid: "Application name is invalid",
      app_url_required: "Application URL is required",
      app_url_invalid: "Application URL is invalid",
      app_email_required: "Application email is required",
      app_email_invalid: "Application email is invalid"
    }

    with {:ok, _} <- ValidatorService.is_string?(params["app_name"], errs.app_name_required),
         {:ok, _} <- ValidatorService.is_string?(params["app_url"], errs.app_url_required),
         {:ok, _} <- ValidatorService.is_string?(params["app_email"], errs.app_email_required),
         {:ok, _} <-
           ValidatorService.is_length_between?(
             params["app_name"],
             @app_name_min_length,
             @app_name_max_length,
             errs.app_name_invalid
           ),
         {:ok, _} <- ValidatorService.is_url?(params["app_url"], errs.app_url_invalid),
         {:ok, _} <-
           ValidatorService.is_email?(params["app_email"], errs.app_email_invalid) do
      {:ok, ""}
    else
      {:error, reason} -> {:error, reason}
    end
  end
end

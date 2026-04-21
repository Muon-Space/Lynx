# Copyright 2023 Clivern. All rights reserved.
# Use of this source code is governed by the MIT
# license that can be found in the LICENSE file.

import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/lynx start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :lynx, LynxWeb.Endpoint, server: true
end

# Auth configuration
config :lynx,
  auth_password_enabled: (System.get_env("AUTH_PASSWORD_ENABLED") || "true") == "true",
  auth_sso_enabled: (System.get_env("AUTH_SSO_ENABLED") || "false") == "true",
  sso_protocol: System.get_env("SSO_PROTOCOL") || "oidc",
  sso_login_label: System.get_env("SSO_LOGIN_LABEL") || "SSO",
  sso_issuer: System.get_env("SSO_ISSUER") || "",
  sso_client_id: System.get_env("SSO_CLIENT_ID") || "",
  sso_client_secret: System.get_env("SSO_CLIENT_SECRET") || "",
  sso_saml_idp_sso_url: System.get_env("SSO_SAML_IDP_SSO_URL") || "",
  sso_saml_idp_issuer: System.get_env("SSO_SAML_IDP_ISSUER") || "",
  sso_saml_idp_cert: System.get_env("SSO_SAML_IDP_CERT") || "",
  sso_saml_idp_metadata_url: System.get_env("SSO_SAML_IDP_METADATA_URL") || "",
  sso_saml_sp_entity_id: System.get_env("SSO_SAML_SP_ENTITY_ID") || "",
  sso_jit_enabled: (System.get_env("SSO_JIT_ENABLED") || "true") == "true",
  sso_saml_sign_requests: (System.get_env("SSO_SAML_SIGN_REQUESTS") || "false") == "true",
  scim_enabled: (System.get_env("SCIM_ENABLED") || "false") == "true"

# OIDC configuration is read from the DB (Settings tab) so it can be changed
# at runtime without an app restart — see `Lynx.Service.SSOService`.

# SAML configuration
if (System.get_env("AUTH_SSO_ENABLED") || "false") == "true" and
     (System.get_env("SSO_PROTOCOL") || "oidc") == "saml" do
  # Resolve SP cert/key: base64 env vars take precedence over file paths.
  # When base64 values are provided, decode them and write to temp files
  # so they work in containerized deploys without volume mounts.
  saml_certfile =
    case System.get_env("SSO_SAML_SP_CERT_BASE64") do
      nil ->
        System.get_env("SSO_SAML_SP_CERTFILE") || ""

      "" ->
        System.get_env("SSO_SAML_SP_CERTFILE") || ""

      base64_cert ->
        path = Path.join(System.tmp_dir!(), "lynx_saml_sp_cert.pem")
        File.write!(path, Base.decode64!(base64_cert))
        path
    end

  saml_keyfile =
    case System.get_env("SSO_SAML_SP_KEY_BASE64") do
      nil ->
        System.get_env("SSO_SAML_SP_KEYFILE") || ""

      "" ->
        System.get_env("SSO_SAML_SP_KEYFILE") || ""

      base64_key ->
        path = Path.join(System.tmp_dir!(), "lynx_saml_sp_key.pem")
        File.write!(path, Base.decode64!(base64_key))
        path
    end

  config :samly, Samly.Provider,
    idp_id_from: :path_segment,
    service_providers: [
      %{
        id: "lynx-sp",
        entity_id: System.get_env("SSO_SAML_SP_ENTITY_ID"),
        certfile: saml_certfile,
        keyfile: saml_keyfile
      }
    ],
    identity_providers: [
      %{
        id: "default",
        sp_id: "lynx-sp",
        base_url: System.get_env("APP_HOST") || "localhost",
        metadata_url: System.get_env("SSO_SAML_IDP_METADATA_URL")
      }
    ]
end

if config_env() == :prod do
  maybe_ipv6 = if System.get_env("ECTO_IPV6"), do: [:inet6], else: []

  if (System.get_env("DB_SSL") || "off") == "on" do
    config :lynx, Lynx.Repo,
      username: System.get_env("DB_USERNAME"),
      password: System.get_env("DB_PASSWORD"),
      hostname: System.get_env("DB_HOSTNAME"),
      database: System.get_env("DB_DATABASE"),
      port: String.to_integer(System.get_env("DB_PORT")),
      maintenance_database: System.get_env("DB_DATABASE"),
      pool_size: String.to_integer(System.get_env("DB_POOL_SIZE") || "10"),
      socket_options: maybe_ipv6,
      ssl: [
        verify: :verify_peer,
        cacertfile: System.get_env("DB_CA_CERTFILE_PATH") || ""
      ]
  else
    config :lynx, Lynx.Repo,
      username: System.get_env("DB_USERNAME"),
      password: System.get_env("DB_PASSWORD"),
      hostname: System.get_env("DB_HOSTNAME"),
      database: System.get_env("DB_DATABASE"),
      port: String.to_integer(System.get_env("DB_PORT")),
      maintenance_database: System.get_env("DB_DATABASE"),
      pool_size: String.to_integer(System.get_env("DB_POOL_SIZE") || "10"),
      socket_options: maybe_ipv6
  end

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("APP_SECRET") ||
      raise """
      environment variable APP_SECRET is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("APP_HOST") || "example.com"
  port = String.to_integer(System.get_env("APP_PORT") || "4000")

  config :lynx, LynxWeb.Endpoint,
    url: [host: host, port: port, scheme: System.get_env("APP_HTTP_SCHEMA") || "http"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/plug_cowboy/Plug.Cowboy.html
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: port
    ],
    secret_key_base: secret_key_base

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Also, you may need to configure the Swoosh API client of your choice if you
  # are not using SMTP. Here is an example of the configuration:
  #
  #     config :lynx, Lynx.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # For this example you need include a HTTP client required by Swoosh API client.
  # Swoosh supports Hackney and Finch out of the box:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Hackney
  #
  # See https://hexdocs.pm/swoosh/Swoosh.html#module-installation for details.
end

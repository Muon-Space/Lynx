# Copyright 2023 Clivern. All rights reserved.
# Use of this source code is governed by the MIT
# license that can be found in the LICENSE file.

defmodule Lynx.Service.SAMLService do
  @moduledoc """
  Direct SAML 2.0 Service Provider implementation using esaml.
  Reads configuration from the database at runtime -- no boot-time config needed.
  """

  require Logger
  require Record

  import SweetXml, only: [parse: 2, xpath: 2, sigil_x: 2]

  alias Lynx.Module.SettingsModule

  # Import esaml record definitions
  Record.defrecord(:esaml_org, Record.extract(:esaml_org, from_lib: "esaml/include/esaml.hrl"))

  Record.defrecord(
    :esaml_contact,
    Record.extract(:esaml_contact, from_lib: "esaml/include/esaml.hrl")
  )

  Record.defrecord(:esaml_sp, Record.extract(:esaml_sp, from_lib: "esaml/include/esaml.hrl"))

  Record.defrecord(
    :esaml_idp_metadata,
    Record.extract(:esaml_idp_metadata, from_lib: "esaml/include/esaml.hrl")
  )

  Record.defrecord(
    :esaml_assertion,
    Record.extract(:esaml_assertion, from_lib: "esaml/include/esaml.hrl")
  )

  Record.defrecord(
    :esaml_subject,
    Record.extract(:esaml_subject, from_lib: "esaml/include/esaml.hrl")
  )

  @doc """
  Build SAML AuthnRequest and return the IdP SSO URL to redirect to.
  Uses HTTP-Redirect binding with deflated/base64-encoded request.
  """
  def build_authn_request do
    with {:ok, idp_meta, fingerprints} <- load_idp_metadata(),
         {:ok, sp} <- build_sp_record(fingerprints) do
      login_url = esaml_idp_metadata(idp_meta, :login_location) |> to_string()
      nameid_format = esaml_idp_metadata(idp_meta, :name_format)

      Logger.info("SAML SP Entity ID: #{esaml_sp(sp, :entity_id)}")
      Logger.info("SAML SP Consume URI: #{esaml_sp(sp, :consume_uri)}")
      Logger.info("SAML SP Sign Requests: #{esaml_sp(sp, :sp_sign_requests)}")
      Logger.info("SAML IdP Login URL: #{login_url}")

      xml = :esaml_sp.generate_authn_request(String.to_charlist(login_url), sp, nameid_format)
      xml_bytes = :xmerl.export_simple([xml], :xmerl_xml) |> List.flatten()

      Logger.info("SAML AuthnRequest XML: #{xml_bytes}")

      # DEFLATE + Base64 encode for HTTP-Redirect binding
      z = :zlib.open()
      :zlib.deflateInit(z, :default, :deflated, -15, 8, :default)
      deflated = :zlib.deflate(z, xml_bytes, :finish) |> IO.iodata_to_binary()
      :zlib.deflateEnd(z)
      :zlib.close(z)

      encoded = Base.encode64(deflated)
      redirect_url = "#{login_url}?SAMLRequest=#{URI.encode_www_form(encoded)}"

      {:ok, redirect_url}
    end
  end

  @doc """
  Validate a SAML Response (POST binding) and extract user attributes.
  """
  def validate_response(saml_response_b64) do
    with {:ok, _idp_meta, fingerprints} <- load_idp_metadata(),
         {:ok, sp} <- build_sp_record(fingerprints),
         {:ok, xml} <- decode_response_xml(saml_response_b64),
         {:ok, assertion} <- do_validate_assertion(xml, sp) do
      {:ok, extract_claims(assertion)}
    end
  end

  @doc """
  Generate SAML SP metadata XML.
  """
  def generate_sp_metadata do
    app_url =
      SettingsModule.get_config("app_url", "http://localhost:4000")
      |> String.trim_trailing("/")

    consume_uri = app_url <> "/auth/sso/saml_callback"
    metadata_uri = app_url <> "/saml/metadata"
    configured_entity_id = SettingsModule.get_sso_config("sso_saml_sp_entity_id", "")
    sp_entity_id = if configured_entity_id == "", do: metadata_uri, else: configured_entity_id
    app_name = SettingsModule.get_config("app_name", "Lynx")
    app_email = SettingsModule.get_config("app_email", "admin@localhost")

    cert_pem = SettingsModule.get_sso_config("sso_saml_sp_cert", "")
    sign_requests = SettingsModule.get_sso_config("sso_saml_sign_requests", "false") == "true"

    cert_b64 =
      if cert_pem != "" do
        cert_pem
        |> String.replace("-----BEGIN CERTIFICATE-----", "")
        |> String.replace("-----END CERTIFICATE-----", "")
        |> String.replace("\n", "")
        |> String.trim()
      else
        ""
      end

    key_descriptor =
      if sign_requests and cert_b64 != "" do
        """
            <md:KeyDescriptor use="signing">
              <ds:KeyInfo xmlns:ds="http://www.w3.org/2000/09/xmldsig#">
                <ds:X509Data>
                  <ds:X509Certificate>#{cert_b64}</ds:X509Certificate>
                </ds:X509Data>
              </ds:KeyInfo>
            </md:KeyDescriptor>
        """
      else
        ""
      end

    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <md:EntityDescriptor xmlns:md="urn:oasis:names:tc:SAML:2.0:metadata"
                         entityID="#{sp_entity_id}">
      <md:SPSSODescriptor AuthnRequestsSigned="#{sign_requests}"
                          WantAssertionsSigned="true"
                          protocolSupportEnumeration="urn:oasis:names:tc:SAML:2.0:protocol">
    #{key_descriptor}    <md:NameIDFormat>urn:oasis:names:tc:SAML:1.1:nameid-format:emailAddress</md:NameIDFormat>
        <md:AssertionConsumerService Binding="urn:oasis:names:tc:SAML:2.0:bindings:HTTP-POST"
                                    Location="#{consume_uri}"
                                    index="0"
                                    isDefault="true"/>
      </md:SPSSODescriptor>
      <md:Organization>
        <md:OrganizationName xml:lang="en">#{app_name}</md:OrganizationName>
        <md:OrganizationDisplayName xml:lang="en">#{app_name}</md:OrganizationDisplayName>
        <md:OrganizationURL xml:lang="en">#{app_url}</md:OrganizationURL>
      </md:Organization>
      <md:ContactPerson contactType="technical">
        <md:EmailAddress>#{app_email}</md:EmailAddress>
      </md:ContactPerson>
    </md:EntityDescriptor>
    """

    {:ok, String.trim(xml)}
  end

  @doc """
  Generate a self-signed SP certificate and private key via openssl.
  """
  def generate_sp_certificate do
    tmp_dir = System.tmp_dir!()
    key_path = Path.join(tmp_dir, "lynx_sp_gen_key_#{System.unique_integer([:positive])}.pem")
    cert_path = Path.join(tmp_dir, "lynx_sp_gen_cert_#{System.unique_integer([:positive])}.pem")

    result =
      System.cmd("openssl", [
        "req",
        "-x509",
        "-newkey",
        "rsa:2048",
        "-keyout",
        key_path,
        "-out",
        cert_path,
        "-days",
        "3650",
        "-nodes",
        "-subj",
        "/CN=Lynx SAML SP",
        "-outform",
        "PEM"
      ])

    # Convert PKCS8 key to traditional RSA format
    if elem(result, 1) == 0 do
      System.cmd("openssl", ["rsa", "-in", key_path, "-out", key_path, "-traditional"],
        stderr_to_stdout: true
      )
    end

    case result do
      {_, 0} ->
        cert_pem = File.read!(cert_path)
        key_pem = File.read!(key_path)
        File.rm(key_path)
        File.rm(cert_path)
        {:ok, %{cert_pem: cert_pem, key_pem: key_pem}}

      {output, code} ->
        {:error, "Certificate generation failed (exit #{code}): #{output}"}
    end
  end

  # -- Private --

  defp load_idp_metadata do
    idp_sso_url = SettingsModule.get_sso_config("sso_saml_idp_sso_url", "")
    idp_cert_pem = SettingsModule.get_sso_config("sso_saml_idp_cert", "")
    metadata_url = SettingsModule.get_sso_config("sso_saml_idp_metadata_url", "")

    # If metadata URL is available, fetch it for NameID format and other details
    metadata_extras = fetch_metadata_extras(metadata_url)

    cond do
      idp_sso_url != "" and idp_cert_pem != "" ->
        build_idp_from_direct_config(idp_sso_url, idp_cert_pem, metadata_extras)

      metadata_url != "" ->
        case fetch_metadata_xml(metadata_url) do
          {:ok, xml_string} -> parse_idp_metadata(xml_string)
          {:error, reason} -> {:error, reason}
        end

      true ->
        {:error, "IdP SSO URL and Certificate, or IdP Metadata URL must be configured"}
    end
  end

  defp fetch_metadata_extras(""), do: %{}
  defp fetch_metadata_extras(nil), do: %{}

  defp fetch_metadata_extras(metadata_url) do
    case fetch_metadata_xml(metadata_url) do
      {:ok, xml_string} ->
        xml_opts = [
          space: :normalize,
          namespace_conformant: true,
          comments: false,
          default_attrs: true
        ]

        md_xml = parse(xml_string, xml_opts)

        nameid_format =
          case safe_xpath(md_xml, ~x"//md:IDPSSODescriptor/md:NameIDFormat[1]/text()"s) do
            nil -> nil
            "" -> nil
            fmt -> String.to_charlist(fmt)
          end

        entity_id = safe_xpath(md_xml, ~x"/*/@entityID"s)

        %{nameid_format: nameid_format, entity_id: entity_id}

      {:error, _} ->
        %{}
    end
  end

  defp build_idp_from_direct_config(sso_url, cert_pem, metadata_extras) do
    idp_issuer = SettingsModule.get_sso_config("sso_saml_idp_issuer", "")
    idp_issuer = if idp_issuer == "", do: metadata_extras[:entity_id] || sso_url, else: idp_issuer

    nameid_format =
      metadata_extras[:nameid_format] ||
        ~c"urn:oasis:names:tc:SAML:1.1:nameid-format:unspecified"

    cert_b64 =
      cert_pem
      |> String.replace("-----BEGIN CERTIFICATE-----", "")
      |> String.replace("-----END CERTIFICATE-----", "")
      |> String.replace(~r/\s/, "")

    fingerprints =
      case Base.decode64(cert_b64) do
        {:ok, der} -> [{:sha256, :crypto.hash(:sha256, der)}]
        :error -> []
      end

    idp_meta =
      esaml_idp_metadata(
        entity_id: String.to_charlist(idp_issuer),
        login_location: String.to_charlist(sso_url),
        logout_location: :undefined,
        name_format: nameid_format
      )

    {:ok, idp_meta, fingerprints}
  end

  defp fetch_metadata_xml(url) do
    case Finch.build(:get, url) |> Finch.request(Lynx.Finch) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: status}} -> {:error, "IdP metadata fetch failed (HTTP #{status})"}
      {:error, reason} -> {:error, "IdP metadata fetch failed: #{inspect(reason)}"}
    end
  end

  defp parse_idp_metadata(xml_string) do
    xml_opts = [
      space: :normalize,
      namespace_conformant: true,
      comments: false,
      default_attrs: true
    ]

    md_xml = parse(xml_string, xml_opts)

    sso_redirect_url =
      safe_xpath(
        md_xml,
        ~x"//md:IDPSSODescriptor/md:SingleSignOnService[@Binding='urn:oasis:names:tc:SAML:2.0:bindings:HTTP-Redirect']/@Location"s
      )

    sso_post_url =
      safe_xpath(
        md_xml,
        ~x"//md:IDPSSODescriptor/md:SingleSignOnService[@Binding='urn:oasis:names:tc:SAML:2.0:bindings:HTTP-POST']/@Location"s
      )

    login_url = non_empty(sso_redirect_url) || non_empty(sso_post_url)

    if login_url == nil do
      {:error, "No SSO URL found in IdP metadata"}
    else
      entity_id = safe_xpath(md_xml, ~x"/*/@entityID"s) || ""
      certs = extract_signing_certs(md_xml)

      fingerprints =
        certs
        |> Enum.map(fn cert_b64 ->
          der = Base.decode64!(cert_b64)
          {:sha256, :crypto.hash(:sha256, der)}
        end)

      idp_meta =
        esaml_idp_metadata(
          entity_id: String.to_charlist(entity_id),
          login_location: String.to_charlist(login_url),
          logout_location: :undefined,
          name_format: :unknown
        )

      {:ok, idp_meta, fingerprints}
    end
  end

  defp extract_signing_certs(md_xml) do
    # Try signing-specific keys first, fall back to any keys
    certs =
      safe_xpath(
        md_xml,
        ~x"//md:IDPSSODescriptor/md:KeyDescriptor[@use='signing']/ds:KeyInfo/ds:X509Data/ds:X509Certificate/text()"sl
      )

    certs =
      if certs == nil or certs == [] do
        safe_xpath(
          md_xml,
          ~x"//md:IDPSSODescriptor/md:KeyDescriptor/ds:KeyInfo/ds:X509Data/ds:X509Certificate/text()"sl
        ) || []
      else
        certs
      end

    Enum.map(certs, &String.replace(to_string(&1), ~r/\s/, ""))
  end

  defp build_sp_record(fingerprints) do
    app_url =
      SettingsModule.get_config("app_url", "http://localhost:4000")
      |> String.trim_trailing("/")

    consume_uri = app_url <> "/auth/sso/saml_callback"
    metadata_uri = app_url <> "/saml/metadata"
    configured_entity_id = SettingsModule.get_sso_config("sso_saml_sp_entity_id", "")
    sp_entity_id = if configured_entity_id == "", do: metadata_uri, else: configured_entity_id
    metadata_uri = app_url <> "/auth/sso/metadata"

    {key, cert} = load_sp_credentials()
    sign_requests = SettingsModule.get_sso_config("sso_saml_sign_requests", "false") == "true"

    sp =
      esaml_sp(
        org: esaml_org(name: ~c"Lynx", displayname: ~c"Lynx", url: String.to_charlist(app_url)),
        tech: esaml_contact(name: ~c"Admin", email: ~c"admin@localhost"),
        key: key,
        certificate: cert,
        sp_sign_requests: sign_requests and key != :undefined,
        sp_sign_metadata: false,
        idp_signs_envelopes: true,
        idp_signs_assertions: false,
        trusted_fingerprints: fingerprints,
        metadata_uri: String.to_charlist(metadata_uri),
        consume_uri: String.to_charlist(consume_uri),
        logout_uri: :undefined,
        entity_id: String.to_charlist(sp_entity_id)
      )

    # Call setup with empty fingerprints (to avoid convert_fingerprints issues),
    # then set the real fingerprints as {sha256, hash} tuples afterward.
    sp_for_setup = esaml_sp(sp, trusted_fingerprints: [])
    sp_setup = :esaml_sp.setup(sp_for_setup)
    {:ok, esaml_sp(sp_setup, trusted_fingerprints: fingerprints)}
  rescue
    e -> {:error, "SP setup failed: #{inspect(e)}"}
  end

  defp load_sp_credentials do
    cert_pem = SettingsModule.get_sso_config("sso_saml_sp_cert", "")
    key_pem = SettingsModule.get_sso_config("sso_saml_sp_key", "")

    if cert_pem == "" or key_pem == "" do
      {:undefined, :undefined}
    else
      try do
        [key_entry] = :public_key.pem_decode(key_pem)

        key = :public_key.pem_entry_decode(key_entry)

        [{:Certificate, cert_der, :not_encrypted}] = :public_key.pem_decode(cert_pem)

        {key, cert_der}
      rescue
        e ->
          Logger.error("Failed to load SP credentials: #{inspect(e)}")
          {:undefined, :undefined}
      end
    end
  end

  defp decode_response_xml(saml_response_b64) do
    case Base.decode64(saml_response_b64) do
      {:ok, xml_string} ->
        # Use xmerl_scan directly WITHOUT space normalization to preserve
        # the exact XML content needed for signature digest verification.
        # namespace_conformant is required for proper namespace resolution.
        {xml, _} =
          :xmerl_scan.string(String.to_charlist(xml_string), [
            {:namespace_conformant, true}
          ])

        {:ok, xml}

      :error ->
        {:error, "Failed to decode SAML Response"}
    end
  end

  defp do_validate_assertion(xml, sp) do
    case :esaml_sp.validate_assertion(xml, &check_dupe/2, sp) do
      {:ok, assertion} -> {:ok, assertion}
      {:error, reason} -> {:error, "SAML assertion validation failed: #{inspect(reason)}"}
    end
  end

  defp check_dupe(_assertion, _digest), do: :ok

  defp extract_claims(assertion) do
    subject = esaml_assertion(assertion, :subject)
    name_id = esaml_subject(subject, :name) |> to_string()

    attrs =
      esaml_assertion(assertion, :attributes)
      |> Enum.map(fn {k, v} ->
        {to_string(k), list_to_string(v)}
      end)
      |> Map.new()

    email = Map.get(attrs, "email") || Map.get(attrs, "mail") || name_id

    name =
      Map.get(attrs, "displayName") ||
        Map.get(attrs, "name") ||
        build_name(attrs) ||
        email

    %{external_id: name_id, email: email, name: name}
  end

  defp build_name(attrs) do
    given = Map.get(attrs, "givenName") || Map.get(attrs, "firstName")
    family = Map.get(attrs, "surname") || Map.get(attrs, "lastName")

    case {given, family} do
      {nil, nil} -> nil
      {g, nil} -> g
      {nil, f} -> f
      {g, f} -> "#{g} #{f}"
    end
  end

  defp list_to_string(v) when is_list(v), do: to_string(v)
  defp list_to_string(v), do: to_string(v)

  defp safe_xpath(xml, xpath_expr) do
    try do
      xpath(xml, xpath_expr)
    rescue
      _ -> nil
    end
  end

  defp non_empty(""), do: nil
  defp non_empty(nil), do: nil
  defp non_empty(s), do: s
end

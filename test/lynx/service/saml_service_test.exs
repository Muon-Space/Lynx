defmodule Lynx.Service.SAMLServiceTest do
  use Lynx.DataCase

  alias Lynx.Context.ConfigContext
  alias Lynx.Service.Settings
  alias Lynx.Service.SAMLService

  defp set_config(name, value) do
    {:ok, _} =
      ConfigContext.create_config(ConfigContext.new_config(%{name: name, value: value}))

    :ok
  end

  defp set_app_basics do
    set_config("app_url", "http://localhost:4000")
    set_config("app_name", "Lynx Test")
    set_config("app_email", "ops@lynx.test")
  end

  describe "generate_sp_metadata/0" do
    test "uses metadata URL as default entity ID when none configured" do
      set_app_basics()
      {:ok, xml} = SAMLService.generate_sp_metadata()

      assert xml =~ "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
      assert xml =~ ~s(entityID="http://localhost:4000/saml/metadata")
      assert xml =~ "AuthnRequestsSigned=\"false\""
      assert xml =~ "WantAssertionsSigned=\"true\""
      assert xml =~ "Lynx Test"
      assert xml =~ "ops@lynx.test"
      assert xml =~ "/auth/sso/saml_callback"
    end

    test "uses configured SP entity ID when set" do
      set_app_basics()
      set_config("sso_saml_sp_entity_id", "urn:my-custom-sp")

      {:ok, xml} = SAMLService.generate_sp_metadata()
      assert xml =~ ~s(entityID="urn:my-custom-sp")
      refute xml =~ ~s(entityID="http://localhost:4000/saml/metadata")
    end

    test "embeds the SP cert and AuthnRequestsSigned=true when sign_requests enabled" do
      set_app_basics()

      pem = """
      -----BEGIN CERTIFICATE-----
      MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA
      -----END CERTIFICATE-----
      """

      set_config("sso_saml_sp_cert", pem)
      set_config("sso_saml_sign_requests", "true")

      {:ok, xml} = SAMLService.generate_sp_metadata()

      assert xml =~ "AuthnRequestsSigned=\"true\""
      assert xml =~ "<md:KeyDescriptor use=\"signing\">"
      # Base64 chunk of the cert (header/footer/newlines stripped)
      assert xml =~ "MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA"
    end

    test "omits KeyDescriptor when sign_requests is false even with cert configured" do
      set_app_basics()

      set_config(
        "sso_saml_sp_cert",
        "-----BEGIN CERTIFICATE-----\nABC\n-----END CERTIFICATE-----"
      )

      set_config("sso_saml_sign_requests", "false")

      {:ok, xml} = SAMLService.generate_sp_metadata()
      refute xml =~ "<md:KeyDescriptor"
      assert xml =~ "AuthnRequestsSigned=\"false\""
    end

    test "trims trailing slash from app_url" do
      set_config("app_url", "http://localhost:4000/")
      set_config("app_name", "Lynx")
      set_config("app_email", "x@y")

      {:ok, xml} = SAMLService.generate_sp_metadata()
      refute xml =~ "http://localhost:4000//"
      assert xml =~ "http://localhost:4000/saml/metadata"
    end
  end

  describe "build_authn_request/0 (error paths)" do
    test "returns {:error, _} when no IdP config is set" do
      set_app_basics()

      assert {:error, msg} = SAMLService.build_authn_request()
      assert msg =~ "IdP"
    end

    test "returns {:error, _} when only metadata URL set and fetch fails" do
      set_app_basics()
      set_config("sso_saml_idp_metadata_url", "http://nonexistent.lynx.test/metadata")

      assert {:error, msg} = SAMLService.build_authn_request()
      assert msg =~ "metadata fetch failed"
    end
  end

  describe "build_authn_request/0 with direct IdP config" do
    test "returns a valid HTTP-Redirect URL when IdP SSO URL + cert are configured" do
      set_app_basics()
      set_config("sso_saml_idp_sso_url", "https://idp.example.com/sso")
      # The cert needs to be valid base64 inside the PEM markers
      cert_b64 = Base.encode64("fake-cert-bytes")

      set_config(
        "sso_saml_idp_cert",
        "-----BEGIN CERTIFICATE-----\n#{cert_b64}\n-----END CERTIFICATE-----"
      )

      assert {:ok, redirect_url} = SAMLService.build_authn_request()
      assert redirect_url =~ "https://idp.example.com/sso?SAMLRequest="
      # The deflated AuthnRequest is URL-encoded base64
      assert redirect_url =~ "%"
    end
  end

  describe "validate_response/1 (error paths)" do
    test "returns {:error, _} when IdP config is missing" do
      set_app_basics()

      assert {:error, msg} = SAMLService.validate_response("anything")
      assert msg =~ "IdP"
    end

    test "returns {:error, _} for invalid base64 SAMLResponse" do
      set_app_basics()
      set_config("sso_saml_idp_sso_url", "https://idp.example.com/sso")
      cert_b64 = Base.encode64("fake-cert-bytes")

      set_config(
        "sso_saml_idp_cert",
        "-----BEGIN CERTIFICATE-----\n#{cert_b64}\n-----END CERTIFICATE-----"
      )

      # Not valid base64
      assert {:error, msg} = SAMLService.validate_response("@@@-not-base64-@@@")
      assert msg =~ "decode"
    end

    test "returns {:error, _} for valid base64 but malformed XML/assertion" do
      set_app_basics()
      set_config("sso_saml_idp_sso_url", "https://idp.example.com/sso")
      cert_b64 = Base.encode64("fake-cert-bytes")

      set_config(
        "sso_saml_idp_cert",
        "-----BEGIN CERTIFICATE-----\n#{cert_b64}\n-----END CERTIFICATE-----"
      )

      # Valid base64 of a junk string — will parse-fail or assertion-fail
      bad_response = Base.encode64("<not><a><saml/></a></not>")
      assert {:error, _} = SAMLService.validate_response(bad_response)
    end
  end

  describe "generate_sp_certificate/0" do
    @tag :openssl
    test "generates a self-signed cert + key when openssl is available" do
      case System.find_executable("openssl") do
        nil ->
          # CI without openssl — skip
          :ok

        _ ->
          assert {:ok, %{cert_pem: cert_pem, key_pem: key_pem}} =
                   SAMLService.generate_sp_certificate()

          assert cert_pem =~ "-----BEGIN CERTIFICATE-----"
          assert cert_pem =~ "-----END CERTIFICATE-----"
          assert key_pem =~ "-----BEGIN"
          assert key_pem =~ "PRIVATE KEY-----"
      end
    end

    test "generated cert can be embedded in metadata" do
      case System.find_executable("openssl") do
        nil ->
          :ok

        _ ->
          {:ok, %{cert_pem: cert_pem}} = SAMLService.generate_sp_certificate()

          set_app_basics()
          Settings.upsert_config("sso_saml_sp_cert", cert_pem)
          Settings.upsert_config("sso_saml_sign_requests", "true")

          {:ok, xml} = SAMLService.generate_sp_metadata()
          assert xml =~ "<md:KeyDescriptor use=\"signing\">"
          # The cert base64 (without headers) is in the XML
          cert_b64 =
            cert_pem
            |> String.replace("-----BEGIN CERTIFICATE-----", "")
            |> String.replace("-----END CERTIFICATE-----", "")
            |> String.replace("\n", "")
            |> String.trim()

          # First 30 chars should be present
          assert xml =~ String.slice(cert_b64, 0, 30)
      end
    end
  end

  describe "build_authn_request/0 IdP-from-metadata-URL path" do
    test "fetch failure surfaces a clean {:error, _}" do
      set_app_basics()
      # Invalid URL — will fail at Finch level
      set_config("sso_saml_idp_metadata_url", "http://127.0.0.1:1/never-listening")

      assert {:error, msg} = SAMLService.build_authn_request()
      # The error is either "metadata fetch failed" (Finch) or a parse error
      assert is_binary(msg)
    end
  end
end

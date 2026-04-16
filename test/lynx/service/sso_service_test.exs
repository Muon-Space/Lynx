# Copyright 2023 Clivern. All rights reserved.
# Use of this source code is governed by the MIT
# license that can be found in the LICENSE file.

defmodule Lynx.Service.SSOServiceTest do
  @moduledoc """
  SSO Service Test Cases
  """

  use ExUnit.Case

  alias Lynx.Service.SSOService

  describe "saml_assertion_to_attrs/1" do
    test "extracts attributes from assertion with email attribute" do
      assertion = %{
        attributes: %{
          "email" => "saml_user@example.com",
          "name" => "SAML User"
        },
        subject: %{name: "saml-name-id-001"}
      }

      assert {:ok, attrs} = SSOService.saml_assertion_to_attrs(assertion)
      assert attrs.email == "saml_user@example.com"
      assert attrs.name == "SAML User"
      assert attrs.external_id == "saml-name-id-001"
    end

    test "extracts email from OASIS claim URI" do
      assertion = %{
        attributes: %{
          "http://schemas.xmlsoap.org/ws/2005/05/identity/claims/emailaddress" =>
            "oasis@example.com"
        },
        subject: %{name: "oasis-id"}
      }

      assert {:ok, attrs} = SSOService.saml_assertion_to_attrs(assertion)
      assert attrs.email == "oasis@example.com"
    end

    test "builds name from givenName and surname" do
      assertion = %{
        attributes: %{
          "email" => "parts@example.com",
          "givenName" => "Jane",
          "surname" => "Doe"
        },
        subject: %{name: "parts-id"}
      }

      {:ok, attrs} = SSOService.saml_assertion_to_attrs(assertion)
      assert attrs.name == "Jane Doe"
    end

    test "falls back to email as name when no name attributes" do
      assertion = %{
        attributes: %{
          "email" => "noname@example.com"
        },
        subject: %{name: "noname-id"}
      }

      {:ok, attrs} = SSOService.saml_assertion_to_attrs(assertion)
      assert attrs.name == "noname@example.com"
    end

    test "returns error when no email attribute found" do
      assertion = %{
        attributes: %{"name" => "No Email User"},
        subject: %{name: "noemail-id"}
      }

      assert {:error, "No email attribute found in SAML assertion"} =
               SSOService.saml_assertion_to_attrs(assertion)
    end

    test "uses subject name as external_id" do
      assertion = %{
        attributes: %{"email" => "ext@example.com"},
        subject: %{name: "my-unique-nameid"}
      }

      {:ok, attrs} = SSOService.saml_assertion_to_attrs(assertion)
      assert attrs.external_id == "my-unique-nameid"
    end
  end
end

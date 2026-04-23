defmodule Lynx.Context.OPABundleTokenContextTest do
  use LynxWeb.LiveCase, async: false

  alias Lynx.Context.OPABundleTokenContext

  setup do
    mark_installed()
    :ok
  end

  describe "generate_token/1" do
    test "returns plaintext token once" do
      assert {:ok, %{uuid: uuid, token: token, name: "primary"}} =
               OPABundleTokenContext.generate_token("primary")

      assert is_binary(uuid)
      assert byte_size(token) > 20
    end

    test "rejects blank name" do
      assert {:error, _msg} = OPABundleTokenContext.generate_token("")
    end
  end

  describe "validate_token/1" do
    test "active token returns the record" do
      {:ok, %{token: t}} = OPABundleTokenContext.generate_token("p")
      assert %{name: "p"} = OPABundleTokenContext.validate_token(t)
    end

    test "revoked token returns nil" do
      {:ok, %{uuid: uuid, token: t}} = OPABundleTokenContext.generate_token("p")
      {:ok, _} = OPABundleTokenContext.revoke_token_by_uuid(uuid)

      assert OPABundleTokenContext.validate_token(t) == nil
    end

    test "unknown token returns nil" do
      assert OPABundleTokenContext.validate_token("not-a-real-token") == nil
    end

    test "bumps last_used_at on success" do
      {:ok, %{uuid: uuid, token: t}} = OPABundleTokenContext.generate_token("p")

      before = OPABundleTokenContext.get_token_by_uuid(uuid).last_used_at
      assert before == nil

      OPABundleTokenContext.validate_token(t)
      after_ = OPABundleTokenContext.get_token_by_uuid(uuid).last_used_at
      assert after_ != nil
    end
  end

  describe "list_tokens/0" do
    test "masks token values" do
      {:ok, _} = OPABundleTokenContext.generate_token("a")

      [row] = OPABundleTokenContext.list_tokens()
      assert String.ends_with?(row.token_prefix, "...")
      refute Map.has_key?(row, :token)
    end
  end
end

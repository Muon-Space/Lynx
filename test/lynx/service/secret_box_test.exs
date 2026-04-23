defmodule Lynx.Service.SecretBoxTest do
  @moduledoc """
  Pinning the contract of the AES-256-GCM at-rest encryption helper:

    * Roundtrip: decrypt(encrypt(x)) == {:ok, x}
    * Different IVs per encrypt → ciphertext varies even for same plaintext
    * Tampered tag/ct/iv → {:error, _}, never raises
    * Versioned envelope shape (v1.<iv64>.<ct64>.<tag64>)
    * nil/empty pass through cleanly
  """
  use ExUnit.Case, async: true

  alias Lynx.Service.SecretBox

  describe "encrypt/decrypt roundtrip" do
    test "decrypt(encrypt(x)) returns the original plaintext" do
      assert {:ok, "hello"} = SecretBox.decrypt(SecretBox.encrypt("hello"))

      assert {:ok, "with spaces and 🦊"} =
               SecretBox.decrypt(SecretBox.encrypt("with spaces and 🦊"))
    end

    test "long PEM-shaped plaintext roundtrips" do
      pem =
        "-----BEGIN PRIVATE KEY-----\n" <>
          String.duplicate("ABCDEF12345", 100) <>
          "\n-----END PRIVATE KEY-----"

      assert {:ok, ^pem} = SecretBox.decrypt(SecretBox.encrypt(pem))
    end
  end

  describe "encrypt/1 envelope" do
    test "produces v1.<iv>.<ct>.<tag> structure" do
      assert "v1." <> rest = SecretBox.encrypt("payload")
      parts = String.split(rest, ".")
      assert length(parts) == 3
      Enum.each(parts, fn p -> assert {:ok, _} = Base.url_decode64(p, padding: false) end)
    end

    test "different IVs produce different ciphertexts for the same plaintext" do
      a = SecretBox.encrypt("same input")
      b = SecretBox.encrypt("same input")
      refute a == b
      # But both decrypt to the same plaintext.
      assert SecretBox.decrypt(a) == {:ok, "same input"}
      assert SecretBox.decrypt(b) == {:ok, "same input"}
    end

    test "nil and empty string pass through unchanged" do
      assert SecretBox.encrypt(nil) == nil
      assert SecretBox.encrypt("") == ""
    end
  end

  describe "decrypt/1 fail modes" do
    test "tampered tag returns {:error, :decrypt_failed}" do
      "v1." <> rest = SecretBox.encrypt("legit")
      [iv, ct, _tag] = String.split(rest, ".")
      bad_tag = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
      tampered = "v1." <> iv <> "." <> ct <> "." <> bad_tag

      assert {:error, _} = SecretBox.decrypt(tampered)
    end

    test "tampered ciphertext returns {:error, :decrypt_failed}" do
      "v1." <> rest = SecretBox.encrypt("legit")
      [iv, _ct, tag] = String.split(rest, ".")
      bad_ct = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
      tampered = "v1." <> iv <> "." <> bad_ct <> "." <> tag

      assert {:error, _} = SecretBox.decrypt(tampered)
    end

    test "malformed envelope (wrong number of parts) returns {:error, :malformed}" do
      assert {:error, :malformed} = SecretBox.decrypt("v1.abc")
      assert {:error, :malformed} = SecretBox.decrypt("v1.abc.def")
    end

    test "value missing the v1. prefix is treated as plaintext (forward-compat)" do
      # This handles partially-backfilled rows: a config row without
      # the envelope prefix is returned as-is so callers don't break.
      assert {:ok, "raw plaintext"} = SecretBox.decrypt("raw plaintext")
    end

    test "nil and empty input map to {:ok, nil/\"\"}" do
      assert SecretBox.decrypt(nil) == {:ok, nil}
      assert SecretBox.decrypt("") == {:ok, ""}
    end
  end

  describe "encrypted?/1" do
    test "true for v1.-prefixed envelopes" do
      assert SecretBox.encrypted?(SecretBox.encrypt("anything"))
    end

    test "false for bare plaintext, nil, empty" do
      refute SecretBox.encrypted?("plain")
      refute SecretBox.encrypted?(nil)
      refute SecretBox.encrypted?("")
    end
  end
end

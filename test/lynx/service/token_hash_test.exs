defmodule Lynx.Service.TokenHashTest do
  @moduledoc """
  Pinning the contract of the bearer-token hashing module:

    * Same input → same hash (deterministic, so equality lookups work)
    * Different inputs → different hashes (collision resistance)
    * nil / empty → nil (so changesets pass through cleanly)
    * Hash output is hex-encoded (fits a regular string column)
    * Prefix returns the first 8 chars unchanged
  """
  use ExUnit.Case, async: true

  alias Lynx.Service.TokenHash

  describe "hash/1" do
    test "is deterministic for the same input" do
      assert TokenHash.hash("abc") == TokenHash.hash("abc")
    end

    test "differs for different inputs" do
      refute TokenHash.hash("abc") == TokenHash.hash("abd")
    end

    test "returns nil for nil/empty input" do
      assert TokenHash.hash(nil) == nil
      assert TokenHash.hash("") == nil
    end

    test "produces hex-encoded SHA-256 output (64 hex chars)" do
      hash = TokenHash.hash("some-real-token-value")
      assert is_binary(hash)
      assert String.length(hash) == 64
      assert hash =~ ~r/^[0-9a-f]{64}$/
    end
  end

  describe "prefix/1" do
    test "returns first 8 chars for tokens longer than 8" do
      assert TokenHash.prefix("abcdefghijklmnop") == "abcdefgh"
    end

    test "returns the whole token if 8 chars or shorter" do
      assert TokenHash.prefix("short") == "short"
      assert TokenHash.prefix("12345678") == "12345678"
    end

    test "returns nil for nil/empty" do
      assert TokenHash.prefix(nil) == nil
      assert TokenHash.prefix("") == nil
    end
  end
end

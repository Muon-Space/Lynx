defmodule Lynx.Service.JWTServiceTest do
  use ExUnit.Case, async: false

  alias Lynx.Service.JWTService

  @cache_table :lynx_jwks_cache

  setup do
    JWTService.init_cache()
    # Clear cache between tests so seeded JWKS don't leak
    if :ets.whereis(@cache_table) != :undefined do
      :ets.delete_all_objects(@cache_table)
    end

    :ok
  end

  # Generate a fresh RSA key for signing test JWTs and the JWKS
  # representation that the verifier will load.
  defp build_signing_keypair do
    jwk = JOSE.JWK.generate_key({:rsa, 2048})
    {_, jwk_map} = JOSE.JWK.to_public_map(jwk)
    # Add the alg field that JWTService.verify_and_decode reads
    jwk_map = Map.put(jwk_map, "alg", "RS256")
    jwk_map = Map.put(jwk_map, "use", "sig")
    {jwk, jwk_map}
  end

  defp sign_jwt(jwk, claims) do
    {_, token} =
      JOSE.JWT.sign(jwk, %{"alg" => "RS256"}, claims)
      |> JOSE.JWS.compact()

    token
  end

  defp seed_jwks_cache(discovery_url, jwks_map) do
    # Mimic put_cached/2 — the module reads under the "jwks:#{url}" key
    :ets.insert(@cache_table, {"jwks:#{discovery_url}", jwks_map, :os.system_time(:second)})
    :ok
  end

  describe "init_cache/0" do
    test "creates the ETS table when missing" do
      :ets.delete(@cache_table)
      assert :ets.whereis(@cache_table) == :undefined

      JWTService.init_cache()
      assert :ets.whereis(@cache_table) != :undefined
    end

    test "is a no-op when table already exists" do
      JWTService.init_cache()
      assert :ets.whereis(@cache_table) != :undefined

      # Calling again must not raise
      JWTService.init_cache()
      assert :ets.whereis(@cache_table) != :undefined
    end
  end

  describe "validate_token/3 with seeded JWKS cache (happy path)" do
    test "returns {:ok, claims} for a valid signed JWT", %{} do
      {jwk, public_jwk} = build_signing_keypair()
      seed_jwks_cache("https://idp.example.com", %{"keys" => [public_jwk]})

      claims = %{"sub" => "user-123", "iss" => "https://idp.example.com"}
      jwt = sign_jwt(jwk, claims)

      assert {:ok, decoded} = JWTService.validate_token("https://idp.example.com", jwt)
      assert decoded["sub"] == "user-123"
    end

    test "returns {:error, _} when no key matches the token", %{} do
      {_signing_jwk, _public} = build_signing_keypair()
      # Cache a DIFFERENT key — verification will fail
      {_other_jwk, other_public} = build_signing_keypair()
      seed_jwks_cache("https://idp.example.com", %{"keys" => [other_public]})

      {real_jwk, _} = build_signing_keypair()
      jwt = sign_jwt(real_jwk, %{"sub" => "x"})

      assert {:error, _} = JWTService.validate_token("https://idp.example.com", jwt)
    end

    test "returns {:error, _} when JWKS document has no keys", %{} do
      seed_jwks_cache("https://idp.example.com", %{"keys" => []})

      {jwk, _} = build_signing_keypair()
      jwt = sign_jwt(jwk, %{"sub" => "x"})

      assert {:error, _} = JWTService.validate_token("https://idp.example.com", jwt)
    end

    test "returns {:error, _} for a malformed JWT", %{} do
      {_, public} = build_signing_keypair()
      seed_jwks_cache("https://idp.example.com", %{"keys" => [public]})

      assert {:error, _} =
               JWTService.validate_token("https://idp.example.com", "not.a.real.jwt")
    end
  end

  describe "validate_token/3 expiry check" do
    test "rejects expired tokens", %{} do
      {jwk, public_jwk} = build_signing_keypair()
      seed_jwks_cache("https://idp.example.com", %{"keys" => [public_jwk]})

      claims = %{"sub" => "x", "exp" => :os.system_time(:second) - 60}
      jwt = sign_jwt(jwk, claims)

      assert {:error, "Token expired"} =
               JWTService.validate_token("https://idp.example.com", jwt)
    end

    test "accepts tokens with future expiry", %{} do
      {jwk, public_jwk} = build_signing_keypair()
      seed_jwks_cache("https://idp.example.com", %{"keys" => [public_jwk]})

      claims = %{"sub" => "x", "exp" => :os.system_time(:second) + 3600}
      jwt = sign_jwt(jwk, claims)

      assert {:ok, _} = JWTService.validate_token("https://idp.example.com", jwt)
    end

    test "accepts tokens with no exp claim", %{} do
      {jwk, public_jwk} = build_signing_keypair()
      seed_jwks_cache("https://idp.example.com", %{"keys" => [public_jwk]})

      jwt = sign_jwt(jwk, %{"sub" => "x"})

      assert {:ok, _} = JWTService.validate_token("https://idp.example.com", jwt)
    end

    test "accepts tokens with non-numeric exp (treated as missing)", %{} do
      {jwk, public_jwk} = build_signing_keypair()
      seed_jwks_cache("https://idp.example.com", %{"keys" => [public_jwk]})

      jwt = sign_jwt(jwk, %{"sub" => "x", "exp" => "not-a-number"})

      assert {:ok, _} = JWTService.validate_token("https://idp.example.com", jwt)
    end
  end

  describe "validate_token/3 audience check" do
    setup do
      {jwk, public_jwk} = build_signing_keypair()
      seed_jwks_cache("https://idp.example.com", %{"keys" => [public_jwk]})
      {:ok, jwk: jwk}
    end

    test "accepts when expected audience is nil", %{jwk: jwk} do
      jwt = sign_jwt(jwk, %{"sub" => "x", "aud" => "anything"})
      assert {:ok, _} = JWTService.validate_token("https://idp.example.com", jwt, nil)
    end

    test "accepts when expected audience is empty string", %{jwk: jwk} do
      jwt = sign_jwt(jwk, %{"sub" => "x", "aud" => "anything"})
      assert {:ok, _} = JWTService.validate_token("https://idp.example.com", jwt, "")
    end

    test "accepts when token has no aud claim and audience is expected", %{jwk: jwk} do
      jwt = sign_jwt(jwk, %{"sub" => "x"})
      assert {:ok, _} = JWTService.validate_token("https://idp.example.com", jwt, "lynx")
    end

    test "accepts when token aud is a string matching expected", %{jwk: jwk} do
      jwt = sign_jwt(jwk, %{"sub" => "x", "aud" => "lynx"})
      assert {:ok, _} = JWTService.validate_token("https://idp.example.com", jwt, "lynx")
    end

    test "accepts when token aud is a list containing expected", %{jwk: jwk} do
      jwt = sign_jwt(jwk, %{"sub" => "x", "aud" => ["other", "lynx", "third"]})
      assert {:ok, _} = JWTService.validate_token("https://idp.example.com", jwt, "lynx")
    end

    test "rejects when string aud does not match expected", %{jwk: jwk} do
      jwt = sign_jwt(jwk, %{"sub" => "x", "aud" => "wrong"})
      assert {:error, msg} = JWTService.validate_token("https://idp.example.com", jwt, "lynx")
      assert msg =~ "Audience mismatch"
    end

    test "rejects when list aud does not contain expected", %{jwk: jwk} do
      jwt = sign_jwt(jwk, %{"sub" => "x", "aud" => ["a", "b"]})
      assert {:error, msg} = JWTService.validate_token("https://idp.example.com", jwt, "lynx")
      assert msg =~ "Audience mismatch"
    end
  end

  describe "JWKS cache TTL" do
    test "cache hit serves the seeded value", %{} do
      {jwk, public_jwk} = build_signing_keypair()
      seed_jwks_cache("https://idp.example.com", %{"keys" => [public_jwk]})

      jwt = sign_jwt(jwk, %{"sub" => "x"})
      assert {:ok, _} = JWTService.validate_token("https://idp.example.com", jwt)
    end

    test "expired cache entry is evicted and a refetch is attempted", %{} do
      {jwk, public_jwk} = build_signing_keypair()

      # Seed with a timestamp older than the TTL (3600s)
      old_ts = :os.system_time(:second) - 4000

      :ets.insert(
        @cache_table,
        {"jwks:https://idp.example.com", %{"keys" => [public_jwk]}, old_ts}
      )

      jwt = sign_jwt(jwk, %{"sub" => "x"})

      # The cache miss falls through to fetch_discovery, which hits the
      # network. Without an issuer running, it errors — exactly the
      # behaviour we want to assert (cache was evicted, fetch attempted).
      result = JWTService.validate_token("https://idp.example.com", jwt)
      assert match?({:error, _}, result)

      # The stale entry should have been deleted
      assert :ets.lookup(@cache_table, "jwks:https://idp.example.com") == []
    end
  end

  describe "validate_token/3 fetch fallbacks (no cache)" do
    test "returns {:error, _} when discovery URL is unreachable", %{} do
      # No cache seeded; fetch will fail (no live IdP)
      result =
        JWTService.validate_token(
          "https://nonexistent.lynx.test",
          "any.token.value"
        )

      assert match?({:error, _}, result)
    end

    test "appends /.well-known/openid-configuration to bare URLs", %{} do
      # The fetch will still fail (no IdP) but this exercises the URL builder
      result = JWTService.validate_token("https://nonexistent.lynx.test/", "x.y.z")
      assert match?({:error, _}, result)
    end
  end
end

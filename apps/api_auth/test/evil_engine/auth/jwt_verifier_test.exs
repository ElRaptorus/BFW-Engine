defmodule EvilEngine.Auth.JwtVerifierTest do
  use ExUnit.Case, async: false

  alias EvilEngine.Auth.JwtVerifier
  alias EvilEngine.Test.AuthHelper

  describe "verify/1 with HS256" do
    test "accepts a valid token" do
      token = AuthHelper.sign_jwt(%{"sub" => "user-1", "roles" => ["admin"]})

      assert {:ok, claims} = JwtVerifier.verify(token)
      assert claims["sub"] == "user-1"
      assert claims["roles"] == ["admin"]
    end

    test "rejects an expired token" do
      token = AuthHelper.sign_expired_jwt(%{"sub" => "expired-user"})

      assert {:error, :expired} = JwtVerifier.verify(token)
    end

    test "rejects a not-yet-valid token" do
      token = AuthHelper.sign_not_yet_valid_jwt(%{"sub" => "future-user"})

      assert {:error, :not_yet_valid} = JwtVerifier.verify(token)
    end

    test "rejects a token signed with wrong secret" do
      token = AuthHelper.sign_wrong_secret_jwt(%{"sub" => "intruder"})

      assert {:error, :invalid_signature} = JwtVerifier.verify(token)
    end

    test "rejects garbage input" do
      assert {:error, :invalid_signature} = JwtVerifier.verify("not.a.jwt")
    end

    test "preserves all custom claims" do
      custom = %{
        "sub" => "user-2",
        "deploy_bpmn" => true,
        "lane:accounting" => "write",
        "observe_all" => true,
        "custom_field" => "hello"
      }

      token = AuthHelper.sign_jwt(custom)
      assert {:ok, claims} = JwtVerifier.verify(token)

      assert claims["deploy_bpmn"] == true
      assert claims["lane:accounting"] == "write"
      assert claims["observe_all"] == true
      assert claims["custom_field"] == "hello"
    end
  end

  describe "verify/1 with no key material" do
    test "returns :no_key_configured when both JWKS and HS256 are nil" do
      prev_secret = Application.get_env(:api_auth, :hs256_secret)
      Application.put_env(:api_auth, :hs256_secret, nil)

      try do
        secret = "temp_secret_for_signing_at_least_32!"
        jwk = JOSE.JWK.from_oct(secret)

        claims = %{
          "sub" => "x",
          "exp" => DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_unix()
        }

        {_, token} = JOSE.JWT.sign(jwk, %{"alg" => "HS256"}, claims) |> JOSE.JWS.compact()
        assert {:error, :no_key_configured} = JwtVerifier.verify(token)
      after
        Application.put_env(:api_auth, :hs256_secret, prev_secret)
      end
    end
  end

  describe "verify/1 with issuer validation (EVIL_JWT_ISSUER)" do
    setup do
      previous = Application.get_env(:api_auth, :issuer)
      on_exit(fn -> Application.put_env(:api_auth, :issuer, previous) end)
      :ok
    end

    test "accepts a token whose iss matches the configured issuer" do
      Application.put_env(:api_auth, :issuer, "https://issuer.example.com")
      token = AuthHelper.sign_jwt(%{"sub" => "user-1", "iss" => "https://issuer.example.com"})

      assert {:ok, claims} = JwtVerifier.verify(token)
      assert claims["iss"] == "https://issuer.example.com"
    end

    test "rejects a token whose iss does not match the configured issuer" do
      Application.put_env(:api_auth, :issuer, "https://issuer.example.com")
      token = AuthHelper.sign_jwt(%{"sub" => "user-1", "iss" => "https://attacker.example.com"})

      assert {:error, :issuer_mismatch} = JwtVerifier.verify(token)
    end

    test "rejects a token with no iss claim when issuer is configured" do
      Application.put_env(:api_auth, :issuer, "https://issuer.example.com")
      token = AuthHelper.sign_jwt(%{"sub" => "user-1"})

      assert {:error, :issuer_mismatch} = JwtVerifier.verify(token)
    end

    test "ignores iss claim when EVIL_JWT_ISSUER is unset" do
      Application.put_env(:api_auth, :issuer, nil)
      token = AuthHelper.sign_jwt(%{"sub" => "user-1", "iss" => "https://anything.example.com"})

      assert {:ok, claims} = JwtVerifier.verify(token)
      assert claims["iss"] == "https://anything.example.com"
    end
  end

  describe "verify/1 with audience validation (EVIL_JWT_AUDIENCE)" do
    setup do
      previous = Application.get_env(:api_auth, :audience)
      on_exit(fn -> Application.put_env(:api_auth, :audience, previous) end)
      :ok
    end

    test "accepts a token whose aud matches the configured audience (string)" do
      Application.put_env(:api_auth, :audience, "evil-engine")
      token = AuthHelper.sign_jwt(%{"sub" => "user-1", "aud" => "evil-engine"})

      assert {:ok, claims} = JwtVerifier.verify(token)
      assert claims["aud"] == "evil-engine"
    end

    test "accepts a token whose aud array contains the configured audience" do
      Application.put_env(:api_auth, :audience, "evil-engine")
      token = AuthHelper.sign_jwt(%{"sub" => "user-1", "aud" => ["other-service", "evil-engine"]})

      assert {:ok, _claims} = JwtVerifier.verify(token)
    end

    test "rejects a token whose aud does not match the configured audience" do
      Application.put_env(:api_auth, :audience, "evil-engine")
      token = AuthHelper.sign_jwt(%{"sub" => "user-1", "aud" => "other-service"})

      assert {:error, :audience_mismatch} = JwtVerifier.verify(token)
    end

    test "rejects a token whose aud array does not contain the configured audience" do
      Application.put_env(:api_auth, :audience, "evil-engine")
      token = AuthHelper.sign_jwt(%{"sub" => "user-1", "aud" => ["other-service", "yet-another"]})

      assert {:error, :audience_mismatch} = JwtVerifier.verify(token)
    end

    test "rejects a token with no aud claim when audience is configured" do
      Application.put_env(:api_auth, :audience, "evil-engine")
      token = AuthHelper.sign_jwt(%{"sub" => "user-1"})

      assert {:error, :audience_mismatch} = JwtVerifier.verify(token)
    end

    test "ignores aud claim when EVIL_JWT_AUDIENCE is unset" do
      Application.put_env(:api_auth, :audience, nil)
      token = AuthHelper.sign_jwt(%{"sub" => "user-1", "aud" => "anything"})

      assert {:ok, claims} = JwtVerifier.verify(token)
      assert claims["aud"] == "anything"
    end
  end

  describe "verify/1 combined claim validation" do
    setup do
      previous_iss = Application.get_env(:api_auth, :issuer)
      previous_aud = Application.get_env(:api_auth, :audience)

      on_exit(fn ->
        Application.put_env(:api_auth, :issuer, previous_iss)
        Application.put_env(:api_auth, :audience, previous_aud)
      end)

      :ok
    end

    test "accepts a token with valid iss, aud, exp" do
      Application.put_env(:api_auth, :issuer, "https://issuer.example.com")
      Application.put_env(:api_auth, :audience, "evil-engine")

      token =
        AuthHelper.sign_jwt(%{
          "sub" => "user-1",
          "iss" => "https://issuer.example.com",
          "aud" => "evil-engine"
        })

      assert {:ok, _claims} = JwtVerifier.verify(token)
    end

    test "expiration takes priority over issuer mismatch" do
      Application.put_env(:api_auth, :issuer, "https://issuer.example.com")

      token =
        AuthHelper.sign_expired_jwt(%{
          "sub" => "user-1",
          "iss" => "https://attacker.example.com"
        })

      assert {:error, :expired} = JwtVerifier.verify(token)
    end
  end

  describe "verify/1 with RS256 via JWKS cache" do
    setup do
      private_jwk = JOSE.JWK.generate_key({:rsa, 2048})
      public_jwk = JOSE.JWK.to_public(private_jwk)

      :sys.replace_state(EvilEngine.Auth.JwksCache, fn state ->
        %{state | keys: public_jwk}
      end)

      on_exit(fn ->
        :sys.replace_state(EvilEngine.Auth.JwksCache, fn state -> %{state | keys: nil} end)
      end)

      {:ok, private_jwk: private_jwk}
    end

    test "accepts a valid RS256 token when JWKS keys are cached", %{private_jwk: private_jwk} do
      claims = %{
        "sub" => "rs256-user",
        "exp" => DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_unix()
      }

      {_, token} =
        JOSE.JWT.sign(private_jwk, %{"alg" => "RS256"}, claims) |> JOSE.JWS.compact()

      assert {:ok, decoded} = JwtVerifier.verify(token)
      assert decoded["sub"] == "rs256-user"
    end

    test "rejects RS256 token signed with a different key pair", %{private_jwk: _private_jwk} do
      other_jwk = JOSE.JWK.generate_key({:rsa, 2048})

      claims = %{
        "sub" => "wrong-key-user",
        "exp" => DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_unix()
      }

      {_, token} =
        JOSE.JWT.sign(other_jwk, %{"alg" => "RS256"}, claims) |> JOSE.JWS.compact()

      assert {:error, :invalid_signature} = JwtVerifier.verify(token)
    end
  end
end

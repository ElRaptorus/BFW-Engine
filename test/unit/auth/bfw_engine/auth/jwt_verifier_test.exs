defmodule BfwEngine.Auth.JwtVerifierTest do
  use ExUnit.Case, async: false

  alias BfwEngine.Auth.JwksCache
  alias BfwEngine.Auth.JwtVerifier
  alias BfwEngine.Test.AuthHelper

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
      prev_secret = Application.get_env(:bfw_engine, :hs256_secret)
      Application.put_env(:bfw_engine, :hs256_secret, nil)

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
        Application.put_env(:bfw_engine, :hs256_secret, prev_secret)
      end
    end
  end

  describe "verify/1 with issuer validation (BFE_JWT_ISSUER)" do
    setup do
      previous = Application.get_env(:bfw_engine, :issuer)
      on_exit(fn -> Application.put_env(:bfw_engine, :issuer, previous) end)
      :ok
    end

    test "accepts a token whose iss matches the configured issuer" do
      Application.put_env(:bfw_engine, :issuer, "https://issuer.example.com")
      token = AuthHelper.sign_jwt(%{"sub" => "user-1", "iss" => "https://issuer.example.com"})

      assert {:ok, claims} = JwtVerifier.verify(token)
      assert claims["iss"] == "https://issuer.example.com"
    end

    test "rejects a token whose iss does not match the configured issuer" do
      Application.put_env(:bfw_engine, :issuer, "https://issuer.example.com")
      token = AuthHelper.sign_jwt(%{"sub" => "user-1", "iss" => "https://attacker.example.com"})

      assert {:error, :issuer_mismatch} = JwtVerifier.verify(token)
    end

    test "rejects a token with no iss claim when issuer is configured" do
      Application.put_env(:bfw_engine, :issuer, "https://issuer.example.com")
      token = AuthHelper.sign_jwt(%{"sub" => "user-1"})

      assert {:error, :issuer_mismatch} = JwtVerifier.verify(token)
    end

    test "ignores iss claim when BFE_JWT_ISSUER is unset" do
      Application.put_env(:bfw_engine, :issuer, nil)
      token = AuthHelper.sign_jwt(%{"sub" => "user-1", "iss" => "https://anything.example.com"})

      assert {:ok, claims} = JwtVerifier.verify(token)
      assert claims["iss"] == "https://anything.example.com"
    end
  end

  describe "verify/1 with audience validation (BFE_JWT_AUDIENCE)" do
    setup do
      previous = Application.get_env(:bfw_engine, :audience)
      on_exit(fn -> Application.put_env(:bfw_engine, :audience, previous) end)
      :ok
    end

    test "accepts a token whose aud matches the configured audience (string)" do
      Application.put_env(:bfw_engine, :audience, "bfw-engine")
      token = AuthHelper.sign_jwt(%{"sub" => "user-1", "aud" => "bfw-engine"})

      assert {:ok, claims} = JwtVerifier.verify(token)
      assert claims["aud"] == "bfw-engine"
    end

    test "accepts a token whose aud array contains the configured audience" do
      Application.put_env(:bfw_engine, :audience, "bfw-engine")
      token = AuthHelper.sign_jwt(%{"sub" => "user-1", "aud" => ["other-service", "bfw-engine"]})

      assert {:ok, _claims} = JwtVerifier.verify(token)
    end

    test "rejects a token whose aud does not match the configured audience" do
      Application.put_env(:bfw_engine, :audience, "bfw-engine")
      token = AuthHelper.sign_jwt(%{"sub" => "user-1", "aud" => "other-service"})

      assert {:error, :audience_mismatch} = JwtVerifier.verify(token)
    end

    test "rejects a token whose aud array does not contain the configured audience" do
      Application.put_env(:bfw_engine, :audience, "bfw-engine")
      token = AuthHelper.sign_jwt(%{"sub" => "user-1", "aud" => ["other-service", "yet-another"]})

      assert {:error, :audience_mismatch} = JwtVerifier.verify(token)
    end

    test "rejects a token with no aud claim when audience is configured" do
      Application.put_env(:bfw_engine, :audience, "bfw-engine")
      token = AuthHelper.sign_jwt(%{"sub" => "user-1"})

      assert {:error, :audience_mismatch} = JwtVerifier.verify(token)
    end

    test "ignores aud claim when BFE_JWT_AUDIENCE is unset" do
      Application.put_env(:bfw_engine, :audience, nil)
      token = AuthHelper.sign_jwt(%{"sub" => "user-1", "aud" => "anything"})

      assert {:ok, claims} = JwtVerifier.verify(token)
      assert claims["aud"] == "anything"
    end
  end

  describe "verify/1 combined claim validation" do
    setup do
      previous_iss = Application.get_env(:bfw_engine, :issuer)
      previous_aud = Application.get_env(:bfw_engine, :audience)

      on_exit(fn ->
        Application.put_env(:bfw_engine, :issuer, previous_iss)
        Application.put_env(:bfw_engine, :audience, previous_aud)
      end)

      :ok
    end

    test "accepts a token with valid iss, aud, exp" do
      Application.put_env(:bfw_engine, :issuer, "https://issuer.example.com")
      Application.put_env(:bfw_engine, :audience, "bfw-engine")

      token =
        AuthHelper.sign_jwt(%{
          "sub" => "user-1",
          "iss" => "https://issuer.example.com",
          "aud" => "bfw-engine"
        })

      assert {:ok, _claims} = JwtVerifier.verify(token)
    end

    test "expiration takes priority over issuer mismatch" do
      Application.put_env(:bfw_engine, :issuer, "https://issuer.example.com")

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
      other_jwk = JOSE.JWK.generate_key({:rsa, 2048})

      key_set = %{
        "keys" => [
          public_key_map(other_jwk, "other-key"),
          public_key_map(private_jwk, "signing-key")
        ]
      }

      {:ok, body_agent} = Agent.start_link(fn -> %{body: Jason.encode!(key_set), requests: 0} end)
      {server, port} = start_jwks_server(body_agent)

      restart_jwks_cache("http://127.0.0.1:#{port}/jwks", refresh_ms: 50)

      assert wait_for_jwks_keys()

      on_exit(fn ->
        Process.exit(server, :kill)
        restart_jwks_cache(nil)
      end)

      {:ok, private_jwk: private_jwk, body_agent: body_agent}
    end

    test "accepts a token whose kid selects the second key of a real key set", %{
      private_jwk: private_jwk
    } do
      token = sign_rs256(private_jwk, %{"alg" => "RS256", "kid" => "signing-key"})

      assert {:ok, decoded} = JwtVerifier.verify(token)
      assert decoded["sub"] == "rs256-user"
    end

    test "accepts a kid-less token by trying every key in the set", %{private_jwk: private_jwk} do
      token = sign_rs256(private_jwk, %{"alg" => "RS256"})

      assert {:ok, decoded} = JwtVerifier.verify(token)
      assert decoded["sub"] == "rs256-user"
    end

    test "rejects a token with a kid that is not in the key set", %{private_jwk: private_jwk} do
      token = sign_rs256(private_jwk, %{"alg" => "RS256", "kid" => "unknown-key"})

      assert {:error, :invalid_signature} = JwtVerifier.verify(token)
    end

    test "rejects a token that names the wrong key by kid", %{private_jwk: private_jwk} do
      token = sign_rs256(private_jwk, %{"alg" => "RS256", "kid" => "other-key"})

      assert {:error, :invalid_signature} = JwtVerifier.verify(token)
    end

    test "keeps the previously cached keys when a refresh returns a non-JSON body", %{
      private_jwk: private_jwk,
      body_agent: body_agent
    } do
      %{requests: requests_before} =
        Agent.get_and_update(body_agent, &{&1, %{&1 | body: "this is not json"}})

      wait_for_requests(body_agent, requests_before + 2)
      token = sign_rs256(private_jwk, %{"alg" => "RS256", "kid" => "signing-key"})

      assert {:ok, _claims} = JwtVerifier.verify(token)
    end

    test "a bare key document without kid verifies kid-less tokens only", %{
      private_jwk: private_jwk,
      body_agent: body_agent
    } do
      {_key_type, bare_key} = private_jwk |> JOSE.JWK.to_public() |> JOSE.JWK.to_map()

      %{requests: requests_before} =
        Agent.get_and_update(body_agent, &{&1, %{&1 | body: Jason.encode!(bare_key)}})

      wait_for_requests(body_agent, requests_before + 2)

      assert {:ok, _claims} = JwtVerifier.verify(sign_rs256(private_jwk, %{"alg" => "RS256"}))

      assert {:error, :invalid_signature} =
               JwtVerifier.verify(
                 sign_rs256(private_jwk, %{"alg" => "RS256", "kid" => "signing-key"})
               )
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

  defp public_key_map(private_jwk, key_id) do
    {_key_type, fields} = private_jwk |> JOSE.JWK.to_public() |> JOSE.JWK.to_map()
    Map.put(fields, "kid", key_id)
  end

  defp sign_rs256(private_jwk, protected_header) do
    claims = %{
      "sub" => "rs256-user",
      "exp" => DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_unix()
    }

    {_, token} = private_jwk |> JOSE.JWT.sign(protected_header, claims) |> JOSE.JWS.compact()
    token
  end

  defp wait_for_requests(body_agent, minimum_requests) do
    Enum.reduce_while(1..100, false, fn _attempt, _seen ->
      if Agent.get(body_agent, & &1.requests) >= minimum_requests do
        {:halt, true}
      else
        Process.sleep(20)
        {:cont, false}
      end
    end)
  end

  defp restart_jwks_cache(jwks_url, options \\ []) do
    supervisor = BfwEngine.Auth.Supervisor
    _ = Supervisor.terminate_child(supervisor, JwksCache)
    _ = Supervisor.delete_child(supervisor, JwksCache)

    {:ok, _pid} =
      Supervisor.start_child(supervisor, {JwksCache, [jwks_url: jwks_url] ++ options})
  end

  defp wait_for_jwks_keys do
    Enum.reduce_while(1..50, false, fn _attempt, _seen ->
      if JwksCache.get_keys() do
        {:halt, true}
      else
        Process.sleep(20)
        {:cont, false}
      end
    end)
  end

  defp start_jwks_server(body_agent) do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])

    {:ok, port} = :inet.port(listen)
    server = spawn_link(fn -> accept_jwks(listen, body_agent) end)
    {server, port}
  end

  defp accept_jwks(listen, body_agent) do
    case :gen_tcp.accept(listen, 5_000) do
      {:ok, socket} ->
        _ = :gen_tcp.recv(socket, 0, 2_000)
        body = Agent.get_and_update(body_agent, &{&1.body, %{&1 | requests: &1.requests + 1}})

        response =
          "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n" <>
            body

        :gen_tcp.send(socket, response)
        :gen_tcp.close(socket)
        accept_jwks(listen, body_agent)

      {:error, :timeout} ->
        accept_jwks(listen, body_agent)

      {:error, :closed} ->
        :ok
    end
  end
end

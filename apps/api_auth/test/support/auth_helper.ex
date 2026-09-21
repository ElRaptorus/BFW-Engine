defmodule BfwEngine.Test.AuthHelper do
  @moduledoc false

  @test_secret "test_only_secret_at_least_32_bytes!"

  @doc "Ensures the test secret is set in Application config and returns it."
  def ensure_test_secret do
    case Application.get_env(:api_auth, :hs256_secret) do
      nil ->
        Application.put_env(:api_auth, :hs256_secret, @test_secret)
        @test_secret

      secret ->
        secret
    end
  end

  @doc "Signs a test JWT with HS256 using the configured test secret."
  def sign_jwt(claims \\ %{}) do
    secret = ensure_test_secret()
    jwk = JOSE.JWK.from_oct(secret)

    default_claims = %{
      "exp" => DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_unix(),
      "iat" => DateTime.utc_now() |> DateTime.to_unix()
    }

    merged = Map.merge(default_claims, claims)
    {_, compact} = JOSE.JWT.sign(jwk, %{"alg" => "HS256"}, merged) |> JOSE.JWS.compact()
    compact
  end

  @doc "Signs an expired JWT."
  def sign_expired_jwt(claims \\ %{}) do
    sign_jwt(
      Map.merge(
        %{"exp" => DateTime.utc_now() |> DateTime.add(-3600) |> DateTime.to_unix()},
        claims
      )
    )
  end

  @doc "Signs a JWT that is not yet valid (nbf in the future)."
  def sign_not_yet_valid_jwt(claims \\ %{}) do
    sign_jwt(
      Map.merge(
        %{"nbf" => DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_unix()},
        claims
      )
    )
  end

  @doc "Signs a JWT with a completely wrong secret."
  def sign_wrong_secret_jwt(claims \\ %{}) do
    jwk = JOSE.JWK.from_oct("wrong_secret_that_is_at_least_32_bytes!")

    default_claims = %{
      "sub" => "intruder",
      "exp" => DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_unix()
    }

    merged = Map.merge(default_claims, claims)
    {_, compact} = JOSE.JWT.sign(jwk, %{"alg" => "HS256"}, merged) |> JOSE.JWS.compact()
    compact
  end

  @doc "Builds a Plug.Test conn with a valid Bearer token."
  def conn_with_auth(method, path, claims \\ %{}) do
    token = sign_jwt(claims)

    Plug.Test.conn(method, path)
    |> Plug.Conn.put_req_header("authorization", "Bearer #{token}")
  end

  @doc "Temporarily disables auth, runs the function, then restores."
  def with_auth_disabled(fun) do
    previous = Application.get_env(:api_auth, :auth_disabled)
    Application.put_env(:api_auth, :auth_disabled, true)

    try do
      fun.()
    after
      Application.put_env(:api_auth, :auth_disabled, previous)
    end
  end

  @doc "Temporarily enables auth, runs the function, then restores."
  def with_auth_enabled(fun) do
    previous = Application.get_env(:api_auth, :auth_disabled)
    Application.put_env(:api_auth, :auth_disabled, false)

    try do
      fun.()
    after
      Application.put_env(:api_auth, :auth_disabled, previous)
    end
  end
end

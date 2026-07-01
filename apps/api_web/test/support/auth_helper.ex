defmodule EvilEngine.Test.HttpAuthHelper do
  @moduledoc false

  @test_secret "test_only_secret_at_least_32_bytes!"

  def sign_jwt(claims \\ %{}) do
    secret =
      case Application.get_env(:api_auth, :hs256_secret) do
        nil ->
          Application.put_env(:api_auth, :hs256_secret, @test_secret)
          @test_secret

        s ->
          s
      end

    jwk = JOSE.JWK.from_oct(secret)

    default_claims = %{
      "sub" => "test-user",
      "exp" => DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_unix(),
      "roles" => ["operator"]
    }

    merged = Map.merge(default_claims, claims)
    {_, compact} = JOSE.JWT.sign(jwk, %{"alg" => "HS256"}, merged) |> JOSE.JWS.compact()
    compact
  end
end

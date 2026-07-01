defmodule EvilEngine.Auth.JwtVerifier do
  @moduledoc """
  Verifies JWT tokens using the configured algorithm(s).

  Tries JWKS first (RS256 / ES256), falls back to HS256. At least one
  must be configured unless `EVIL_AUTH_DISABLED=true`.

  When `EVIL_JWT_ISSUER` / `EVIL_JWT_AUDIENCE` are configured, the
  corresponding token claims (`iss` / `aud`) must match. If the env
  vars are unset, the corresponding claim is not validated.

  Returns `{:ok, claims}` on success, `{:error, reason}` on failure.
  """

  alias EvilEngine.Auth.JwksCache

  @claim_errors [:expired, :not_yet_valid, :issuer_mismatch, :audience_mismatch]

  @doc """
  Verify a raw JWT string against the configured key material.

  ## Return values

  - `{:ok, claims}` — valid token, claims is a map of string keys
  - `{:error, :no_key_configured}` — neither JWKS nor HS256 secret set
  - `{:error, :invalid_signature}` — signature check failed on all algos
  - `{:error, :expired}` — token `exp` claim is in the past
  - `{:error, :not_yet_valid}` — token `nbf` claim is in the future
  - `{:error, :issuer_mismatch}` — `EVIL_JWT_ISSUER` configured and `iss` does not match
  - `{:error, :audience_mismatch}` — `EVIL_JWT_AUDIENCE` configured and `aud` does not match
  """
  @spec verify(String.t()) ::
          {:ok, map()}
          | {:error,
             :no_key_configured
             | :invalid_signature
             | :expired
             | :not_yet_valid
             | :issuer_mismatch
             | :audience_mismatch}
  def verify(token) when is_binary(token) do
    with {:error, jwks_reason} <- try_jwks(token),
         {:error, hs256_reason} <- try_hs256(token) do
      case {jwks_reason, hs256_reason} do
        {:no_jwks, :no_secret} -> {:error, :no_key_configured}
        {_, claim_err} when claim_err in @claim_errors -> {:error, claim_err}
        {claim_err, _} when claim_err in @claim_errors -> {:error, claim_err}
        _ -> {:error, :invalid_signature}
      end
    end
  end

  defp try_jwks(token) do
    case JwksCache.get_keys() do
      nil ->
        {:error, :no_jwks}

      jwk ->
        case JOSE.JWT.verify_strict(jwk, ["RS256", "ES256"], token) do
          {true, %JOSE.JWT{fields: claims}, _jws} ->
            validate_claims(claims)

          _ ->
            {:error, :jwks_signature_mismatch}
        end
    end
  rescue
    _ -> {:error, :jwks_verification_error}
  end

  defp try_hs256(token) do
    case hs256_secret() do
      nil ->
        {:error, :no_secret}

      secret ->
        jwk = JOSE.JWK.from_oct(secret)

        case JOSE.JWT.verify_strict(jwk, ["HS256"], token) do
          {true, %JOSE.JWT{fields: claims}, _jws} ->
            validate_claims(claims)

          _ ->
            {:error, :hs256_signature_mismatch}
        end
    end
  rescue
    _ -> {:error, :hs256_verification_error}
  end

  defp validate_claims(claims) do
    now = DateTime.utc_now() |> DateTime.to_unix()

    cond do
      Map.has_key?(claims, "exp") and claims["exp"] < now ->
        {:error, :expired}

      Map.has_key?(claims, "nbf") and claims["nbf"] > now ->
        {:error, :not_yet_valid}

      issuer_mismatch?(claims) ->
        {:error, :issuer_mismatch}

      audience_mismatch?(claims) ->
        {:error, :audience_mismatch}

      true ->
        {:ok, claims}
    end
  end

  defp issuer_mismatch?(claims) do
    case configured_issuer() do
      nil -> false
      expected -> Map.get(claims, "iss") != expected
    end
  end

  defp audience_mismatch?(claims) do
    case configured_audience() do
      nil -> false
      expected -> not audience_matches?(Map.get(claims, "aud"), expected)
    end
  end

  defp audience_matches?(actual, expected) when is_binary(actual), do: actual == expected
  defp audience_matches?(actual, expected) when is_list(actual), do: expected in actual
  defp audience_matches?(_actual, _expected), do: false

  defp hs256_secret do
    Application.get_env(:api_auth, :hs256_secret)
  end

  defp configured_issuer do
    Application.get_env(:api_auth, :issuer)
  end

  defp configured_audience do
    Application.get_env(:api_auth, :audience)
  end
end

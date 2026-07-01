defmodule EvilEngine.Auth.JwtAuthProvider do
  @moduledoc """
  Built-in auth provider that delegates to `JwtVerifier` and maps
  the decoded claims to an `%Identity{}`.

  This is the default implementation of `EvilEngine.Plugin.AuthProvider`.
  It is active unless a plugin registers a replacement via
  `facade.register_auth_provider/1`.
  """

  @behaviour EvilEngine.Plugin.AuthProvider

  alias EvilEngine.Auth.JwtVerifier
  alias EvilEngine.Types.Identity

  @impl true
  @spec verify_and_resolve(String.t()) :: {:ok, Identity.t()} | {:error, term()}
  def verify_and_resolve(token) do
    case JwtVerifier.verify(token) do
      {:ok, claims} -> {:ok, build_identity(claims)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Build an `%Identity{}` from decoded JWT claims."
  @spec build_identity(map()) :: Identity.t()
  def build_identity(claims) when is_map(claims) do
    %Identity{
      id: claims["sub"] || claims["client_id"] || "unknown",
      roles: extract_list(claims, "roles"),
      groups: extract_list(claims, "groups"),
      claims: claims
    }
  end

  defp extract_list(claims, key) do
    case Map.get(claims, key) do
      list when is_list(list) -> list
      _ -> []
    end
  end
end

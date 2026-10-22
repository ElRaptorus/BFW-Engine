defmodule BfwEngine.Auth.JwtAuthProvider do
  @moduledoc """
  Built-in auth provider that delegates to `JwtVerifier` and maps
  the decoded claims to an `%Identity{}`.

  This is the default implementation of `BfwEngine.Plugin.AuthProvider`.
  A verified token without a non-blank string `sub` or `client_id` claim
  yields `{:error, :missing_subject}`.

  It is active unless a plugin registers a replacement via
  `facade.register_auth_provider/1`.
  """

  @behaviour BfwEngine.Plugin.AuthProvider

  alias BfwEngine.Auth.JwtVerifier
  alias BfwEngine.Types.Identity

  @impl true
  @spec verify_and_resolve(String.t()) :: {:ok, Identity.t()} | {:error, term()}
  def verify_and_resolve(token) do
    case JwtVerifier.verify(token) do
      {:ok, claims} -> build_identity(claims)
      {:error, reason} -> {:error, reason}
    end
  end

  @spec build_identity(map()) :: {:ok, Identity.t()} | {:error, :missing_subject}
  defp build_identity(claims) when is_map(claims) do
    case subject_identifier(claims) do
      nil ->
        {:error, :missing_subject}

      identifier ->
        {:ok,
         %Identity{
           id: identifier,
           roles: extract_list(claims, "roles"),
           groups: extract_list(claims, "groups"),
           claims: claims
         }}
    end
  end

  defp subject_identifier(claims) do
    ["sub", "client_id"]
    |> Enum.map(&Map.get(claims, &1))
    |> Enum.find(&non_blank_string?/1)
  end

  defp non_blank_string?(value), do: is_binary(value) and String.trim(value) != ""

  defp extract_list(claims, key) do
    case Map.get(claims, key) do
      list when is_list(list) -> list
      _ -> []
    end
  end
end

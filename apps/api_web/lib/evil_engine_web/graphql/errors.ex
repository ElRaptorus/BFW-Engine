defmodule EvilEngineWeb.Graphql.Errors do
  @moduledoc """
  Translates engine error tuples into Absinthe-compatible GraphQL errors.

  GraphQL is query-only. This helper is retained for query-layer error
  translation (for example payload-cap) and for tests. There are no
  GraphQL mutation resolvers.
  """

  @doc """
  Translates an engine error tuple into a GraphQL error map.

  Returns a map suitable for inclusion in the `errors` list of a
  GraphQL response, with `extensions.code` set to the appropriate
  error code string.

  ## Examples

      iex> Errors.to_graphql_error({:error, :payload_too_large, %{size: 100_000, limit: 65_536, field: :payload}})
      %{
        message: "Payload exceeds the maximum allowed size",
        extensions: %{
          code: "PAYLOAD_TOO_LARGE",
          size: 100_000,
          limit: 65_536,
          field: "payload"
        }
      }
  """
  @spec to_graphql_error({:error, atom()} | {:error, atom(), map()}) ::
          %{message: String.t(), extensions: map()}
  def to_graphql_error({:error, :payload_too_large, %{size: size, limit: limit, field: field}}) do
    %{
      message: "Payload exceeds the maximum allowed size",
      extensions: %{
        code: "PAYLOAD_TOO_LARGE",
        size: size,
        limit: limit,
        field: to_string(field)
      }
    }
  end

  def to_graphql_error({:error, reason}) when is_atom(reason) do
    %{
      message: "Operation failed: #{reason}",
      extensions: %{
        code: reason |> to_string() |> String.upcase()
      }
    }
  end

  def to_graphql_error({:error, reason, details}) when is_atom(reason) and is_map(details) do
    %{
      message: "Operation failed: #{reason}",
      extensions: Map.put(details, :code, reason |> to_string() |> String.upcase())
    }
  end
end

defmodule BfwEngine.Client.Wire do
  @moduledoc """
  Small helper for building camelCase JSON request bodies from optional
  Elixir-side values, shared by the resource modules.
  """

  @doc """
  Puts `value` under `key` in `map`, unless `value` is `nil`.

  Used to build request bodies where every field is optional and the wire
  contract omits absent keys rather than sending `null`.
  """
  @spec put_if_present(map(), String.t(), term()) :: map()
  def put_if_present(map, _key, nil), do: map
  def put_if_present(map, key, value), do: Map.put(map, key, value)

  @doc """
  Normalizes a `typeProperties` value coming back from a GraphQL
  `flowNodeInstances` query.

  The underlying Ash resource types `type_properties` as `:map`, but
  AshGraphql serializes `:map`-typed attributes as a JSON-encoded string
  scalar rather than a native JSON object on the GraphQL wire (REST returns
  it as a native object). This decodes that string back into a map so every
  `BfwEngine.Client` caller sees the same map shape regardless of which
  wire surface answered — matching what the resource modules' docs promise.
  Already-decoded maps and `nil` pass through unchanged; a value that fails
  to decode as JSON is returned as-is.
  """
  @spec decode_type_properties(term()) :: map() | term()
  def decode_type_properties(nil), do: nil
  def decode_type_properties(type_properties) when is_map(type_properties), do: type_properties

  def decode_type_properties(type_properties) when is_binary(type_properties) do
    case Jason.decode(type_properties) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> type_properties
    end
  end

  def decode_type_properties(type_properties), do: type_properties

  @doc """
  Encodes one URL path segment, leaving unreserved characters unchanged
  and encoding reserved characters such as `/`.
  """
  @spec path_segment(String.t()) :: String.t()
  def path_segment(segment) when is_binary(segment) do
    URI.encode(segment, &URI.char_unreserved?/1)
  end

  @doc """
  Applies `decode_type_properties/1` to the `"typeProperties"` key of a
  single `flowNodeInstances` GraphQL result map when that key is present.
  A result that omits the key is returned unchanged.
  """
  @spec normalize_flow_node_instance(map()) :: map()
  def normalize_flow_node_instance(result) do
    case Map.fetch(result, "typeProperties") do
      {:ok, type_properties} ->
        Map.put(result, "typeProperties", decode_type_properties(type_properties))

      :error ->
        result
    end
  end
end

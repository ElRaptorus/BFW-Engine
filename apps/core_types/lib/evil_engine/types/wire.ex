defmodule EvilEngine.Types.Wire do
  @moduledoc """
  Snake-to-camelCase key conversion for JSON wire surfaces.

  Enforces the **opaque payload boundary**: structural keys are
  camelCased, but user-payload subtrees (tokens, claims, form data,
  contracts, error details) pass through unchanged so that downstream
  consumers see the exact shape the process author intended.

  Used by Jason.Encoder implementations on event structs and by
  controllers/plugs that build response maps.
  """

  @opaque_atom_fields MapSet.new([
                        :payload,
                        :result,
                        :input_token,
                        :output_token,
                        :started_with_context,
                        :started_by,
                        :deployer,
                        :claims,
                        :form_fields,
                        :form_actions,
                        :type_properties,
                        :error_info,
                        :payload_contract,
                        :result_contract,
                        :data_contracts,
                        :bpmn_xml,
                        :dmn_xml,
                        :violations,
                        :metadata,
                        :deleted_by,
                        :data_object_cache
                      ])

  @opaque_string_fields MapSet.new(
                          Enum.map(MapSet.to_list(@opaque_atom_fields), &Atom.to_string/1)
                        )

  @doc """
  Recursively converts map keys from `snake_case` to `camelCase`.

  - Atom keys like `:process_model_id` become `"processModelId"`.
  - String keys like `"process_model_id"` become `"processModelId"`.
  - Keys listed in the opaque-field set are converted but their
    **values** are emitted unchanged (no nested conversion).
  - Lists are traversed element-by-element.
  - Non-map, non-list values pass through.
  """
  @spec camelize_keys(term()) :: term()
  def camelize_keys(map) when is_map(map) and not is_struct(map) do
    Map.new(map, fn {key, value} ->
      camel_key = camelize_key(key)

      if opaque?(key) do
        {camel_key, value}
      else
        {camel_key, camelize_keys(value)}
      end
    end)
  end

  def camelize_keys(list) when is_list(list) do
    Enum.map(list, &camelize_keys/1)
  end

  def camelize_keys(value), do: value

  @doc """
  Converts a single atom or string key from `snake_case` to
  `camelCase` string form.

  Single-word keys (no underscores) return the word as-is.
  """
  @spec camelize_key(atom() | String.t()) :: String.t()
  def camelize_key(key) when is_atom(key), do: key |> Atom.to_string() |> camelize_key()

  def camelize_key(key) when is_binary(key) do
    case String.split(key, "_") do
      [single] -> single
      [head | tail] -> head <> Enum.map_join(tail, &String.capitalize/1)
    end
  end

  @doc """
  Converts a struct to a camelCase-keyed map suitable for JSON encoding.

  Drops the `__struct__` key, then applies `camelize_keys/1`.
  """
  @spec struct_to_camel_map(struct()) :: map()
  def struct_to_camel_map(struct) do
    struct |> Map.from_struct() |> camelize_keys()
  end

  defp opaque?(key) when is_atom(key), do: MapSet.member?(@opaque_atom_fields, key)
  defp opaque?(key) when is_binary(key), do: MapSet.member?(@opaque_string_fields, key)
end

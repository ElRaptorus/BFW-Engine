defmodule BfwEngine.Persistence.Types.JsonbAny do
  @moduledoc """
  Custom Ash type for JSONB columns that hold any JSON-encodable value,
  not just maps. Used by DataObject and DataObjectWrite `value` fields,
  since DOA FEEL expressions can produce scalars, arrays, or maps.
  """

  use Ash.Type

  @impl true
  def storage_type(_), do: :map

  @impl true
  def cast_input(nil, _), do: {:ok, nil}
  def cast_input(value, _), do: {:ok, value}

  @impl true
  def cast_stored(nil, _), do: {:ok, nil}
  def cast_stored(value, _), do: {:ok, value}

  @impl true
  def dump_to_native(nil, _), do: {:ok, nil}
  def dump_to_native(value, _), do: {:ok, value}

  def graphql_type(_constraints), do: :json
end

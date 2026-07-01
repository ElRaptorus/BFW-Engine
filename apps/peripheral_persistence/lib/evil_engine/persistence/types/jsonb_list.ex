defmodule EvilEngine.Persistence.Types.JsonbList do
  @moduledoc """
  Custom Ash type for JSONB columns that store JSON arrays.

  PostgreSQL `jsonb` holds the entire list as one JSON value (for example
  `[{"process_instance_id": "..."}]`). Ash's built-in `{:array, _}` types
  map to native PostgreSQL array columns (`jsonb[]`, `text[]`), which do
  not match these audit-table columns.
  """

  use Ash.Type

  @impl true
  def storage_type(_), do: :map

  @impl true
  def cast_input(nil, _), do: {:ok, nil}
  def cast_input(value, _) when is_list(value), do: {:ok, value}
  def cast_input(_value, _), do: {:error, "must be a list"}

  @impl true
  def cast_stored(nil, _), do: {:ok, nil}
  def cast_stored(value, _) when is_list(value), do: {:ok, value}
  def cast_stored(value, constraints), do: cast_input(value, constraints)

  @impl true
  def dump_to_native(nil, _), do: {:ok, nil}
  def dump_to_native(value, _) when is_list(value), do: {:ok, value}
  def dump_to_native(_value, _), do: {:error, "must be a list"}

  def graphql_type(_constraints), do: :json
end

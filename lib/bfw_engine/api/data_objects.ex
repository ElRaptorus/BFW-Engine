defmodule BfwEngine.Api.DataObjects do
  @moduledoc """
  Data object reads and writes.
  Callers use `BfwEngine.Api`.
  """

  require Ash.Query

  alias BfwEngine.Persistence.Resources

  @domain BfwEngine.Persistence.Api

  @doc "List current Data Object values (latest per data object) for a process instance."
  @spec list_data_object_values(binary(), keyword()) :: {:ok, list()} | {:error, term()}
  def list_data_object_values(process_instance_id, opts \\ []) do
    Resources.DataObject
    |> Ash.Query.filter(process_instance_id == ^process_instance_id)
    |> Ash.read(Keyword.merge([domain: @domain, authorize?: false], opts))
  end

  @doc "List Data Object history (full audit trail) for a process instance."
  @spec list_data_object_history(binary(), keyword()) :: {:ok, list()} | {:error, term()}
  def list_data_object_history(process_instance_id, opts \\ []) do
    Resources.DataObjectWrite
    |> Ash.Query.filter(process_instance_id == ^process_instance_id)
    |> Ash.read(Keyword.merge([domain: @domain, authorize?: false], opts))
  end

  @doc "Get a single Data Object value by ID."
  @spec get_data_object_value(binary(), keyword()) :: {:ok, struct()} | {:error, term()}
  def get_data_object_value(id, opts \\ []) do
    Ash.get(Resources.DataObject, id, Keyword.merge([domain: @domain, authorize?: false], opts))
  end
end

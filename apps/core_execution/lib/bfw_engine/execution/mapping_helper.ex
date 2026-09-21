defmodule BfwEngine.Execution.MappingHelper do
  @moduledoc """
  Shared helpers for FEEL-based input/output mappings and JSON Schema
  contract validation. Used by CallActivity, ScriptTask, ServiceTask,
  and UserTask handlers to implement the uniform data transformation
  pipeline:

      token -> in_mappings -> payload_contract -> handler -> out_mappings -> result_contract -> downstream
  """

  alias BfwEngine.Expressions
  alias BfwEngine.Expressions.Context, as: FeelContext

  @doc """
  Apply input mappings to transform a token payload into the handler's
  expected input shape. Returns `{:ok, mapped_payload}` or
  `{:error, {:feel_eval_failed, source, reason}}`.

  When `mappings` is empty, returns the original payload unchanged.
  """
  @spec apply_in_mappings([map()], map() | nil, map()) :: {:ok, map()} | {:error, term()}
  def apply_in_mappings([], payload, _context), do: {:ok, payload || %{}}

  def apply_in_mappings(mappings, payload, context) do
    eval_mappings(mappings, payload || %{}, context)
  end

  @doc """
  Apply output mappings to transform a handler's result into the
  downstream token shape. Returns `{:ok, mapped_output}` or
  `{:error, {:feel_eval_failed, source, reason}}`.

  When `mappings` is empty, returns the original payload unchanged.
  """
  @spec apply_out_mappings([map()], map() | nil, map()) :: {:ok, map()} | {:error, term()}
  def apply_out_mappings([], payload, _context), do: {:ok, payload || %{}}

  def apply_out_mappings(mappings, payload, context) do
    eval_mappings(mappings, payload || %{}, context)
  end

  @doc """
  Validate a payload against a JSON Schema contract.

  Returns `:ok` when the contract is nil (no validation) or when the
  payload passes. Returns `{:error, violations}` on failure.
  """
  @spec validate_contract(map() | nil, map()) :: :ok | {:error, term()}
  def validate_contract(nil, _payload), do: :ok

  def validate_contract(contract, payload) when is_map(contract) do
    resolved = ExJsonSchema.Schema.resolve(contract)

    case ExJsonSchema.Validator.validate(resolved, payload) do
      :ok -> :ok
      {:error, errors} -> {:error, errors}
    end
  rescue
    exception ->
      {:error, {:invalid_contract_schema, Exception.message(exception)}}
  end

  defp eval_mappings(mappings, payload, context) do
    feel_context = FeelContext.from_handler_context(context, payload)

    Enum.reduce_while(mappings, {:ok, %{}}, fn mapping, {:ok, acc} ->
      case Expressions.eval(mapping.source, feel_context) do
        {:ok, value} ->
          {:cont, {:ok, Map.put(acc, mapping.target, value)}}

        {:error, reason} ->
          {:halt, {:error, {:feel_eval_failed, mapping.source, reason}}}
      end
    end)
  end
end

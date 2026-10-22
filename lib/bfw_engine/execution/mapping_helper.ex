defmodule BfwEngine.Execution.MappingHelper do
  @moduledoc """
  Shared helpers for FEEL-based input/output mappings and JSON Schema
  contract validation. Used by every handler that implements the uniform
  data transformation pipeline:

      token -> in_mappings -> payload_contract -> handler -> out_mappings -> result_contract -> downstream

  Each step tags its own error, so a mapping failure, a contract violation,
  and a Data Object write failure never share an `error_code`.
  """

  alias BfwEngine.Expressions
  alias BfwEngine.Expressions.Context, as: FeelContext

  @doc """
  Apply input mappings to transform a token payload into the handler's
  expected input shape. Returns `{:ok, mapped_payload}` or
  `{:error, {:in_mapping_failed, {:feel_eval_failed, source, reason}}}`.

  When `mappings` is empty, returns the original payload unchanged.
  """
  @spec apply_in_mappings([map()], map() | nil, map()) :: {:ok, map()} | {:error, term()}
  def apply_in_mappings([], payload, _context), do: {:ok, payload || %{}}

  def apply_in_mappings(mappings, payload, context) do
    eval_mappings(mappings, payload || %{}, context, :in_mapping_failed)
  end

  @doc """
  Apply output mappings to transform a handler's result into the
  downstream token shape. Returns `{:ok, mapped_output}` or
  `{:error, {:out_mapping_failed, {:feel_eval_failed, source, reason}}}`.

  When `mappings` is empty, returns the original payload unchanged.
  """
  @spec apply_out_mappings([map()], map() | nil, map()) :: {:ok, map()} | {:error, term()}
  def apply_out_mappings([], payload, _context), do: {:ok, payload || %{}}

  def apply_out_mappings(mappings, payload, context) do
    eval_mappings(mappings, payload || %{}, context, :out_mapping_failed)
  end

  @doc """
  Build a throw-side outgoing token: the published body merged over the input
  token. When either value is not a map, the outgoing token is the published body.
  """
  @spec merge_over_input(term(), term()) :: term()
  def merge_over_input(input_payload, published_payload)
      when is_map(input_payload) and is_map(published_payload),
      do: Map.merge(input_payload, published_payload)

  def merge_over_input(_input_payload, published_payload), do: published_payload

  @doc """
  Validate a payload against a JSON Schema contract.

  Returns `:ok` when the contract is nil (no validation) or when the
  payload passes. Returns `{:error, violations}` on failure, where
  `violations` is a list of `{message, path}` tuples or
  `{:invalid_contract_schema, message}`.
  """
  @spec validate_contract(term(), map()) :: :ok | {:error, term()}
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

  # The parser keeps any JSON value, so a contract such as `[1]` or `true` reaches here.
  def validate_contract(_contract, _payload) do
    {:error, {:invalid_contract_schema, "a contract must be a JSON object"}}
  end

  @doc """
  Same as `validate_contract/2`, but tags a failure with `error_code`:
  `{:error, {error_code, violations}}`.
  """
  @spec validate_contract(term(), map(), atom()) :: :ok | {:error, {atom(), term()}}
  def validate_contract(contract, payload, error_code) do
    case validate_contract(contract, payload) do
      :ok -> :ok
      {:error, violations} -> {:error, {error_code, violations}}
    end
  end

  defp eval_mappings(mappings, payload, context, error_code) do
    feel_context = FeelContext.from_handler_context(context, payload)

    Enum.reduce_while(mappings, {:ok, %{}}, fn mapping, {:ok, acc} ->
      case Expressions.eval(mapping.source, feel_context) do
        {:ok, value} ->
          {:cont, {:ok, Map.put(acc, mapping.target, value)}}

        {:error, reason} ->
          {:halt, {:error, {error_code, {:feel_eval_failed, mapping.source, reason}}}}
      end
    end)
  end
end

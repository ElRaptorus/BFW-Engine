defmodule EvilEngine.Execution.DataObjectWriter do
  @moduledoc """
  Pure evaluation phase for DOA-driven writes to Data Objects.

  Resolves the DOA target chain, evaluates optional FEEL expressions,
  validates value contracts, and enforces PayloadCap. Returns a list
  of `DataObjectWriteIntent` structs — no DB calls happen here.

  Called from `handle_fni_ok_proceed` in `ProcessInstance`. The
  returned intents are passed to
  `Persistence.finish_fni_with_data_objects/3`, which persists all
  writes atomically together with the FNI state transition.
  """

  require Logger

  alias EvilEngine.BPMN.Model.FlowNode
  alias EvilEngine.Execution.DataObjectWriteIntent
  alias EvilEngine.Execution.HandlerContext
  alias EvilEngine.Execution.MappingHelper
  alias EvilEngine.Execution.PayloadCap
  alias EvilEngine.Expressions
  alias EvilEngine.Expressions.Context, as: FeelContext

  @doc """
  Evaluates all Data Output Associations on the given flow node and returns
  a list of `DataObjectWriteIntent` structs ready for atomic persistence.

  `data_object_cache` is the current in-memory DO cache (map of DO ID -> value).
  `process_model` is the parsed BPMN process model.

  Returns `{:ok, updated_cache, intents}` or `{:error, reason}`.
  """
  @spec prepare_associations(
          flow_node :: FlowNode.t(),
          flow_node_instance_id :: String.t(),
          output_payload :: map(),
          data_object_cache :: %{String.t() => term()},
          process_model :: struct(),
          handler_context :: HandlerContext.t()
        ) :: {:ok, %{String.t() => term()}, [DataObjectWriteIntent.t()]} | {:error, term()}
  def prepare_associations(
        %FlowNode{data_output_associations: []},
        _flow_node_instance_id,
        _output,
        data_object_cache,
        _process_model,
        _handler_context
      ) do
    {:ok, data_object_cache, []}
  end

  def prepare_associations(
        %FlowNode{} = flow_node,
        flow_node_instance_id,
        output_payload,
        data_object_cache,
        process_model,
        handler_context
      ) do
    do_ref_index = build_data_object_ref_index(process_model)
    data_object_index = build_data_object_index(process_model)

    Enum.reduce_while(
      flow_node.data_output_associations,
      {:ok, data_object_cache, []},
      fn association, {:ok, cache, intents} ->
        case evaluate_single_doa(
               association,
               flow_node_instance_id,
               output_payload,
               cache,
               handler_context,
               do_ref_index,
               data_object_index
             ) do
          {:ok, intent} ->
            updated_cache = Map.put(cache, intent.data_object_id, intent.value)
            {:cont, {:ok, updated_cache, intents ++ [intent]}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end
    )
  rescue
    exception ->
      Logger.error("DataObjectWriter crashed: #{Exception.message(exception)}")
      {:error, {:data_object_writer_crash, Exception.message(exception)}}
  end

  defp evaluate_single_doa(
         association,
         flow_node_instance_id,
         output_payload,
         cache,
         handler_context,
         do_ref_index,
         data_object_index
       ) do
    with {:ok, data_object_id} <-
           resolve_target(association.target_ref, do_ref_index, data_object_index),
         {:ok, new_value} <-
           evaluate_value(association.value_expression, output_payload, handler_context),
         :ok <- validate_value_contract(data_object_id, new_value, data_object_index),
         :ok <- check_payload_cap(new_value) do
      previous_value = Map.get(cache, data_object_id)

      intent = %DataObjectWriteIntent{
        data_object_id: data_object_id,
        flow_node_instance_id: flow_node_instance_id,
        process_instance_id: handler_context.process_instance_id,
        previous_value: previous_value,
        value: new_value
      }

      {:ok, intent}
    end
  end

  defp resolve_target(target_ref, do_ref_index, data_object_index) do
    case Map.get(do_ref_index, target_ref) do
      nil ->
        {:error, {:unknown_data_object_reference, target_ref}}

      data_object_ref_id ->
        case Map.get(data_object_index, data_object_ref_id) do
          nil -> {:error, {:unknown_data_object, data_object_ref_id}}
          _data_object -> {:ok, data_object_ref_id}
        end
    end
  end

  defp evaluate_value(nil, output_payload, _handler_context), do: {:ok, output_payload}

  defp evaluate_value(expression, output_payload, handler_context) do
    feel_context = FeelContext.from_handler_context(handler_context, output_payload)

    case Expressions.eval(expression, feel_context) do
      {:ok, value} -> {:ok, value}
      {:error, reason} -> {:error, {:feel_eval_failed, expression, reason}}
    end
  end

  defp validate_value_contract(data_object_id, value, data_object_index) do
    case Map.get(data_object_index, data_object_id) do
      %{value_contract: nil} ->
        :ok

      %{value_contract: contract} when is_map(contract) ->
        case MappingHelper.validate_contract(contract, value) do
          :ok ->
            :ok

          {:error, violations} ->
            {:error, {:value_contract_violation, data_object_id, violations}}
        end

      _ ->
        :ok
    end
  end

  defp check_payload_cap(value) do
    case PayloadCap.check(value, field: :data_object_value) do
      :ok -> :ok
      {:error, :payload_too_large, details} -> {:error, {:payload_too_large, details}}
    end
  end

  defp build_data_object_ref_index(process_model) do
    Map.new(process_model.data_object_references, fn ref ->
      {ref.id, ref.data_object_ref}
    end)
  end

  defp build_data_object_index(process_model) do
    Map.new(process_model.data_objects, fn obj -> {obj.id, obj} end)
  end
end

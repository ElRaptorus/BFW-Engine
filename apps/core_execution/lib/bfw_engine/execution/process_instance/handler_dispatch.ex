defmodule BfwEngine.Execution.ProcessInstance.HandlerDispatch do
  @moduledoc """
  Builds handler contexts and delivers handler results back to the process instance.
  """

  alias BfwEngine.BPMN.Model.FlowNode
  alias BfwEngine.Execution.HandlerContext
  alias BfwEngine.Execution.HandlerDispatch, as: FlowNodeHandlerDispatch
  alias BfwEngine.Expressions.Context, as: FeelContext

  @spec invoke_optional_callback(FlowNode.t() | nil, atom(), list()) :: :ok
  def invoke_optional_callback(flow_node, callback_name, args) do
    with {:ok, handler} <- FlowNodeHandlerDispatch.handler_for(flow_node),
         true <- function_exported?(handler, callback_name, length(args)) do
      apply(handler, callback_name, args)
    end

    :ok
  end

  @spec build_handler_context(struct(), String.t(), FlowNode.t(), pid()) :: HandlerContext.t()
  def build_handler_context(data, flow_node_instance_id, flow_node, process_instance_pid) do
    identity_map =
      case data.identity do
        nil -> %{}
        %{__struct__: _} = identity -> Map.from_struct(identity)
        identity when is_map(identity) -> identity
      end

    process_map =
      case data.process_model do
        nil ->
          %{}

        process_model ->
          %{id: process_model.id, name: process_model.name, version: process_model.version}
      end

    fni_entry = Map.get(data.flow_node_instance_states, flow_node_instance_id, %{})

    loop_overlay =
      case fni_entry do
        %{loop_overlay: overlay} when is_map(overlay) -> overlay
        _ -> nil
      end

    %HandlerContext{
      flow_node_instance_id: flow_node_instance_id,
      process_instance_id: data.process_instance_id,
      root_process_instance_id: data.root_process_instance_id,
      process_version_id: data.process_version_id,
      process_instance_pid: process_instance_pid,
      process_model: data.process_model,
      definitions: data.definitions,
      flow_node_this: FeelContext.flow_node_this(flow_node),
      context: data.started_with_context || %{},
      identity: identity_map,
      process: process_map,
      process_instance: %{
        id: data.process_instance_id,
        started_at: data.started_at,
        started_by: identity_map[:id]
      },
      data_objects: data.data_object_cache,
      loop: loop_overlay,
      multi_instance_id: Map.get(fni_entry, :multi_instance_id),
      iteration_index: Map.get(fni_entry, :iteration_index)
    }
  end

  @spec dispatch_handler_result(pid(), String.t(), term()) :: :ok
  def dispatch_handler_result(
        process_instance_pid,
        flow_node_instance_id,
        {:async, flow_node_instance_id, continuation_function, type_properties}
      )
      when is_function(continuation_function, 0) and is_map(type_properties) do
    send(
      process_instance_pid,
      {:fni_result, flow_node_instance_id, {:async, flow_node_instance_id, type_properties}}
    )

    run_async_continuation(process_instance_pid, flow_node_instance_id, continuation_function)
  end

  def dispatch_handler_result(
        process_instance_pid,
        flow_node_instance_id,
        {:async, flow_node_instance_id, continuation_function}
      )
      when is_function(continuation_function, 0) do
    send(
      process_instance_pid,
      {:fni_result, flow_node_instance_id, {:async, flow_node_instance_id}}
    )

    run_async_continuation(process_instance_pid, flow_node_instance_id, continuation_function)
  end

  def dispatch_handler_result(process_instance_pid, flow_node_instance_id, result) do
    send(process_instance_pid, {:fni_result, flow_node_instance_id, result})
  end

  defp run_async_continuation(process_instance_pid, flow_node_instance_id, continuation_function) do
    receive do
      {:async_gate, :continue} ->
        final_result = continuation_function.()
        send(process_instance_pid, {:fni_result, flow_node_instance_id, final_result})

      {:async_gate, :cancel} ->
        :ok
    end
  end
end

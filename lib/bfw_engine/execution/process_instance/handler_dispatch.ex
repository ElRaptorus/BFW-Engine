defmodule BfwEngine.Execution.ProcessInstance.HandlerDispatch do
  @moduledoc """
  Builds handler contexts and delivers handler results back to the process instance.
  """

  alias BfwEngine.BPMN.Model.FlowNode
  alias BfwEngine.Events.CancelledFlowNodeInstances
  alias BfwEngine.Events.MessageSubscriptions
  alias BfwEngine.Events.SignalSubscriptions
  alias BfwEngine.Execution.HandlerContext
  alias BfwEngine.Execution.HandlerDispatch, as: FlowNodeHandlerDispatch
  alias BfwEngine.Expressions.Context, as: FeelContext

  @handler_kill_wait_ms 1_000

  @doc """
  Kills a handler Task and waits (bounded) until it is down. Call it before
  removing the Task's subscriptions: an exit signal is asynchronous, and a
  Task still running after `Process.exit/2` returned could register a
  subscription, and drain a pending message into it, after the removal.
  Accepts `nil` (no Task). Returns `:ok`.
  """
  @spec kill_handler_task(pid() | nil) :: :ok
  def kill_handler_task(nil), do: :ok

  def kill_handler_task(pid) do
    monitor_reference = Process.monitor(pid)
    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^monitor_reference, :process, ^pid, _reason} -> :ok
    after
      @handler_kill_wait_ms ->
        Process.demonitor(monitor_reference, [:flush])
        :ok
    end
  end

  @doc """
  Ends the handler of a flow node instance the process instance cancels,
  interrupts, aborts, or fatals from outside: marks it in
  `CancelledFlowNodeInstances`, so the handler cannot register again, removes
  every message and signal subscription registered for
  `flow_node_instance_id`, then calls
  `callback_name` (`:handle_aborted` or `:handle_fatal`) through
  `invoke_optional_callback/3`.

  The removal goes by flow node instance id because a handler cancelled
  before its `{:async, …}` result reached the process instance has not
  reported its subscription id yet.
  """
  @spec release_handler(FlowNode.t() | nil, String.t(), :handle_aborted | :handle_fatal, map()) ::
          :ok
  def release_handler(flow_node, flow_node_instance_id, callback_name, entry) do
    CancelledFlowNodeInstances.mark(flow_node_instance_id)
    MessageSubscriptions.unregister_all_for_flow_node_instance(flow_node_instance_id)
    SignalSubscriptions.unregister_all_for_flow_node_instance(flow_node_instance_id)
    invoke_optional_callback(flow_node, callback_name, [entry])
  end

  @doc """
  Calls `callback_name` on the flow node's handler when the handler exports
  it. When the first argument is a Multi-Instance or Standard Loop iteration
  entry, the inner activity's handler receives the call, not the shell's.
  """
  @spec invoke_optional_callback(FlowNode.t() | nil, atom(), list()) :: :ok
  def invoke_optional_callback(flow_node, callback_name, args) do
    with {:ok, handler} <- callback_handler(flow_node, args),
         true <- function_exported?(handler, callback_name, length(args)) do
      apply(handler, callback_name, args)
    end

    :ok
  end

  defp callback_handler(flow_node, [%{multi_instance_id: shell_id} | _rest])
       when is_binary(shell_id),
       do: FlowNodeHandlerDispatch.inner_handler_for(flow_node)

  defp callback_handler(flow_node, _args), do: FlowNodeHandlerDispatch.handler_for(flow_node)

  @doc """
  Registers the calling process instance under `{:fni, flow_node_instance_id}`
  in `BfwEngine.Execution.Registry` when `flow_node` is a Service Task, so
  `finish_async`/`fail_async` find it. Call it before the handler runs: a
  plugin may complete the task before its `handle_enter/3` returned.

  `multi_instance_id` is the shell's flow node instance id for a
  Multi-Instance or Standard Loop iteration, else `nil`. The shell of such a
  loop is not registered: no plugin completes it. Other flow node types are
  left alone. Returns `:ok`.
  """
  @spec register_service_task_completion_route(FlowNode.t(), String.t(), String.t() | nil) :: :ok
  def register_service_task_completion_route(
        %FlowNode{
          type: :service_task,
          multi_instance: multi_instance,
          standard_loop: standard_loop
        },
        flow_node_instance_id,
        multi_instance_id
      )
      when (is_nil(multi_instance) and is_nil(standard_loop)) or is_binary(multi_instance_id) do
    _registration =
      Registry.register(BfwEngine.Execution.Registry, {:fni, flow_node_instance_id}, :async)

    :ok
  end

  def register_service_task_completion_route(
        _flow_node,
        _flow_node_instance_id,
        _multi_instance_id
      ),
      do: :ok

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

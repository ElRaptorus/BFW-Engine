defmodule BfwEngine.Execution.FlowNodes.SignalCatchEvent do
  @moduledoc """
  Handler for `<bpmn:intermediateCatchEvent>` with a Signal event definition.

  Follows the same async handler Task pattern as `MessageCatchEvent`:

  1. `handle_enter/3` registers a subscription in `SignalSubscriptions`
     with `via_pid: self()` and returns `{:async, fni_id, continuation_fn, type_properties}`
  2. The continuation blocks on `receive {:signal_arrived, signal_id}`
  3. On arrival: passes the token through unchanged (signals carry no
     payload), applies `out_mappings` if present (these map the existing
     token, not a signal payload), resolves outgoing flows
  4. Cancellation: the process instance removes the subscription by flow
     node instance id (`HandlerDispatch.release_handler/4`)
  5. `handle_resume/3`: re-register, report the new subscription id, and
     block again
  """

  @behaviour BfwEngine.Execution.FlowNodeHandler

  alias BfwEngine.BPMN.Model.FlowNode
  alias BfwEngine.Events.SignalSubscriptions
  alias BfwEngine.Execution.FlowNodeResult
  alias BfwEngine.Execution.FlowNodes.SignalEventHelper
  alias BfwEngine.Execution.FniLifecycle
  alias BfwEngine.Execution.HandlerContext
  alias BfwEngine.Execution.MappingHelper
  alias BfwEngine.Execution.ProcessInstance.LaneResolution
  alias BfwEngine.Execution.SequenceFlowResolver
  alias BfwEngine.Types.Token

  @impl true
  @spec handle_enter(FlowNode.t(), Token.t(), HandlerContext.t()) ::
          {:async, String.t(), (-> term()), map()} | {:error, term()}
  def handle_enter(flow_node, token, context) do
    with {:ok, signal_name} <-
           SignalEventHelper.resolve_signal_name(flow_node, context.definitions) do
      register_and_wait(flow_node, context, signal_name, token.payload)
    end
  end

  @spec handle_resume(FlowNode.t(), map(), HandlerContext.t()) ::
          {:ok, FlowNodeResult.t()} | {:error, term()}
  def handle_resume(flow_node, entry, context) do
    resume_payload = entry.token.payload || %{}

    with {:ok, signal_name} <-
           SignalEventHelper.resolve_signal_name(flow_node, context.definitions) do
      {:ok, subscription_id} =
        SignalSubscriptions.register(%{
          process_instance_id: context.process_instance_id,
          root_process_instance_id: context.root_process_instance_id,
          flow_node_instance_id: context.flow_node_instance_id,
          flow_node_id: flow_node.id,
          signal_name: signal_name,
          kind: :intermediate_catch,
          via_pid: self(),
          lane_name: LaneResolution.resolve_lane_name_from_context(context, flow_node)
        })

      FniLifecycle.record_resumed_subscription(context, subscription_id)
      send(context.process_instance_pid, {:resume_settled, context.flow_node_instance_id})
      wait_for_signal(flow_node, context, subscription_id, resume_payload)
    end
  end

  # -------------------------------------------------------------------
  # Private: initial enter flow
  # -------------------------------------------------------------------

  defp register_and_wait(flow_node, context, signal_name, token_payload) do
    {:ok, subscription_id} =
      SignalSubscriptions.register(%{
        process_instance_id: context.process_instance_id,
        root_process_instance_id: context.root_process_instance_id,
        flow_node_instance_id: context.flow_node_instance_id,
        flow_node_id: flow_node.id,
        signal_name: signal_name,
        kind: :intermediate_catch,
        via_pid: self(),
        lane_name: LaneResolution.resolve_lane_name_from_context(context, flow_node)
      })

    type_properties = %{
      signal_name: signal_name,
      subscription_id: subscription_id
    }

    case FniLifecycle.park_async(context, type_properties) do
      :ok ->
        continuation = fn ->
          wait_for_signal(flow_node, context, subscription_id, token_payload)
        end

        {:async, context.flow_node_instance_id, continuation,
         Map.put(type_properties, :persisted, true)}

      {:error, :persistence_failed} ->
        SignalSubscriptions.unregister(subscription_id)
        {:error, :persistence_failed}
    end
  end

  defp wait_for_signal(flow_node, context, subscription_id, token_payload) do
    receive do
      {:signal_arrived, _signal_id, triggerer_fni_id} ->
        SignalSubscriptions.unregister(subscription_id)

        out_mappings = Map.get(flow_node.type_data, :out_mappings, [])

        with {:ok, mapped_output} <-
               MappingHelper.apply_out_mappings(out_mappings, token_payload || %{}, context),
             {:ok, next_ids} <- resolve_outgoing(flow_node, context),
             {:ok, lifecycle_result} <-
               FniLifecycle.finish(context, flow_node, mapped_output, %{},
                 triggerer_flow_node_instance_id: triggerer_fni_id
               ) do
          {:ok,
           %FlowNodeResult{
             output_payload: mapped_output,
             next_flow_node_ids: next_ids,
             metadata: %{persisted: true, lifecycle: lifecycle_result}
           }}
        end
    end
  end

  # -------------------------------------------------------------------
  # Private: helpers
  # -------------------------------------------------------------------

  defp resolve_outgoing(flow_node, context) do
    case SequenceFlowResolver.resolve(flow_node, context.process_model) do
      {:ok, targets} -> {:ok, Enum.map(targets, & &1.id)}
      {:error, reason, meta} -> {:error, Map.put(meta, :reason, reason)}
    end
  end
end

defmodule BfwEngine.Execution.FlowNodes.MessageCatchEvent do
  @moduledoc """
  Handler for `<bpmn:intermediateCatchEvent>` with a Message event definition.

  Follows the same async handler Task pattern as `TimerCatchEvent`:

  1. `handle_enter/3` registers a subscription in `MessageSubscriptions`
     with `via_pid: self()` (the handler Task PID) and returns
     `{:async, fni_id, continuation_fn, type_properties}`
  2. The continuation blocks on `receive {:message_arrived, message_id, payload}`
  3. On arrival: validates payload contract, applies output mapping,
     resolves outgoing flows, returns `{:ok, FlowNodeResult}`
  4. `handle_fatal/1` / `handle_aborted/1`: unregister the subscription
  5. `handle_resume/3`: re-register and block again

  The PI has zero message-specific logic — it processes the handler Task's
  result through the generic `{:fni_result, ...}` pipeline.
  """

  @behaviour BfwEngine.Execution.FlowNodeHandler

  alias BfwEngine.BPMN.Model.FlowNode
  alias BfwEngine.Events.MessageSubscriptions
  alias BfwEngine.Execution.FlowNodeResult
  alias BfwEngine.Execution.FlowNodes.MessageEventHelper
  alias BfwEngine.Execution.FniLifecycle
  alias BfwEngine.Execution.HandlerContext
  alias BfwEngine.Execution.MappingHelper
  alias BfwEngine.Execution.ProcessInstance.Helpers
  alias BfwEngine.Execution.SequenceFlowResolver
  alias BfwEngine.Types.Token

  # -------------------------------------------------------------------
  # FlowNodeHandler callbacks
  # -------------------------------------------------------------------

  @doc """
  Resolves the message name, evaluates the process-level correlation key,
  registers a subscription with `MessageSubscriptions`, drains any pending
  messages, and returns an async Task that waits for `{:message_arrived, ...}`.
  Applies output mappings after receipt.
  """
  @spec handle_enter(FlowNode.t(), Token.t(), HandlerContext.t()) ::
          {:async, String.t(), (-> term()), map()} | {:error, term()}
  @impl true
  def handle_enter(flow_node, token, context) do
    event_definition = flow_node.type_data.event_definition

    with {:ok, message_name} <-
           MessageEventHelper.resolve_message_name(flow_node, context.definitions),
         {:ok, expected_correlation_value} <-
           MessageEventHelper.evaluate_correlation_key(
             context.process_model,
             context,
             token.payload
           ) do
      register_and_wait(
        flow_node,
        context,
        message_name,
        expected_correlation_value,
        event_definition
      )
    end
  end

  @impl true
  def handle_fatal(entry) do
    unregister_subscription(entry)
    :ok
  end

  @impl true
  def handle_aborted(entry) do
    unregister_subscription(entry)
    :ok
  end

  # -------------------------------------------------------------------
  # Resume (called by PI during reactivation)
  # -------------------------------------------------------------------

  @spec handle_resume(FlowNode.t(), map(), HandlerContext.t()) ::
          {:ok, FlowNodeResult.t()} | {:error, term()}
  def handle_resume(flow_node, entry, context) do
    event_definition = flow_node.type_data.event_definition

    resume_payload = entry.token.payload || %{}

    with {:ok, message_name} <-
           MessageEventHelper.resolve_message_name(flow_node, context.definitions),
         {:ok, expected_correlation_value} <-
           MessageEventHelper.evaluate_correlation_key(
             context.process_model,
             context,
             resume_payload
           ) do
      {:ok, subscription_id} =
        MessageSubscriptions.register(%{
          process_instance_id: context.process_instance_id,
          root_process_instance_id: context.root_process_instance_id,
          flow_node_instance_id: context.flow_node_instance_id,
          flow_node_id: flow_node.id,
          message_name: message_name,
          expected_correlation_value: expected_correlation_value,
          kind: :intermediate_catch,
          via_pid: self(),
          lane_name: Helpers.resolve_lane_name_from_context(context, flow_node)
        })

      wait_for_message(flow_node, context, event_definition, subscription_id)
    end
  end

  # -------------------------------------------------------------------
  # Private: initial enter flow
  # -------------------------------------------------------------------

  defp register_and_wait(
         flow_node,
         context,
         message_name,
         expected_correlation_value,
         event_definition
       ) do
    {:ok, subscription_id} =
      MessageSubscriptions.register(%{
        process_instance_id: context.process_instance_id,
        root_process_instance_id: context.root_process_instance_id,
        flow_node_instance_id: context.flow_node_instance_id,
        flow_node_id: flow_node.id,
        message_name: message_name,
        expected_correlation_value: expected_correlation_value,
        kind: :intermediate_catch,
        via_pid: self(),
        lane_name: Helpers.resolve_lane_name_from_context(context, flow_node)
      })

    type_properties = %{
      message_name: message_name,
      subscription_id: subscription_id,
      expected_correlation_value: normalize_correlation(expected_correlation_value)
    }

    case FniLifecycle.park_async(context, type_properties) do
      :ok ->
        continuation = fn ->
          wait_for_message(flow_node, context, event_definition, subscription_id)
        end

        {:async, context.flow_node_instance_id, continuation,
         Map.put(type_properties, :persisted, true)}

      {:error, :persistence_failed} ->
        {:error, :persistence_failed}
    end
  end

  defp wait_for_message(flow_node, context, _event_definition, subscription_id) do
    receive do
      {:message_arrived, _message_id, payload, triggerer_fni_id} ->
        MessageSubscriptions.unregister(subscription_id)

        out_mappings = Map.get(flow_node.type_data, :out_mappings, [])

        with :ok <-
               MappingHelper.validate_contract(flow_node.type_data.result_contract, payload),
             {:ok, mapped_output} <-
               MappingHelper.apply_out_mappings(out_mappings, payload, context),
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
        else
          {:error, violations} when is_list(violations) ->
            {:error, %{reason: :result_contract_violation, violations: violations}}

          {:error, _reason} = error ->
            error
        end
    end
  end

  # -------------------------------------------------------------------
  # Private: cleanup
  # -------------------------------------------------------------------

  defp unregister_subscription(entry) do
    type_props = entry.type_properties || %{}

    subscription_id =
      Map.get(type_props, :subscription_id) || Map.get(type_props, "subscription_id")

    if subscription_id do
      MessageSubscriptions.unregister(subscription_id)
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

  defp normalize_correlation(:none), do: nil
  defp normalize_correlation(value), do: value
end

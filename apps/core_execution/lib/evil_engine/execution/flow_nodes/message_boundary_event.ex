defmodule EvilEngine.Execution.FlowNodes.MessageBoundaryEvent do
  @moduledoc """
  Handler for `<bpmn:boundaryEvent>` with a Message event definition.

  Follows the same subscription-model boundary pattern as `TimerBoundaryEvent`:

  1. `handle_enter/3` registers a subscription in `MessageSubscriptions`
     and returns `{:async, fni_id, continuation_fn, type_properties}`
  2. The continuation blocks on `receive {:message_arrived, ...}`

  ### Interrupting vs non-interrupting

  - **Interrupting** (`cancel_activity: true`): Fires once. Returns
    `{:boundary, ...}` which finishes the boundary FNI, interrupts the
    host, and cancels sibling boundaries.
  - **Non-interrupting** (`cancel_activity: false`): Loops. Each message
    arrival sends `{:boundary_cycle_fire, ...}` to the PI, which spawns
    a parallel branch from the boundary's outgoing path without finishing
    the boundary FNI. The handler re-registers and blocks again. The
    loop only exits when the PI kills the handler Task via
    `cancel_boundary_fnis_for_host` on host completion.
  """

  @behaviour EvilEngine.Execution.FlowNodeHandler

  alias EvilEngine.BPMN.Model.FlowNode
  alias EvilEngine.Events.MessageSubscriptions
  alias EvilEngine.Execution.FlowNodes.MessageEventHelper
  alias EvilEngine.Execution.FniLifecycle
  alias EvilEngine.Execution.HandlerContext
  alias EvilEngine.Execution.MappingHelper
  alias EvilEngine.Execution.ProcessInstance.Helpers
  alias EvilEngine.Types.Token

  # -------------------------------------------------------------------
  # FlowNodeHandler callbacks
  # -------------------------------------------------------------------

  @spec handle_enter(FlowNode.t(), Token.t(), HandlerContext.t()) ::
          {:async, String.t(), (-> term()), map()} | {:error, term()}
  @impl true
  def handle_enter(flow_node, token, context) do
    cancel_activity = flow_node.type_data.cancel_activity
    host_fni_id = context.host_flow_node_instance_id

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
        cancel_activity,
        host_fni_id,
        token.payload
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
          {:boundary, String.t(), term(), boolean()} | {:error, term()}
  def handle_resume(flow_node, entry, context) do
    type_props = entry.type_properties || %{}
    cancel_activity = resolve_cancel_activity(type_props, flow_node)

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
          kind: :boundary,
          via_pid: self(),
          lane_name: Helpers.resolve_lane_name_from_context(context, flow_node)
        })

      if cancel_activity do
        wait_for_message_once(flow_node, context, subscription_id)
      else
        message_receive_loop(
          context.process_instance_pid,
          context.flow_node_instance_id,
          flow_node,
          context,
          message_name,
          expected_correlation_value,
          subscription_id
        )
      end
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
         cancel_activity,
         host_fni_id,
         _token_payload
       ) do
    {:ok, subscription_id} =
      MessageSubscriptions.register(%{
        process_instance_id: context.process_instance_id,
        root_process_instance_id: context.root_process_instance_id,
        flow_node_instance_id: context.flow_node_instance_id,
        flow_node_id: flow_node.id,
        message_name: message_name,
        expected_correlation_value: expected_correlation_value,
        kind: :boundary,
        via_pid: self(),
        lane_name: Helpers.resolve_lane_name_from_context(context, flow_node)
      })

    type_properties = %{
      host_flow_node_instance_id: host_fni_id,
      cancel_activity: cancel_activity,
      message_name: message_name,
      subscription_id: subscription_id,
      expected_correlation_value: normalize_correlation(expected_correlation_value)
    }

    case FniLifecycle.park_async(context, type_properties) do
      :ok ->
        continuation =
          build_message_continuation(
            flow_node,
            context,
            message_name,
            expected_correlation_value,
            cancel_activity,
            subscription_id
          )

        {:async, context.flow_node_instance_id, continuation,
         Map.put(type_properties, :persisted, true)}

      {:error, :persistence_failed} ->
        {:error, :persistence_failed}
    end
  end

  defp build_message_continuation(
         flow_node,
         context,
         _message_name,
         _correlation,
         true = _cancel,
         subscription_id
       ) do
    fn -> wait_for_message_once(flow_node, context, subscription_id) end
  end

  defp build_message_continuation(
         flow_node,
         context,
         message_name,
         expected_correlation_value,
         false = _cancel,
         subscription_id
       ) do
    fn ->
      message_receive_loop(
        context.process_instance_pid,
        context.flow_node_instance_id,
        flow_node,
        context,
        message_name,
        expected_correlation_value,
        subscription_id
      )
    end
  end

  # -------------------------------------------------------------------
  # Interrupting: fire once, finish the boundary FNI
  # -------------------------------------------------------------------

  defp wait_for_message_once(flow_node, context, subscription_id) do
    receive do
      {:message_arrived, _message_id, payload, triggerer_fni_id} ->
        MessageSubscriptions.unregister(subscription_id)

        with :ok <-
               MappingHelper.validate_contract(flow_node.type_data.result_contract, payload),
             {:ok, mapped_payload} <- apply_output_mappings(flow_node, context, payload) do
          {:boundary, flow_node.id, mapped_payload, true, triggerer_fni_id}
        else
          {:error, violations} when is_list(violations) ->
            {:error, %{reason: :result_contract_violation, violations: violations}}

          {:error, _reason} = error ->
            error
        end
    end
  end

  # -------------------------------------------------------------------
  # Non-interrupting: loop, re-subscribe after each fire
  # -------------------------------------------------------------------

  defp message_receive_loop(
         process_instance_pid,
         flow_node_instance_id,
         flow_node,
         context,
         message_name,
         expected_correlation_value,
         current_subscription_id
       ) do
    receive do
      {:message_arrived, _message_id, payload, triggerer_fni_id} ->
        MessageSubscriptions.unregister(current_subscription_id)

        with :ok <-
               MappingHelper.validate_contract(flow_node.type_data.result_contract, payload),
             {:ok, mapped_payload} <- apply_output_mappings(flow_node, context, payload) do
          send(
            process_instance_pid,
            {:fni_result, flow_node_instance_id,
             {:boundary_cycle_fire, flow_node.id, mapped_payload, false, triggerer_fni_id}}
          )

          {:ok, new_subscription_id} =
            MessageSubscriptions.register(%{
              process_instance_id: context.process_instance_id,
              root_process_instance_id: context.root_process_instance_id,
              flow_node_instance_id: context.flow_node_instance_id,
              flow_node_id: flow_node.id,
              message_name: message_name,
              expected_correlation_value: expected_correlation_value,
              kind: :boundary,
              via_pid: self(),
              lane_name: Helpers.resolve_lane_name_from_context(context, flow_node)
            })

          type_properties = %{
            host_flow_node_instance_id: context.host_flow_node_instance_id,
            cancel_activity: false,
            message_name: message_name,
            subscription_id: new_subscription_id,
            expected_correlation_value: normalize_correlation(expected_correlation_value)
          }

          case persist_live_subscription(
                 context,
                 type_properties,
                 new_subscription_id,
                 &MessageSubscriptions.unregister/1
               ) do
            :ok ->
              message_receive_loop(
                process_instance_pid,
                flow_node_instance_id,
                flow_node,
                context,
                message_name,
                expected_correlation_value,
                new_subscription_id
              )

            {:error, :persistence_failed} = error ->
              error
          end
        else
          {:error, violations} when is_list(violations) ->
            {:error, %{reason: :result_contract_violation, violations: violations}}

          {:error, _reason} = error ->
            error
        end
    end
  end

  # -------------------------------------------------------------------
  # Private: output mappings
  # -------------------------------------------------------------------

  defp apply_output_mappings(flow_node, context, payload) do
    out_mappings = Map.get(flow_node.type_data, :out_mappings, [])
    MappingHelper.apply_out_mappings(out_mappings, payload, context)
  end

  # -------------------------------------------------------------------
  # Private: cleanup
  # -------------------------------------------------------------------

  defp persist_live_subscription(context, type_properties, subscription_id, unregister_fun) do
    case FniLifecycle.park_async(context, type_properties) do
      :ok ->
        notify_process_instance_of_subscription(context, type_properties)
        :ok

      {:error, :persistence_failed} = error ->
        unregister_fun.(subscription_id)
        error
    end
  end

  defp notify_process_instance_of_subscription(context, type_properties) do
    if is_pid(context.process_instance_pid) do
      send(
        context.process_instance_pid,
        {:fni_merge_type_properties, context.flow_node_instance_id, type_properties}
      )
    end
  end

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

  defp resolve_cancel_activity(type_props, flow_node) do
    case Map.get(type_props, :cancel_activity) || Map.get(type_props, "cancel_activity") do
      nil -> flow_node.type_data.cancel_activity
      value -> value
    end
  end

  defp normalize_correlation(:none), do: nil
  defp normalize_correlation(value), do: value
end

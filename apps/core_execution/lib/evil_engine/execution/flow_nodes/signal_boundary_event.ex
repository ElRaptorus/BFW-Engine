defmodule EvilEngine.Execution.FlowNodes.SignalBoundaryEvent do
  @moduledoc """
  Handler for `<bpmn:boundaryEvent>` with a Signal event definition.

  Follows the same subscription-model boundary pattern as `MessageBoundaryEvent`:

  1. `handle_enter/3` registers a subscription in `SignalSubscriptions`
     and returns `{:async, fni_id, continuation_fn, type_properties}`
  2. The continuation blocks on `receive {:signal_arrived, ...}`

  ### Interrupting vs non-interrupting

  - **Interrupting** (`cancel_activity: true`): Fires once. Returns
    `{:boundary, ...}` which finishes the boundary FNI, interrupts
    the host, and cancels sibling boundaries.
  - **Non-interrupting** (`cancel_activity: false`): Loops. Each signal
    arrival sends `{:boundary_cycle_fire, ...}` to the PI, which spawns
    a parallel branch from the boundary's outgoing path without finishing
    the boundary FNI. The handler re-registers and blocks again. The
    loop only exits when the PI kills the handler Task via
    `cancel_boundary_fnis_for_host` on host completion.

  Signals carry no payload — the token passes through unchanged. Output
  mappings, if present, transform the existing token (not a signal payload).
  """

  @behaviour EvilEngine.Execution.FlowNodeHandler

  alias EvilEngine.BPMN.Model.FlowNode
  alias EvilEngine.Events.SignalSubscriptions
  alias EvilEngine.Execution.FlowNodes.SignalEventHelper
  alias EvilEngine.Execution.FniLifecycle
  alias EvilEngine.Execution.HandlerContext
  alias EvilEngine.Execution.MappingHelper
  alias EvilEngine.Types.Token

  @impl true
  @spec handle_enter(FlowNode.t(), Token.t(), HandlerContext.t()) ::
          {:async, String.t(), (-> term()), map()} | {:error, term()}
  def handle_enter(flow_node, token, context) do
    cancel_activity = flow_node.type_data.cancel_activity
    host_fni_id = context.host_flow_node_instance_id

    with {:ok, signal_name} <-
           SignalEventHelper.resolve_signal_name(flow_node, context.definitions) do
      register_and_wait(
        flow_node,
        context,
        signal_name,
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

  @spec handle_resume(FlowNode.t(), map(), HandlerContext.t()) ::
          {:boundary, String.t(), term(), boolean()} | {:error, term()}
  def handle_resume(flow_node, entry, context) do
    type_props = entry.type_properties || %{}
    cancel_activity = resolve_cancel_activity(type_props, flow_node)

    resume_payload = entry.token.payload || %{}

    with {:ok, signal_name} <-
           SignalEventHelper.resolve_signal_name(flow_node, context.definitions) do
      {:ok, subscription_id} =
        SignalSubscriptions.register(%{
          process_instance_id: context.process_instance_id,
          flow_node_instance_id: context.flow_node_instance_id,
          flow_node_id: flow_node.id,
          signal_name: signal_name,
          kind: :boundary,
          via_pid: self()
        })

      if cancel_activity do
        wait_for_signal_once(flow_node, context, subscription_id, resume_payload)
      else
        signal_receive_loop(
          context.process_instance_pid,
          context.flow_node_instance_id,
          flow_node,
          context,
          signal_name,
          resume_payload,
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
         signal_name,
         cancel_activity,
         host_fni_id,
         token_payload
       ) do
    {:ok, subscription_id} =
      SignalSubscriptions.register(%{
        process_instance_id: context.process_instance_id,
        flow_node_instance_id: context.flow_node_instance_id,
        flow_node_id: flow_node.id,
        signal_name: signal_name,
        kind: :boundary,
        via_pid: self()
      })

    type_properties = %{
      host_flow_node_instance_id: host_fni_id,
      cancel_activity: cancel_activity,
      signal_name: signal_name,
      subscription_id: subscription_id
    }

    case FniLifecycle.park_async(context, type_properties) do
      :ok ->
        continuation =
          build_signal_continuation(
            flow_node,
            context,
            signal_name,
            cancel_activity,
            token_payload,
            subscription_id
          )

        {:async, context.flow_node_instance_id, continuation,
         Map.put(type_properties, :persisted, true)}

      {:error, :persistence_failed} ->
        {:error, :persistence_failed}
    end
  end

  defp build_signal_continuation(
         flow_node,
         context,
         _signal_name,
         true = _cancel,
         token_payload,
         subscription_id
       ) do
    fn -> wait_for_signal_once(flow_node, context, subscription_id, token_payload) end
  end

  defp build_signal_continuation(
         flow_node,
         context,
         signal_name,
         false = _cancel,
         token_payload,
         subscription_id
       ) do
    fn ->
      signal_receive_loop(
        context.process_instance_pid,
        context.flow_node_instance_id,
        flow_node,
        context,
        signal_name,
        token_payload,
        subscription_id
      )
    end
  end

  # -------------------------------------------------------------------
  # Interrupting: fire once, finish the boundary FNI
  # -------------------------------------------------------------------

  defp wait_for_signal_once(flow_node, context, subscription_id, token_payload) do
    receive do
      {:signal_arrived, _signal_id, triggerer_fni_id} ->
        SignalSubscriptions.unregister(subscription_id)

        case apply_output_mappings(flow_node, context, token_payload) do
          {:ok, mapped_payload} ->
            {:boundary, flow_node.id, mapped_payload, true, triggerer_fni_id}

          {:error, _reason} = error ->
            error
        end
    end
  end

  # -------------------------------------------------------------------
  # Non-interrupting: loop, re-subscribe after each fire
  # -------------------------------------------------------------------

  defp signal_receive_loop(
         process_instance_pid,
         flow_node_instance_id,
         flow_node,
         context,
         signal_name,
         token_payload,
         current_subscription_id
       ) do
    receive do
      {:signal_arrived, _signal_id, triggerer_fni_id} ->
        SignalSubscriptions.unregister(current_subscription_id)

        case apply_output_mappings(flow_node, context, token_payload) do
          {:ok, mapped_payload} ->
            send(
              process_instance_pid,
              {:fni_result, flow_node_instance_id,
               {:boundary_cycle_fire, flow_node.id, mapped_payload, false, triggerer_fni_id}}
            )

            {:ok, new_subscription_id} =
              SignalSubscriptions.register(%{
                process_instance_id: context.process_instance_id,
                flow_node_instance_id: context.flow_node_instance_id,
                flow_node_id: flow_node.id,
                signal_name: signal_name,
                kind: :boundary,
                via_pid: self()
              })

            signal_receive_loop(
              process_instance_pid,
              flow_node_instance_id,
              flow_node,
              context,
              signal_name,
              token_payload,
              new_subscription_id
            )

          {:error, _reason} = error ->
            error
        end
    end
  end

  # -------------------------------------------------------------------
  # Private: output mappings
  # -------------------------------------------------------------------

  defp apply_output_mappings(flow_node, context, token_payload) do
    out_mappings = Map.get(flow_node.type_data, :out_mappings, [])
    MappingHelper.apply_out_mappings(out_mappings, token_payload || %{}, context)
  end

  # -------------------------------------------------------------------
  # Private: cleanup
  # -------------------------------------------------------------------

  defp unregister_subscription(entry) do
    type_props = entry.type_properties || %{}

    subscription_id =
      Map.get(type_props, :subscription_id) || Map.get(type_props, "subscription_id")

    if subscription_id do
      SignalSubscriptions.unregister(subscription_id)
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
end

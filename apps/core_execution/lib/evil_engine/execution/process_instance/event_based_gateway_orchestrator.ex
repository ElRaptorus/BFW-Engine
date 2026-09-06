defmodule EvilEngine.Execution.ProcessInstance.EventBasedGatewayOrchestrator do
  @moduledoc """
  Interrupts sibling catch-event FNIs when one branch of an event-based gateway wins.

  Siblings that are already `:waiting` are interrupted immediately. Siblings
  still `:active` (handler `handle_enter/3` in flight, often mid-persist) are
  only stamped with `:ebg_pending_cancel`. Killing those Tasks would race the
  enter-path persist and can stall the process instance. The PI finalizes the
  stamp once the loser reports `{:async}` / `{:wait}` / `{:ok}`.
  """

  alias EvilEngine.Execution.FniLifecycle
  alias EvilEngine.Execution.ProcessInstance.Helpers

  @pending_cancel_reason "event_based_gateway_sibling_cancelled"

  @doc """
  When a catch event spawned from an event-based gateway completes, interrupt
  every other waiting sibling that shares the same gateway predecessor, and
  stamp still-entering (`:active`) siblings for deferred interrupt.
  """
  @spec cancel_sibling_catch_flow_node_instances(struct(), String.t()) :: struct()
  def cancel_sibling_catch_flow_node_instances(data, winning_flow_node_instance_id) do
    with %{previous_flow_node_instance_ids: [gateway_flow_node_instance_id | _]} <-
           Map.get(data.flow_node_instance_states, winning_flow_node_instance_id),
         %{flow_node_id: gateway_flow_node_id} <-
           Map.get(data.flow_node_instance_states, gateway_flow_node_instance_id),
         gateway_flow_node when not is_nil(gateway_flow_node) <-
           Helpers.find_flow_node(data, gateway_flow_node_id),
         true <- gateway_flow_node.type == :event_based_gateway do
      cancel_siblings(data, gateway_flow_node_instance_id, winning_flow_node_instance_id)
    else
      _ -> data
    end
  end

  @doc """
  True when this FNI was stamped as an Event-Based Gateway loser while its
  handler was still entering.
  """
  @spec pending_cancel?(map()) :: boolean()
  def pending_cancel?(entry) when is_map(entry) do
    type_properties = Map.get(entry, :type_properties) || %{}

    Map.get(type_properties, :ebg_pending_cancel) == true or
      Map.get(type_properties, "ebg_pending_cancel") == true
  end

  def pending_cancel?(_entry), do: false

  @doc """
  Interrupt a sibling that finished entering after the gateway already had a
  winner. No-op when the FNI is missing, already terminal, or not stamped.
  """
  @spec interrupt_pending_loser(struct(), String.t()) :: struct()
  def interrupt_pending_loser(data, flow_node_instance_id) do
    case Map.get(data.flow_node_instance_states, flow_node_instance_id) do
      %{state: state} = entry when state in [:active, :waiting] ->
        if pending_cancel?(entry) do
          interrupt_one(data, flow_node_instance_id, entry)
        else
          data
        end

      _other ->
        data
    end
  end

  defp cancel_siblings(data, gateway_flow_node_instance_id, winning_flow_node_instance_id) do
    data.flow_node_instance_states
    |> Enum.filter(fn {flow_node_instance_id, entry} ->
      flow_node_instance_id != winning_flow_node_instance_id and
        entry.state in [:active, :waiting] and
        gateway_flow_node_instance_id in entry.previous_flow_node_instance_ids
    end)
    |> Enum.reduce(data, fn {sibling_flow_node_instance_id, entry}, accumulator ->
      case entry.state do
        :waiting ->
          interrupt_one(accumulator, sibling_flow_node_instance_id, entry)

        :active ->
          stamp_pending_cancel(accumulator, sibling_flow_node_instance_id, entry)
      end
    end)
  end

  defp stamp_pending_cancel(data, flow_node_instance_id, entry) do
    type_properties =
      Map.put(entry.type_properties || %{}, :ebg_pending_cancel, true)

    put_in(data.flow_node_instance_states[flow_node_instance_id], %{
      entry
      | type_properties: type_properties
    })
  end

  defp interrupt_one(data, flow_node_instance_id, entry) do
    graceful_kill_handler(entry.pid)

    flow_node = Helpers.find_flow_node(data, entry.flow_node_id)
    Helpers.invoke_optional_callback(flow_node, :handle_aborted, [entry])

    _persist_result =
      FniLifecycle.transition_to_interrupted(
        flow_node_instance_id,
        data.process_instance_id,
        @pending_cancel_reason,
        flow_node,
        Map.get(entry, :type_properties, %{}),
        Helpers.resolve_lane_name(data.process_model, flow_node),
        data.root_process_instance_id
      )

    data = %{
      data
      | conditional_waiters: Map.delete(data.conditional_waiters, flow_node_instance_id)
    }

    put_in(data.flow_node_instance_states[flow_node_instance_id], %{
      entry
      | state: :interrupted,
        pid: nil
    })
  end

  @graceful_kill_timeout_ms 200

  defp graceful_kill_handler(nil), do: :ok

  defp graceful_kill_handler(pid) do
    reference = Process.monitor(pid)
    Process.exit(pid, :shutdown)

    receive do
      {:DOWN, ^reference, :process, ^pid, _reason} -> :ok
    after
      @graceful_kill_timeout_ms ->
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^reference, :process, ^pid, _reason} -> :ok
        after
          100 -> Process.demonitor(reference, [:flush])
        end
    end
  end
end

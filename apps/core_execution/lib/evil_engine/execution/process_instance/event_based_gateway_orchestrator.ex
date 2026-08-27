defmodule EvilEngine.Execution.ProcessInstance.EventBasedGatewayOrchestrator do
  @moduledoc """
  Interrupts sibling catch-event FNIs when one branch of an event-based gateway wins.
  """

  alias EvilEngine.Execution.FniLifecycle
  alias EvilEngine.Execution.ProcessInstance.Helpers

  @doc """
  When a catch event spawned from an event-based gateway completes, interrupt
  every other active or waiting sibling that shares the same gateway predecessor.
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

  defp cancel_siblings(data, gateway_flow_node_instance_id, winning_flow_node_instance_id) do
    data.flow_node_instance_states
    |> Enum.filter(fn {flow_node_instance_id, entry} ->
      flow_node_instance_id != winning_flow_node_instance_id and
        entry.state in [:active, :waiting] and
        gateway_flow_node_instance_id in entry.previous_flow_node_instance_ids
    end)
    |> Enum.reduce(data, fn {sibling_flow_node_instance_id, entry}, accumulator ->
      graceful_kill_handler(entry.pid)

      flow_node = Helpers.find_flow_node(accumulator, entry.flow_node_id)
      Helpers.invoke_optional_callback(flow_node, :handle_aborted, [entry])

      _persist_result =
        FniLifecycle.transition_to_interrupted(
          sibling_flow_node_instance_id,
          accumulator.process_instance_id,
          "event_based_gateway_sibling_cancelled",
          flow_node,
          Map.get(entry, :type_properties, %{}),
          Helpers.resolve_lane_name(accumulator.process_model, flow_node),
          accumulator.root_process_instance_id
        )

      accumulator =
        %{
          accumulator
          | conditional_waiters:
              Map.delete(accumulator.conditional_waiters, sibling_flow_node_instance_id)
        }

      put_in(accumulator.flow_node_instance_states[sibling_flow_node_instance_id], %{
        entry
        | state: :interrupted,
          pid: nil
      })
    end)
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

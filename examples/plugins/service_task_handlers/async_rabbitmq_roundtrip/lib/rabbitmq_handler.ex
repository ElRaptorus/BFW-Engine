defmodule Examples.ServiceTaskHandlers.RabbitmqRoundtrip.RabbitmqHandler do
  @moduledoc """
  Publishes a work message to RabbitMQ with `correlation_id` equal to the Flow Node
  Instance id, then returns `{:async, flow_node_instance_id}`.
  """

  @behaviour BfwEngine.Plugin.ServiceTaskHandler

  @doc "Publishes a work message keyed by the flow node instance id and returns {:async, id} for the parked task."
  @impl true
  def handle_enter(_flow_node, token, handler_context) do
    flow_node_instance_id = handler_context.flow_node_instance_id
    payload_map = Map.get(token.payload, "message", token.payload)

    publish_outbound_message(flow_node_instance_id, payload_map)

    {:async, flow_node_instance_id}
  end

  defp publish_outbound_message(flow_node_instance_id, payload_map) do
    # TODO: replace with AMQP.Basic.publish(channel, exchange, routing_key, payload, correlation_id: flow_node_instance_id)
    correlation_id = flow_node_instance_id
    publish_options = %{correlation_id: correlation_id, payload: payload_map}

    case Process.get(:examples_rabbitmq_roundtrip_capture) do
      capture_process when is_pid(capture_process) ->
        send(capture_process, {:published, publish_options})

      _ ->
        :ok
    end
  end
end

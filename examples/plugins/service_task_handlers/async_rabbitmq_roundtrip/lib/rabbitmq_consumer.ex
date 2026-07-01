defmodule Examples.ServiceTaskHandlers.RabbitmqRoundtrip.RabbitmqConsumer do
  @moduledoc """
  GenServer template for a reply queue consumer that finishes parked Service Tasks.

  Wire `handle_info/2` to your AMQP client's delivery messages. The stub clause
  below mirrors what you would emit once `AMQP.Basic.consume/4` is configured.
  """

  use GenServer

  @doc "Starts the consumer GenServer holding the facade needed to finish async tasks when replies arrive."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) do
    facade = Keyword.fetch!(options, :facade)
    GenServer.start_link(__MODULE__, %{facade: facade}, [])
  end

  @doc "Sends a synthetic inbound reply through the same code path tests use to simulate AMQP delivery."
  @spec simulate_inbound_reply(GenServer.server(), String.t(), map()) :: :ok
  def simulate_inbound_reply(server, flow_node_instance_id, result_map) do
    GenServer.cast(server, {:simulated_inbound_reply, flow_node_instance_id, result_map})
  end

  @doc "Keeps only the facade reference in state until AMQP or test messages arrive."
  @impl true
  def init(state), do: {:ok, state}

  @doc "Parses a stubbed RabbitMQ delivery and finishes or fails the matching async service task."
  @impl true
  def handle_info({:basic_deliver, _channel, _delivery_tag, metadata, body}, state) do
    # TODO: replace envelope parsing with AMQP.Basic.ack/ack_async and your library's metadata shape
    flow_node_instance_id = Map.get(metadata, :correlation_id) || Map.get(metadata, "correlation_id")
    decoded_reply = Jason.decode(body)

    cond do
      not is_binary(flow_node_instance_id) ->
        :ok

      match?({:ok, reply_map} when is_map(reply_map), decoded_reply) ->
        {:ok, result_map} = decoded_reply
        _ = state.facade.service_tasks.finish_async.(flow_node_instance_id, result_map)

      true ->
        _ =
          state.facade.service_tasks.fail_async.(
            flow_node_instance_id,
            "RABBITMQ_REPLY_INVALID",
            "Reply payload was not a JSON object"
          )
    end

    {:noreply, state}
  end

  @doc "Completes the async service task directly when tests simulate an inbound reply."
  @impl true
  def handle_cast({:simulated_inbound_reply, flow_node_instance_id, result_map}, state) do
    _ = state.facade.service_tasks.finish_async.(flow_node_instance_id, result_map)
    {:noreply, state}
  end
end

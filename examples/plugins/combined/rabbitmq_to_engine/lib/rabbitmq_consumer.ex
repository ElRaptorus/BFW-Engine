defmodule Examples.Plugins.Combined.RabbitmqToEngine.RabbitmqConsumer do
  @moduledoc """
  Background consumer that translates external queue messages into engine starts.

  AMQP connectivity is intentionally stubbed; swap the marked sections for a real
  client when wiring to RabbitMQ.
  """

  use GenServer

  require Logger

  alias BfwEngine.Types.Identity
  alias Examples.Plugins.Combined.RabbitmqToEngine.{FacadeStore, OrchestratorCustomEvent}

  @doc "Prepares consumer state with a placeholder connection until a real AMQP client is wired in."
  @impl true
  def init(options) do
    _engine_facade = Keyword.fetch!(options, :engine_facade)

    # credo:disable-for-next-line Credo.Check.Design.TagTODO
    # TODO: replace with AMQP.Connection.open(...)
    connection_stub = :not_connected

    {:ok, %{connection: connection_stub}}
  end

  @doc "Dispatches engine starts from test or AMQP-shaped messages when the facade is present, otherwise ignores or passes through unrelated messages."
  @impl true
  def handle_info({:deliver_test_message, message_body}, state) do
    engine_facade = FacadeStore.get()

    if engine_facade == nil do
      Logger.error("rabbitmq_orchestrator: missing facade in FacadeStore")
      {:noreply, state}
    else
      dispatch_outcome = dispatch_engine_start_from_body(engine_facade, message_body)
      Logger.debug("rabbitmq_orchestrator: dispatch_outcome=#{inspect(dispatch_outcome)}")
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:basic_deliver, _consumer_tag, _delivery_tag, _redelivered?, _exchange, _routing_key, body}, state) do
    engine_facade = FacadeStore.get()

    if engine_facade == nil do
      Logger.error("rabbitmq_orchestrator: missing facade in FacadeStore")
      {:noreply, state}
    else
      _result = dispatch_engine_start_from_body(engine_facade, body)
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(_message, state), do: {:noreply, state}

  @doc "Starts the GenServer, optionally registering it under a provided name."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) do
    {registration_name, server_options} = Keyword.pop(options, :name)

    if registration_name != nil do
      GenServer.start_link(__MODULE__, server_options, name: registration_name)
    else
      GenServer.start_link(__MODULE__, server_options)
    end
  end

  defp dispatch_engine_start_from_body(engine_facade, message_body) when is_binary(message_body) do
    parsed_map = Jason.decode!(message_body)
    process_model_id = Map.fetch!(parsed_map, "process_model_id")
    initial_payload = Map.get(parsed_map, "payload", %{})
    plugin_identity = plugin_synthetic_identity()

    with {:ok, process_version} <- engine_facade.processes.get_latest_version.(process_model_id),
         process_instance_identifier <- generate_process_instance_identifier(),
         start_arguments <- [
           process_instance_id: process_instance_identifier,
           process_version_id: process_version.id,
           payload: initial_payload,
           identity: plugin_identity
         ],
         {:ok, _process_instance_pid} <- engine_facade.processes.start.(start_arguments) do
      published_event = %OrchestratorCustomEvent{
        type: "orchestrator:process_started",
        process_model_id: process_model_id,
        process_instance_id: process_instance_identifier,
        payload: initial_payload,
        timestamp: DateTime.utc_now()
      }

      engine_facade.publish_event.(published_event)
      :ok
    end
  end

  defp plugin_synthetic_identity do
    %Identity{
      id: "plugin:rabbitmq-orchestrator-example",
      roles: ["plugin"],
      groups: []
    }
  end

  defp generate_process_instance_identifier do
    random_bytes = :crypto.strong_rand_bytes(16)
    "pi-orchestrator-" <> Base.encode16(random_bytes, case: :lower)
  end
end

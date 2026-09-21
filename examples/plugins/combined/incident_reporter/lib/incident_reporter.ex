defmodule IncidentReporter do
  @moduledoc """
  Reference plugin demonstrating end-to-end integration of the engine's
  retry API with external incident management systems via a message bus.

  ## Architecture

  ```
  Engine ─→ EventSink ─→ Bus ─→ External System
                                       │
  Engine ←─ RetryConsumer ←─ Bus ←─────┘
  ```

  The plugin has two halves:

  1. **EventSink** — publishes structured incident reports when a Process
     Instance transitions to `fatal` or `aborted`.
  2. **RetryConsumer** — listens for retry commands on a bus queue and
     calls `facade.process_instances.retry` to restart failed PIs.

  ## Configuration

  All configuration is via application env (set in the host release's
  `config.exs`):

  | Key                    | Default                                     | Description                                          |
  |------------------------|---------------------------------------------|------------------------------------------------------|
  | `:message_bus_adapter` | `IncidentReporter.MessageBus.RabbitMqAdapter` | Module implementing `MessageBus.Adapter` behaviour |
  | `:connection_opts`     | `[]`                                        | Passed to `adapter.connect/1`                        |
  | `:publish_exchange`    | `"evil.incidents"`                          | Exchange/topic for outgoing incident reports         |
  | `:consume_queue`       | `"evil.retry_commands"`                     | Queue/subscription for incoming retry commands       |

  ## Writing a Custom Adapter

  Implement `IncidentReporter.MessageBus.Adapter` for your broker of
  choice. See `RabbitMqAdapter` (production) and `InMemoryAdapter`
  (tests) for reference.
  """

  @behaviour BfwEngine.Plugin

  require Logger

  @impl true
  def on_load(facade) do
    config = Application.get_all_env(:incident_reporter)
    adapter = config[:message_bus_adapter] || IncidentReporter.MessageBus.RabbitMqAdapter

    case adapter.connect(config[:connection_opts] || []) do
      {:ok, connection} ->
        register_and_start(facade, adapter, connection, config)

      {:error, reason} ->
        Logger.error("incident_reporter: failed to connect to message bus: #{inspect(reason)}")
        {:error, {:connection_failed, reason}}
    end
  end

  @impl true
  def on_ready(_facade), do: :ok

  defp register_and_start(facade, adapter, connection, config) do
    publish_exchange = config[:publish_exchange] || "evil.incidents"
    consume_queue = config[:consume_queue] || "evil.retry_commands"

    case facade.register_event_sink.("incident_reporter", IncidentReporter.EventSink,
           message_bus_adapter: adapter,
           connection: connection,
           publish_exchange: publish_exchange
         ) do
      :ok ->
        {:ok, _consumer_pid} =
          IncidentReporter.RetryConsumer.start_link(
            engine_facade: facade,
            message_bus_adapter: adapter,
            connection: connection,
            consume_queue: consume_queue,
            name: IncidentReporter.RetryConsumer
          )

        Logger.info(
          "incident_reporter: loaded — publishing to #{publish_exchange}, consuming from #{consume_queue}"
        )

        :ok

      {:error, reason} ->
        adapter.disconnect(connection)
        {:error, {:register_event_sink_failed, reason}}
    end
  end
end

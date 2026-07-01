defmodule IncidentReporter.MessageBus.RabbitMqAdapter do
  @moduledoc """
  RabbitMQ implementation of `IncidentReporter.MessageBus.Adapter`.

  Requires the `amqp` hex package. Publishes incident payloads to a
  configurable exchange and subscribes to a queue for incoming retry
  commands.

  This adapter is the default for production deployments. For tests
  without a running broker, use `IncidentReporter.MessageBus.InMemoryAdapter`.
  """

  @behaviour IncidentReporter.MessageBus.Adapter

  require Logger

  @impl true
  def connect(opts) do
    case ensure_amqp_available() do
      :ok ->
        host = Keyword.get(opts, :host, "localhost")
        port = Keyword.get(opts, :port, 5672)

        Logger.info(
          "incident_reporter: connecting to RabbitMQ at #{host}:#{port}"
        )

        # Delegate to AMQP library when available
        apply(AMQP.Connection, :open, [
          [host: host, port: port] ++ Keyword.drop(opts, [:host, :port])
        ])

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def publish(connection, exchange, payload) when is_binary(payload) do
    channel = Map.get(connection, :channel)

    if channel do
      apply(AMQP.Basic, :publish, [channel, exchange, "", payload])
    else
      {:error, :no_channel}
    end
  end

  @impl true
  def subscribe(connection, queue, subscriber) do
    channel = Map.get(connection, :channel)

    if channel do
      apply(AMQP.Queue, :subscribe, [channel, queue, fn _meta, payload ->
        send(subscriber, {:bus_message, payload})
      end])
    else
      {:error, :no_channel}
    end
  end

  @impl true
  def disconnect(connection) do
    if connection do
      apply(AMQP.Connection, :close, [connection])
    end

    :ok
  end

  defp ensure_amqp_available do
    if Code.ensure_loaded?(AMQP.Connection) do
      :ok
    else
      {:error,
       "AMQP library not available. Add {:amqp, \"~> 3.3\"} to your deps."}
    end
  end
end

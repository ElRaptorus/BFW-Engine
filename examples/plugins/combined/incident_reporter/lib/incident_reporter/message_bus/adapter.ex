defmodule IncidentReporter.MessageBus.Adapter do
  @moduledoc """
  Pluggable transport behaviour for the Incident Reporter's message bus.

  Implement this behaviour to bridge the Incident Reporter with any message
  broker (RabbitMQ, Kafka, Redis Streams, NATS, etc.). The default
  implementation uses RabbitMQ via the `amqp` hex package.

  For tests, use `IncidentReporter.MessageBus.InMemoryAdapter`.
  """

  @type connection :: term()

  @doc """
  Establish a connection to the message broker.

  `opts` are adapter-specific (e.g. host, port, credentials for RabbitMQ).
  Returns `{:ok, connection}` or `{:error, reason}`.
  """
  @callback connect(opts :: keyword()) :: {:ok, connection()} | {:error, term()}

  @doc """
  Publish a message to the given exchange/topic.

  `payload` is a map that will be JSON-encoded by the caller before passing
  to this function. The adapter receives the encoded binary.
  """
  @callback publish(connection(), exchange :: String.t(), payload :: binary()) ::
              :ok | {:error, term()}

  @doc """
  Subscribe to a queue/topic. The adapter must deliver messages to the
  subscriber process as `{:bus_message, binary()}` messages.

  `subscriber` is the PID that should receive the messages.
  """
  @callback subscribe(connection(), queue :: String.t(), subscriber :: pid()) ::
              :ok | {:error, term()}

  @doc """
  Gracefully close the connection.
  """
  @callback disconnect(connection()) :: :ok
end

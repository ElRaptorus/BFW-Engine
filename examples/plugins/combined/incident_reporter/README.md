# Incident Reporter Plugin

Reference plugin that bridges the engine's retry API with external incident
management systems via a pluggable message bus.

## What it does

The Incident Reporter has two halves:

1. **EventSink** — watches for Process Instances transitioning to `fatal` or
   `aborted` and publishes structured JSON incident reports to a message bus
   exchange.
2. **RetryConsumer** — listens on a bus queue for incoming retry commands and
   calls `facade.process_instances.retry` to restart failed PIs.

Together they form a closed loop:

```
Engine ──→ EventSink ──→ Bus ──→ External System (PagerDuty, OpsGenie, …)
                                        │
Engine ←── RetryConsumer ←── Bus ←──────┘
```

## Incident Payload (published)

```json
{
  "type": "incident",
  "processInstanceId": "uuid",
  "processModelId": "OrderProcess",
  "version": "1.0.0",
  "parentProcessInstanceId": "uuid | null",
  "previousState": "running",
  "newState": "fatal",
  "occurredAt": "2026-05-31T15:22:00Z"
}
```

Systems needing full error details can query
`GET /process-instances/{id}` (which includes `error_info`).

## Retry Command Payload (consumed)

```json
{
  "type": "retryProcessInstance",
  "processInstanceId": "uuid",
  "version": "1.2.0",
  "resetToFlowNodeInstanceId": "uuid"
}
```

Only `type` and `processInstanceId` are required. `version` and
`resetToFlowNodeInstanceId` are optional. See
[`docs/architecture/api.md`](../../../../docs/architecture/api.md)
§`PUT /process-instances/:id/retry` for semantics.

## Configuration

Set in the host release's `config.exs`:

```elixir
config :incident_reporter,
  message_bus_adapter: IncidentReporter.MessageBus.RabbitMqAdapter,
  connection_opts: [host: "rabbitmq", port: 5672],
  publish_exchange: "evil.incidents",
  consume_queue: "evil.retry_commands"
```

| Key                    | Default                 | Description                                          |
|------------------------|-------------------------|------------------------------------------------------|
| `:message_bus_adapter` | `RabbitMqAdapter`       | Module implementing `MessageBus.Adapter` behaviour   |
| `:connection_opts`     | `[]`                    | Passed to `adapter.connect/1`                        |
| `:publish_exchange`    | `"evil.incidents"`      | Exchange/topic for outgoing incident reports         |
| `:consume_queue`       | `"evil.retry_commands"` | Queue/subscription for incoming retry commands       |

## Running with Docker Compose

```yaml
services:
  engine:
    image: your-engine-image
    environment:
      BFE_PLUGINS_INBEAM: "incident_reporter"
    depends_on:
      - rabbitmq
      - postgres

  rabbitmq:
    image: rabbitmq:3-management
    ports:
      - "5672:5672"
      - "15672:15672"

  postgres:
    image: postgres:16
    environment:
      POSTGRES_DB: bfw_engine
      POSTGRES_PASSWORD: postgres
```

## Writing a Custom MessageBus.Adapter

Implement the `IncidentReporter.MessageBus.Adapter` behaviour:

```elixir
defmodule MyApp.KafkaAdapter do
  @behaviour IncidentReporter.MessageBus.Adapter

  @impl true
  def connect(opts) do
    # Connect to Kafka cluster
    {:ok, connection}
  end

  @impl true
  def publish(connection, topic, payload) do
    # Produce message to topic
    :ok
  end

  @impl true
  def subscribe(connection, topic, subscriber) do
    # Consume from topic, deliver as {:bus_message, payload}
    :ok
  end

  @impl true
  def disconnect(connection) do
    # Graceful shutdown
    :ok
  end
end
```

Then configure:

```elixir
config :incident_reporter,
  message_bus_adapter: MyApp.KafkaAdapter,
  connection_opts: [brokers: ["kafka:9092"]]
```

Adapters for Redis Streams, NATS, or any other pub/sub transport follow
the same pattern.

## Testing

The plugin ships with `IncidentReporter.MessageBus.InMemoryAdapter` for
tests that don't require a running broker:

```bash
cd examples/plugins/combined/incident_reporter
mix deps.get
mix test
```

## Retry Loop Warning

The EventSink publishes incidents for `fatal`/`aborted` events, and an
external system may auto-retry. If the retry fails again, a new incident
is emitted — creating a potential infinite loop. **The consuming system
must implement retry limits and backoff.** The plugin itself is stateless
and does not track retry counts.

## See Also

- [`docs/architecture/plugins.md`](../../../../docs/architecture/plugins.md)
  §9.1 — EventSink behaviour
- [`docs/architecture/execution.md`](../../../../docs/architecture/execution.md)
  — PI Retry orchestration
- [`docs/architecture/api.md`](../../../../docs/architecture/api.md)
  — `PUT /process-instances/:id/retry` endpoint

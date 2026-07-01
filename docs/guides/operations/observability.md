# Observability

This guide covers the monitoring surfaces and event pipeline available in v1.

## Stats Endpoint

`GET /stats` (auth required) returns a full engine snapshot:

```json
{
  "engine": { "id": "...", "name": "...", "version": "...", "uptime_seconds": 7200 },
  "processes": { "total": 8 },
  "process_instances": { "running": 5, "finished": 42, "fatal": 1 },
  "flow_node_instances": { "active": 3, "waiting": 2 },
  "user_tasks_pending": 2,
  "timers": { "armed": 1 },
  "plugins": { "loaded": 3, "quarantined": 0 },
  "listeners": { "event_sinks_count": 4 }
}
```

Process instances and flow node instances can also be queried via [GraphQL](../api/graphql-reference.md).

## Event Sinks

The engine routes all typed events through the `EngineEventBus` to four configurable built-in sinks:

### Console Sink

| Env Var | Default | Purpose |
|---------|---------|---------|
| `EVIL_EVENT_SINK_CONSOLE` | `on` | Enable/disable |
| `EVIL_LOG_MIN_SEVERITY` | `info` | Floor: `error`, `warn`, `info`, `debug`, `verbose` |

### Telemetry Sink

| Env Var | Default |
|---------|---------|
| `EVIL_EVENT_SINK_TELEMETRY` | `on` |

Disabling this makes all `/stats` counters permanently zero.

### WebSocket Sink

| Env Var | Default |
|---------|---------|
| `EVIL_EVENT_SINK_WEBSOCKET` | `on` |
| `EVIL_EVENT_SINK_WEBSOCKET_MIN_SEVERITY` | `info` |

## Logging

In production, the engine outputs structured JSON log lines via `logger_json`. Use your preferred log aggregator (ELK, Datadog, Loki) to index and search.

## Custom Event Sinks

Build a plugin implementing `@behaviour EvilEngine.Plugin.EventSink` to forward events to external systems (Datadog, Kafka, PagerDuty, etc.). See [Implementing Event Sinks](../plugins/event-sink.md).

## External Telemetry

No OpenTelemetry or Prometheus integration in v1. The `/stats` endpoint and event sinks are the sole observability surfaces. External telemetry is a post-v1 roadmap item.

## Related

- [Monitoring](../handbook/monitoring.md) -- endpoint usage and subscription patterns
- [Implementing Event Sinks](../plugins/event-sink.md) -- custom sink development
- [Database Administration](database.md) -- event table retention

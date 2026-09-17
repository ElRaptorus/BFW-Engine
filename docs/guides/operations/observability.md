# Observability

This guide covers the monitoring surfaces and event pipeline that ship today.

## Health

`GET /health` is a public liveness probe. It returns **204 No Content** (empty body). Kubernetes / Docker probes should check the status code only.

Load level lives on **`GET /stats`** (`engine.load`: `normal` / `elevated` / `critical`), not on `/health`.

## Stats Endpoint

`GET /stats` (JWT required) returns a camelCase snapshot from `StatsCollector.snapshot/0`:

```json
{
  "engine": {
    "id": "...",
    "name": "...",
    "version": "...",
    "startedAt": "2026-08-24T12:00:00Z",
    "uptimeSeconds": 7200,
    "load": "normal"
  },
  "processInstances": { "running": 5, "finished": 42, "fatal": 1, "aborted": 0, "error": 0 },
  "flowNodeInstances": {
    "active": 3,
    "waiting": 2,
    "finished": 40,
    "fatal": 0,
    "aborted": 0,
    "interrupted": 0,
    "byType": {}
  },
  "userTasksPending": { "count": 2, "byAssigneeRole": {} },
  "asyncFlowNodes": { "waiting": 1, "byPlugin": {} },
  "timers": { "armed": 1, "fireInNextMinute": 0 },
  "plugins": [],
  "listeners": {
    "eventSinksCount": 3,
    "eventSinksByName": { "console": "on", "telemetry": "on", "websocket": "on" },
    "monitoringPanelsCount": 0
  }
}
```

`plugins` is an **array** of registry entries, not a `{loaded, quarantined}` object. Process instances and flow node instances can also be queried via [GraphQL](../api/graphql-reference.md).

## Prometheus (`GET /metrics`)

`GET /metrics` is public Prometheus text (`text/plain; version=0.0.4`). It is **on by default** via `TDE_METRICS_ENABLED=true`. Set `TDE_METRICS_ENABLED=false` to return 404.

The scrape endpoint is **unauthenticated**. Restrict it at the network edge if the engine is reachable from untrusted networks.

## Event Sinks

The engine routes typed events through `EngineEventBus` to **three** built-in sinks (console, telemetry, websocket). The engine does not persist those events to Postgres. Sinks are attached by `SinkRegistrar` at boot — they are not OTP plugins.

### Console Sink

| Env Var | Default | Purpose |
|---------|---------|---------|
| `TDE_EVENT_SINK_CONSOLE` | `on` | Enable/disable |
| `TDE_LOG_MIN_SEVERITY` | `info` | Floor: `error`, `warn`, `info`, `debug`, `verbose` |

### Telemetry Sink

| Env Var | Default |
|---------|---------|
| `TDE_EVENT_SINK_TELEMETRY` | `on` |

Disabling this stops the Prometheus `evil_engine.event_bus.events.total` series from incrementing. It does **not** zero `/stats` — that snapshot is live Ash/ETS queries.

### WebSocket Sink

| Env Var | Default |
|---------|---------|
| `TDE_EVENT_SINK_WEBSOCKET` | `on` |

There is no `TDE_EVENT_SINK_WEBSOCKET_MIN_SEVERITY`. The WebSocket sink rejects only `SinkFailed`; it does not filter by log severity. Console severity is `TDE_LOG_MIN_SEVERITY` only.

## Logging

In production, the engine outputs structured JSON log lines via `logger_json`. Use your preferred log aggregator (ELK, Datadog, Loki) to index and search.

## Custom Event Sinks

Build a plugin implementing `@behaviour EvilEngine.Plugin.EventSink` to forward events to external systems (Datadog, Kafka, PagerDuty, etc.). See [Implementing Event Sinks](../plugins/event-sink.md).

## Related

- [Monitoring](../handbook/monitoring.md) -- endpoint usage and subscription patterns
- [Implementing Event Sinks](../plugins/event-sink.md) -- custom sink development
- [Database Administration](database.md) -- tables, partitioning, Mix retention purge, operator SQL

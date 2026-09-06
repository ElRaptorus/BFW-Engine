# Monitoring and Observability

This guide covers the endpoints and mechanisms available for monitoring engine health, process execution, and real-time events.

## Health and Info (No Auth Required)

```bash
# Liveness / readiness — 204 No Content (empty body)
curl -i http://localhost:4000/health
# HTTP/1.1 204 No Content

# Engine identity (camelCase)
curl http://localhost:4000/info
# {"engineId":"...","engineName":"...","version":"0.0.1","startedAt":"..."}
```

`GET /health` is a liveness probe only. Load (`normal` / `elevated` / `critical`) lives on **`GET /stats`** as `engine.load`. See [Back-Pressure](../operations/backpressure.md).

`GET /info` does **not** serialize a database event sink. The built-in database event sink was removed.

## Prometheus Metrics

```bash
curl http://localhost:4000/metrics
```

`GET /metrics` is **public Prometheus text** (no authentication). Enabled by default (`TDE_METRICS_ENABLED=true`). Set to `false` to disable. OpenTelemetry does **not** ship.

| Metric | Type | Description |
|--------|------|-------------|
| `evil_engine_http_requests_total` | Counter | HTTP request count by method, path, and status |
| `evil_engine_http_request_duration_milliseconds` | Histogram | HTTP request latency |
| `evil_engine_pi_state_changes_total` | Counter | PI state transitions by target state |
| `evil_engine_fni_started_total` | Counter | FNI creations |
| `evil_engine_fni_state_changes_total` | Counter | FNI state transitions by target state |
| `evil_engine_event_bus_events_total` | Counter | Events dispatched through the EngineEventBus, by type |
| `evil_engine_active_process_instances` | Gauge | Currently in-memory PIs (polled every 10s) |
| `evil_engine_pi_capacity_ratio` | Gauge | Ratio of active PIs to configured cap (0.0–1.0) |
| BEAM VM gauges | Gauge | Memory usage, run queue lengths, process count |

For Alertmanager rules and production setup, see [Observability](../operations/observability.md) and [Back-Pressure](../operations/backpressure.md).

## Engine Stats (Auth Required)

```bash
curl http://localhost:4000/stats \
  -H "Authorization: Bearer $TOKEN"
```

Wire keys are camelCase (`StatsResponse`). Condensed shape:

```json
{
  "processInstances": { "running": 3, "finished": 12 },
  "userTasksPending": { "count": 2 },
  "plugins": [],
  "engine": { "load": "normal" },
  "listeners": { "eventSinksByName": { "console": {}, "telemetry": {}, "websocket": {} } }
}
```

`plugins` is an **array**. Full field list: OpenAPI `GET /api/openapi`.

## GraphQL Queries

Process instances and flow node instances can be queried via [GraphQL](../api/graphql-reference.md). List queries use **offset** pagination (`limit` / `offset`), not cursor keysets:

```graphql
query {
  processInstances(
    filter: { state: { eq: "running" } },
    limit: 25,
    offset: 0
  ) {
    results {
      id
      state
      startedAt
    }
    count
  }
}
```

GraphQL is query-only. Queries enforce lane-based visibility — the caller only sees PIs and FNIs they have access to.

## WebSocket Channels

For real-time monitoring, the engine pushes events via Phoenix Channels:

| Topic | Content |
|-------|---------|
| `engine:events` | Engine-level events plus PI-scoped events filtered by visibility and lane |
| `process_instance:<id>` | Events for a specific PI (not `pi:<id>`) |
| `user_tasks:pending` | `UserTaskCreated` / `UserTaskFinished` inbox, lane-filtered |

Twelve event types carry `rootProcessInstanceId`. For child PIs the WebSocket sink also broadcasts to `process_instance:<rootProcessInstanceId>`, so a debugger subscribed only to the root channel receives descendant FNI, user-task, data-object, and compensation events.

Condensed live catalog (full tables: [WebSocket API](../api/websocket.md) and [Engine event system](../../architecture/event-system.md)):

| Type | Notes |
|------|-------|
| `EngineStarted` / `EngineShutdown` / `EngineOverloaded` / `EngineRecovered` | Operational |
| `ProcessInstanceStateChanged` / `ProcessInstanceRetried` | PI lifecycle; retry version fields are UUIDs |
| `FlowNodeInstanceStarted` / `Finished` / `StateChanged` | FNI lifecycle |
| `MultiInstanceStarted` / `MultiInstanceCompleted` | MI / Standard Loop shells |
| `UserTaskCreated` / `Finished` / `ValidationFailed` | Also `user_tasks:pending` |
| `CallActivityChildStarted` / `SubProcessChildStarted` / `EventSubprocessTriggered` | Child PIs |
| `MessagePublished` / `Arrived`, `SignalPublished` / `Arrived`, `EscalationRaised` | Communication |
| `TimerFired` / `DataObjectWritten` | Runtime |
| `CompensationTriggered` / `ActivityCompensated` / `TransactionCancelled` | Compensation / transactions |
| `AdHocActivityActivated` / `AdHocSubProcessCompleted` | Ad-hoc |
| Catalog / DMN deploy and `DecisionEvaluated` | Definitions |

`SinkFailed` does **not** reach the WebSocket sink.

## Event Sinks

The engine routes all internal events through the `EngineEventBus` to three built-in sinks:

| Sink | Env Var | Default | Purpose |
|------|---------|---------|---------|
| Console | `TDE_EVENT_SINK_CONSOLE` | `on` | Logs events at configurable severity |
| Telemetry | `TDE_EVENT_SINK_TELEMETRY` | `on` | Feeds `/stats` counters |
| WebSocket | `TDE_EVENT_SINK_WEBSOCKET` | `on` | Pushes to Phoenix Channels |

Console severity is `TDE_LOG_MIN_SEVERITY`. There is no per-WebSocket min-severity env var.

Custom sinks can be built as plugins — see [Implementing Event Sinks](../plugins/event-sink.md).

For production telemetry configuration, see [Observability](../operations/observability.md).

## Related

- [WebSocket API](../api/websocket.md) -- channel connection, event types, and authorization
- [Observability](../operations/observability.md) -- production monitoring setup
- [Back-Pressure](../operations/backpressure.md) -- capacity management and overload signaling
- [Implementing Event Sinks](../plugins/event-sink.md) -- custom sink development

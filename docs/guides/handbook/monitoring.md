# Monitoring and Observability

This guide covers the endpoints and mechanisms available for monitoring engine health, process execution, and real-time events.

## Health and Info (No Auth Required)

```bash
# Liveness / readiness check
curl http://localhost:4000/health
# {"status":"ok","uptime_seconds":3600}

# Engine identity and feature flags
curl http://localhost:4000/info
# {"engine_id":"...","engine_name":"...","version":"0.0.1",
#  "started_at":"...","uptime_seconds":3600,
#  "auth_disabled":false,"event_sink_database":false}
```

Both endpoints are suitable for container health probes.

The `/health` endpoint also includes a `"load"` field reflecting back-pressure status (`"normal"`, `"elevated"`, or `"critical"`) when `EVIL_MAX_CONCURRENT_PIS` is configured. See [Back-Pressure](../operations/backpressure.md) for threshold details.

## Prometheus Metrics

```bash
curl http://localhost:4000/metrics
```

The `/metrics` endpoint (no authentication required) exposes the full metric catalog in Prometheus text format. Available metrics:

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

The endpoint is enabled by default (`EVIL_METRICS_ENABLED=true`). Set to `false` to disable.

For Alertmanager rules and production setup, see [Observability](../operations/observability.md) and [Back-Pressure](../operations/backpressure.md).

## Engine Stats (Auth Required)

```bash
curl http://localhost:4000/stats \
  -H "Authorization: Bearer $TOKEN"
```

Returns a full snapshot including engine identity, deployed processes, running PIs, active FNIs, pending user tasks, timers, loaded plugins, and registered event sinks.

## GraphQL Queries

Process instances and flow node instances can be queried via [GraphQL](../api/graphql-reference.md):

```graphql
query {
  processInstances(
    filter: { state: { eq: RUNNING } },
    first: 25
  ) {
    results {
      id
      state
      startedAt
    }
    count
    endKeyset
  }
}
```

GraphQL queries enforce lane-based visibility — the caller only sees PIs and FNIs they have access to.

## WebSocket Channels

For real-time monitoring, the engine pushes events via Phoenix Channels:

| Topic | Content |
|-------|---------|
| `engine:events` | Engine-level events plus PI-scoped events filtered by §5.1 visibility and lane |
| `process_instance:<id>` | Events for a specific PI (state changes, FNI lifecycle, user tasks), FNI events lane-filtered |
| `user_tasks:pending` | `UserTaskCreated` / `UserTaskFinished` inbox, lane-filtered |

PI-scoped events are broadcast to `process_instance:<id>` **and** `engine:events`. Dispatch then drops FNI events whose `laneName` the subscriber cannot access, and on `engine:events` drops PI-level events the subscriber cannot see.

Joining `process_instance:<id>` requires the PI to be visible to the caller. See [WebSocket API](../api/websocket.md) for connection details, event types, and authorization rules.

## Event Sinks

The engine routes all internal events through the `EngineEventBus` to configurable sinks:

| Sink | Env Var | Default | Purpose |
|------|---------|---------|---------|
| Console | `EVIL_EVENT_SINK_CONSOLE` | `on` | Logs events at configurable severity |
| Telemetry | `EVIL_EVENT_SINK_TELEMETRY` | `on` | Feeds `/stats` counters |
| WebSocket | `EVIL_EVENT_SINK_WEBSOCKET` | `on` | Pushes to Phoenix Channels |

Severity filtering is available per sink (e.g., `EVIL_LOG_MIN_SEVERITY`).

Custom sinks can be built as plugins — see [Implementing Event Sinks](../plugins/event-sink.md).

For production telemetry configuration, see [Observability](../operations/observability.md).

## Related

- [WebSocket API](../api/websocket.md) -- channel connection, event types, and authorization
- [Observability](../operations/observability.md) -- production monitoring setup
- [Back-Pressure](../operations/backpressure.md) -- capacity management and overload signaling
- [Implementing Event Sinks](../plugins/event-sink.md) -- custom sink development

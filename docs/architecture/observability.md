---
title: Daemon Engine — Observability
parent_document: ../ImplementationPlan.md
---

<!-- Extracted from ImplementationPlan.md §11 (Observability). -->

## 11. Observability

Core observability stays intentionally small: structured JSON logs + a
`/stats` JSON snapshot. **Phase 2** adds an optional public **`GET /metrics`**
Prometheus exposition endpoint (`telemetry_metrics_prometheus_core` from Hex `~> 1.1`, not GitHub `main`), gated by
`TDE_METRICS_ENABLED` (see [configuration.md](./configuration.md)). No OpenTelemetry and no distributed tracing in v1.
Every typed engine event is fanned out through `EngineEventBus` to a set of
pluggable sinks ([§3.3](./event-system.md)); this section describes what each sink surfaces and how operators
turn on the ones they want.

### 11.1 Event sinks — how observability output is produced

Everything observable the engine produces at runtime (PI/FNI transitions, messages, signals, timers, Data Object writes, escalation traces, deploy events, sink failures) flows through `EngineEventBus` to the set of active sinks. Mix retention purge does **not** emit bus events. Each sink's output shape is described in [§3.3.3](./event-system.md). **Operator-facing defaults:**

| Sink | Default | What the operator sees | When to enable/disable |
|---|---|---|---|
| `console` | ON | Structured JSON lines on stdout, one per event at or above `TDE_LOG_MIN_SEVERITY` (default `info`). Captured by whatever log-collector the container runtime provides (`kubectl logs`, `docker logs`, Loki, Cloudwatch, …) | Disable for pure-library embeds; leave on otherwise — extremely cheap |
| `telemetry` | ON | In-process `:telemetry` counters (see §11.2). No output channel of its own; feeds `/stats` | Do not disable except in benchmarks; `/stats` loses all counters otherwise |
| `websocket` | ON | Live push to connected Phoenix Channels clients (`process_instance:<id>`, `engine:*`). `debug`/`verbose` severities excluded by default to avoid flooding long-lived Studio connections | Disable when no WS consumers exist; saves negligible CPU |
| `database` | **OFF** | Inserts rows into `process_instance_events` ([§4.3](./data-model.md)). Enables GraphQL-based historical queries over the engine's typed-event log | **Enable when a flat, SQL-queryable log of every typed engine event is wanted** — compliance audit, severity sweeps (`warn`/`error` across time ranges), handler-retry traces, or surfacing plugin-emitted out-of-BPMN-flow events in a log panel. **Not required** to render the BPMN-flow view of a PI (see caveat below) |
| plugin sinks | depends | Whatever the plugin ships to — Datadog, Kafka, S3 JSONL archive, etc. | Author-controlled |

**Debugger reconstruction — what the always-on tables already cover.** The engine's kernel tables are populated regardless of EventSink configuration ([§3.3.2](./event-system.md), §3.3.2.*):

- `process_instances` + `flow_node_instances` carry every PI / FNI state + timestamps + token payloads, plus the `triggerer_flow_node_instance_id` backlink on every Catch Event / Boundary Event / Auto-triggered PI / Start Event spawned by a Throw or Send Task, and the `parent_process_instance_id` backlink for Call-Activity children.
- `data_objects` + `data_object_writes` (always-on) carry the full DO write history with FNI attribution.
- `messages` / `signals` (always-on) carry each engine-wide publish event with `correlations[]` holding `{process_instance_id, flow_node_instance_id, delivered_at}` per recipient, plus the `origin` FNI for thrown events. Escalation and compensation raises are EngineEventBus events (`Event.EscalationRaised`, `Event.CompensationTriggered`), not dedicated tables.
- Timer Start cycle schedules persist in `timer_start_schedules` via `EvilEngine.Persistence.TimerStartScheduleAdapter` (production). Test env uses `Timers.Persistence.NoOp`. PI-scoped timer state lives in FNI `type_properties` and the Scheduler ETS tables.

Together these reconstruct the full sender↔receiver pattern for every BPMN-element-sourced event (the Studio debugger's current approach: point at an event's source and let the user navigate). **This works identically whether the DB EventSink is on or off, live or historical.**

**What the DB sink adds on top** — a flat `process_instance_events` log covering events that do *not* correspond to a kernel-table row: engine lifecycle, severity-filtered `debug`/`verbose` observability emissions, and plugin-emitted events that have no BPMN source element. Events of the last kind are inherently un-navigable from the BPMN flow view either way — they exist only as a flat log — so turning the sink on is a choice about whether the operator wants that log queryable from SQL/GraphQL, not about whether the debugger's flow view works.

**Studio integration caveat:** a Studio "Engine Event Log" panel (flat chronological list, optionally filtered by severity/type) would require a plugin event sink that writes to a custom DB table — the built-in database sink was removed. The Studio debugger's **BPMN-flow view** (PI progress, FNI-detail panels, sender↔receiver navigation, DO history, message/signal/escalation delivery traces) works with any sink configuration.

### 11.2 Logs

- The `console` sink emits events as **structured JSON** (`logger_json` formatter) — this is the primary log surface in v1.
- Severity levels: `error | warn | info | debug | verbose` (maps to concept's "Verbose"). Configured globally via `TDE_LOG_MIN_SEVERITY` (default `info`).
- Every log line carries: `engine_id`, `process_instance_id?`, `flow_node_instance_id?`, `identity.id?`, plus the event-specific payload from `EvilEngine.Types.Event.*`.
- Engine-internal logs outside the event bus (startup banners, sink-failure warnings) use the same JSON formatter and share the same severity level. Mix retention purge logs counts to stdout; there is no RetentionRunner heartbeat.
- **API error audit trail:** Every REST error response is logged by `ErrorResponse` (`:error` for 5xx, `:warning` for 4xx). Auth failures, payload-cap violations, rate-limit rejections, and rescued exceptions in message/signal controllers are logged separately with additional context. GraphQL errors are logged by the `ErrorLogger` Absinthe phase. See [api.md §Audit-trail logging](api.md#audit-trail-logging).

### 11.2 `/stats` endpoint (JSON snapshot)

Primary JSON runtime snapshot (authenticated). Returns the current in-memory snapshot:

```jsonc
{
  "engine": {
    "id": "…", "name": "…", "version": "…",
    "started_at": "2026-04-24T09:12:33Z",
    "uptime_seconds": 12345
  },
  "process_instances": {
    "running": 0, "finished": 0, "fatal": 0,
    "aborted": 0, "error": 0, "escalated": 0, "compensated": 0
  },
  "flow_node_instances": {
    "active": 0, "finished": 0, "fatal": 0,
    "aborted": 0, "interrupted": 0,
    "by_type": { "userTask": 0, "serviceTask": 0, "…": 0 }
  },
  "user_tasks_pending": {
    "count": 0,
    "by_assignee_role": { "…": 0 }
  },
  "async_flow_nodes": {
    "waiting": 0,
    "by_plugin": { "…": 0 }
  },
  "timers": { "armed": 0, "fire_in_next_minute": 0 },
  "plugins": [ { "name": "evil:http_service_task", "kind": "ServiceTaskHandler", "healthy": true } ],
  "listeners": {
    "event_sinks_count": 0,
    "event_sinks_by_name": { "console": "on", "telemetry": "on", "websocket": "on", "database": "off" },
    "monitoring_panels_count": 0
  }
}
```

Backed by the `telemetry` event sink ([§3.3.3](./event-system.md)), which increments in-process `:telemetry` counters on every event. The snapshot is assembled lazily on request; there is no in-memory ring buffer and no time-series retention inside the engine.

**`GET /metrics` (Phase 2, public):** When `TDE_METRICS_ENABLED` is `true` (default), `EvilEngine.Telemetry.Metrics` registers a Prometheus reporter (`TelemetryMetricsPrometheus.Core`) plus a poller (`EvilEngine.Telemetry.Measurements`) that samples active PI count, PI capacity ratio, BEAM VM memory/run-queue/process-count gauges, and evaluates overload threshold transitions (event bus publishes `Event.EngineOverloaded` on upward crossings and `Event.EngineRecovered` on recovery to normal, only on level changes, not every tick). Scrape output is plain text; when metrics are disabled the HTTP handler returns `404` with `{"error":"metrics_disabled"}`.

#### Prometheus metric catalog

| Metric | Type | Labels | Event / source |
|--------|------|--------|----------------|
| `evil_engine.http.request.total` | counter | method, route, status | `[:evil_engine, :http, :stop]` |
| `evil_engine.http.request.duration_ms` | distribution | — | `[:evil_engine, :http, :stop]` |
| `evil_engine.process_instance.state_change.total` | counter | old_state, new_state | `[:evil_engine, :process_instance, :state_change]` |
| `evil_engine.process_instance.active.count` | last_value | — | `[:evil_engine, :process_instance, :active]` (poller) |
| `evil_engine.process_instance.capacity.ratio` | last_value | — | `[:evil_engine, :process_instance, :capacity]` (poller) |
| `evil_engine.flow_node_instance.started.total` | counter | — | `[:evil_engine, :flow_node_instance, :started]` |
| `evil_engine.fni.state_change.total` | counter | flow_node_type, terminal_state | `[:evil_engine, :fni, :state_change]` |
| `evil_engine.event_bus.events.total` | counter | event_type | `[:evil_engine, :event_bus]` |
| `vm.memory.total` | last_value | — | VM poller |
| `vm.memory.processes` | last_value | — | VM poller |
| `vm.total_run_queue_lengths.total` | last_value | — | VM poller |
| `vm.total_run_queue_lengths.cpu` | last_value | — | VM poller |
| `vm.total_run_queue_lengths.io` | last_value | — | VM poller |
| `vm.system_counts.process_count` | last_value | — | VM poller |
| `evil_engine.dmn.evaluations.total` | counter | `hit_policy` | `[:evil_engine, :dmn, :evaluate, :stop]` |
| `evil_engine.dmn.evaluate.duration.milliseconds` | distribution | — | `[:evil_engine, :dmn, :evaluate, :stop]` |
| `evil_engine.dmn.evaluations.exceptions.total` | counter | — | `[:evil_engine, :dmn, :evaluate, :exception]` |
| `evil_engine.dmn.cache.hit.total` | counter | — | `[:evil_engine, :dmn, :cache, :hit]` |
| `evil_engine.dmn.cache.miss.total` | counter | — | `[:evil_engine, :dmn, :cache, :miss]` |
| `evil_engine.db.query.queue_time_ms` | distribution | repo | `[:evil_engine, :db, :query]` (handler) |
| `evil_engine.db.query.total_time_ms` | distribution | repo | `[:evil_engine, :db, :query]` (handler) |
| `evil_engine.db.query.count` | counter | repo, source | `[:evil_engine, :db, :query]` (handler) |
| `evil_engine.db.pool.size` | last_value | repo | `[:evil_engine, :db, :pool]` (poller, 10s) |
| `evil_engine.db.pool.checked_out` | last_value | repo | `[:evil_engine, :db, :pool]` (poller, 10s) |
| `evil_engine.db.pool.idle` | last_value | repo | `[:evil_engine, :db, :pool]` (poller, 10s) |

**DB pool pressure detection:** `DbQueryHandler` attaches to each Repo's Ecto `:query` telemetry event and re-emits standardized `[:evil_engine, :db, :query]` events with millisecond-precision `queue_time_ms`. When checkout wait exceeds `TDE_DB_QUEUE_TIME_WARNING_MS` (default 500ms), a warning is logged. The `repo` tag distinguishes the write pool (`:write`) from the read pool (`:read`) in dual-pool configurations. The `source` tag is the Ecto schema source when present; for raw `Ecto.Adapters.SQL.query` (Data Object snapshot/audit INSERTs, and any other adapter SQL) it is parsed from the SQL table name so those writes are not lumped into `unknown`.

**`GET /health`** returns 204 No Content — a lightweight liveness probe for Kubernetes / Docker. No body.

**`GET /stats`** (auth-gated) includes a `dbPools` section with pool sizes per repo:

```json
{ "dbPools": { "write": { "poolSize": 20 }, "read": { "poolSize": 10 } } }
```

`listeners.eventSinksByName` lets operators verify at a glance which sinks are actually active on the running engine.

### 11.3 Historical / time-series analysis

Out of scope for `/stats`. Any time-range query ("how many PIs failed last hour?", "FNI type distribution over the past week?") has two possible answers depending on the operator's sink configuration:

- **DB sink ON** — GraphQL queries against `process_instance_events` with filter/sort/page ([§10.2](./api.md)) serve the query directly. Retention trims this table per the configured per-state max-age policies.
- **DB sink OFF** — `process_instance_events` is empty; these queries are the external-sink operator's responsibility (query Datadog / Kafka / whatever they ship to). The engine does not keep a shadow in-memory event log for this case; "no DB sink" means "no engine-side historical event store".

Either way the runtime hot path stays free of metrics-aggregation overhead.

### 11.4 Minimal admin HTML

- `/admin/` — single server-rendered page that fetches `/stats`, `/info`, `/health` on load.
- Shows: engine id/uptime, running / waiting / finished / failed counts, per-process
  version counts, plugin list (grouped by kind), event-listener counts per plugin,
  links to Swagger UI + GraphiQL.
- No JS build pipeline; just `Phoenix.HTML` with a tiny CSS file. htmx may be used
  for periodic refresh if polling is desired.

### 11.5 Not in v1 (see ../ImplementationPlan.md §16.4)

- OpenTelemetry logs / metrics / traces export (OTLP)
- Distributed tracing (trace id / span id instrumentation)

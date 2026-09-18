# Observability

---

## Overview

The engine exposes four operator surfaces: structured logs, a JWT-gated
JSON snapshot (`GET /stats`), a public Prometheus scrape (`GET /metrics`),
and unauthenticated liveness/identity probes (`GET /health`, `GET /info`).
Typed runtime events fan out through `EngineEventBus` to three built-in
EventSinks plus any plugin sinks ([event-system.md](./event-system.md)).
Mix retention purge does **not** emit bus events.

---

## Architecture

### Surfaces

| Surface | Auth | What it is |
|---------|------|------------|
| Console EventSink + Logger | n/a | One structured line per accepted bus event (and other Logger output). In `MIX_ENV=prod`, `logger_json` formats stdout as JSON. |
| `GET /stats` | JWT | On-demand snapshot assembled by `StatsCollector` from live Ash counts, Scheduler ETS, the plugin registry, and registered sinks. Not a time-series store. |
| `GET /metrics` | none | Prometheus text exposition from `TelemetryMetricsPrometheus.Core`. Disabled with `TDE_METRICS_ENABLED=false` → HTTP 404 `metrics_disabled`. |
| `GET /health` | none | Liveness probe: **204 No Content**, empty body. |
| `GET /info` | none | Engine id, name, version, `startedAt`. |
| WebSocket EventSink | JWT (channel join) | Live `EvilEngine.Types.Event.*` push to Phoenix Channels. |
| Plugin EventSinks | n/a | Operator-authored destinations (Datadog, Kafka, webhook, …). |

`GET /admin/graphiql` is the GraphQL playground (devtools-gated). Swagger UI
is `GET /`. There is no stats dashboard at `/admin/`.

### Event sinks

Everything typed the engine emits at runtime (PI/FNI transitions, messages,
signals, timers, Data Object writes, escalation/compensation, deploy, sink
failures) is published with `EngineEventBus.publish/1`. Each registered
`@behaviour EvilEngine.Plugin.EventSink` receives the event independently
(at-most-once, crash-isolated). Catalog and dispatch: [event-system.md](./event-system.md).

Built-in sinks registered at boot by `EvilEngine.Events.SinkRegistrar`:

| Sink | Module | Default | Filter | Operator effect |
|------|--------|---------|--------|-----------------|
| `console` | `EvilEngine.Events.Sinks.Console` | ON (`TDE_EVENT_SINK_CONSOLE`) | `TDE_LOG_MIN_SEVERITY` (default `info`; `error` / `warn` / `info` / `debug` / `verbose`) | Logger line per accepted event. `SinkFailed` is never accepted. |
| `telemetry` | `EvilEngine.Telemetry.Sink` | ON (`TDE_EVENT_SINK_TELEMETRY`) | none (`accepts?/1` always true) | Increments `[:evil_engine, :event_bus]` (Prometheus `evil_engine.event_bus.events.total` by `event_type`). **Does not feed `/stats`.** |
| `websocket` | `EvilEngineWeb.Ws.Sinks.WebSocket` | ON (`TDE_EVENT_SINK_WEBSOCKET`) | rejects only `SinkFailed` | Phoenix.PubSub broadcast to `engine:events`, `process_instance:<id>`, root-PI fan-out, and `user_tasks:pending` where applicable. |

Plugin sinks register from `on_load/1` via
`facade.register_event_sink.(name, module, opts)`.

**Database sink removed.** There is no `EvilEngine.Events.Sinks.Database`,
no `TDE_EVENT_SINK_DATABASE`, and no GraphQL resource over a typed-event
log. The `process_instance_events` table is retained for schema/migration
compatibility, partitioned monthly, and stays empty unless a **plugin**
sink writes it. Mix `evil.retention.purge` still deletes leftover rows
when a PI tree is hard-deleted.

**Debugger reconstruction does not need that table.** Kernel tables are
written regardless of sink configuration:

| Table / field | What it reconstructs |
|---------------|----------------------|
| `process_instances` / `flow_node_instances` | PI/FNI state, timestamps, tokens, `triggerer_flow_node_instance_id`, `parent_process_instance_id` |
| `data_objects` / `data_object_writes` | DO snapshot + write history with FNI attribution |
| `messages` / `signals` | Engine-wide publish + `correlations[]` deliveries + throw `origin` |
| `timer_start_schedules` + FNI `type_properties` + Scheduler ETS | Cycle Timer Starts and PI-scoped timers |

Escalation and compensation are bus events (`Event.EscalationRaised`,
`Event.CompensationTriggered`, `Event.ActivityCompensated`), not dedicated
tables. A Studio “flat event log” panel would need a plugin sink; the BPMN
flow view does not.

### Logs

The `console` sink encodes each accepted event with `Jason` and logs it at
a level inferred from the struct (`EngineShutdown` → warn, everything else
accepted → info). Metadata keys present when the struct has them:
`event_type`, `engine_id`, `process_instance_id`, `flow_node_instance_id`.
There is no `identity.id` on that metadata map.

`TDE_LOG_MIN_SEVERITY` is the floor. Engine-internal Logger calls outside
the bus (startup, sink-registration warnings, DB pool-pressure warnings,
API `ErrorResponse`, GraphQL `ErrorLogger`) share the same Logger backend.
In production that backend is `logger_json` (`{:logger_json, "~> 7.0", only: :prod}`).
Mix retention purge logs counts to stdout; there is no RetentionRunner heartbeat.

API error audit: [api.md](./api.md) §Audit-trail logging.

### `GET /stats`

JWT-gated. `EvilEngineWeb.Http.StatsController` camelizes
`EvilEngine.Telemetry.StatsCollector.snapshot/0`. Assembly is **live
queries on request**, not a counter cache:

| Block | Source |
|-------|--------|
| `engine` | `:peripheral_telemetry` config, `:core_execution` app vsn, `:persistent_term` start time, load from `DynamicSupervisor.count_children(EvilEngine.Execution.Supervisor)` vs `TDE_MAX_CONCURRENT_PIS` |
| `processInstances` | Ash `count` on `ProcessInstance` per state `running` / `finished` / `fatal` / `aborted` / `error` |
| `flowNodeInstances` | Ash `count` on `FlowNodeInstance` per state including `waiting` / `interrupted` / `error` |
| `userTasksPending.count` | waiting `user_task` FNIs |
| `asyncFlowNodes.waiting` | waiting FNIs that are not user tasks |
| `timers` | Scheduler ETS `:evil_engine_timers_primary` size + count with `fire_at` ≤ now+60s |
| `plugins` | `EvilEngine.Plugins.Registry.list_plugins/0` |
| `listeners` | `EngineEventBus.list_sinks/0` |
| `dbPools` | configured `pool_size` for write `Repo` and, if started, `ReadRepo` |

Ash/ETS failures are caught and returned as zeros / empty maps so the
endpoint does not 500 when Postgres is down.

Wire shape (camelCase):

```json
{
  "engine": {
    "id": "…",
    "name": "…",
    "version": "…",
    "startedAt": "2026-04-24T09:12:33Z",
    "uptimeSeconds": 12345,
    "load": "normal"
  },
  "processInstances": {
    "running": 0, "finished": 0, "fatal": 0, "aborted": 0, "error": 0
  },
  "flowNodeInstances": {
    "active": 0, "waiting": 0, "finished": 0, "fatal": 0,
    "aborted": 0, "interrupted": 0, "error": 0,
    "byType": {}
  },
  "userTasksPending": { "count": 0, "byAssigneeRole": {} },
  "asyncFlowNodes": { "waiting": 0, "byPlugin": {} },
  "timers": { "armed": 0, "fireInNextMinute": 0 },
  "plugins": [],
  "listeners": {
    "eventSinksCount": 3,
    "eventSinksByName": { "console": "on", "telemetry": "on", "websocket": "on" },
    "monitoringPanelsCount": 0
  },
  "dbPools": { "write": { "poolSize": 20 }, "read": { "poolSize": 10 } }
}
```

Placeholders that are **always empty / zero** in this collector (fields
exist for wire stability): `flowNodeInstances.byType`,
`userTasksPending.byAssigneeRole`, `asyncFlowNodes.byPlugin`,
`listeners.monitoringPanelsCount`.

`processInstances` does **not** count `:cancelled`, `:escalated`, or
`:compensated` (those PI states exist on the resource; they are omitted
from this snapshot). Disabling the telemetry sink does **not** zero
`/stats`.

`engine.load` is `normal` / `elevated` / `critical` at 70% / 90% of
`TDE_MAX_CONCURRENT_PIS` when the cap is a positive integer; always
`normal` when the cap is `:infinity`. The same thresholds drive
`Event.EngineOverloaded` / `Event.EngineRecovered` from the 10s poller
(crossings only, not every tick).

`plugins` is the registry list (`name`, `module`, `manifest`, `status`,
`registeredAt`), not `{loaded, quarantined}`.

### `GET /metrics`

Public Prometheus text (`text/plain`). Definitions:
`EvilEngine.Telemetry.Metrics.metrics/0`. The reporter plus
`:telemetry_poller` (period 10s) start only when
`:peripheral_telemetry, :metrics_enabled` is true.

Scrape names use underscores (dots in the Telemetry.Metrics name become
`_`). Catalog:

| Telemetry.Metrics name | Type | Labels | Source event |
|------------------------|------|--------|--------------|
| `evil_engine.http.request.total` | counter | `method`, `route`, `status` | `[:evil_engine, :http, :stop]` (`Plug.Telemetry`) |
| `evil_engine.http.request.duration_ms` | distribution | — | same |
| `evil_engine.process_instance.state_change.total` | counter | `old_state`, `new_state` | `[:evil_engine, :process_instance, :state_change]` |
| `evil_engine.process_instance.active.count` | last_value | — | `[:evil_engine, :process_instance, :active]` (poller) |
| `evil_engine.process_instance.capacity.ratio` | last_value | — | `[:evil_engine, :process_instance, :capacity]` (poller; `0.0` when cap is infinity) |
| `evil_engine.flow_node_instance.started.total` | counter | — | `[:evil_engine, :flow_node_instance, :started]` |
| `evil_engine.flow_node_instance.state_change.total` | counter | `flow_node_type`, `terminal_state` | `[:evil_engine, :flow_node_instance, :state_change]` |
| `evil_engine.event_bus.events.total` | counter | `event_type` | `[:evil_engine, :event_bus]` (telemetry sink) |
| `evil_engine.dmn.evaluations.total` | counter | `hit_policy` | `[:evil_engine, :dmn, :evaluate, :stop]` |
| `evil_engine.dmn.evaluate.duration.milliseconds` | distribution | — | same |
| `evil_engine.dmn.evaluations.exceptions.total` | counter | — | `[:evil_engine, :dmn, :evaluate, :exception]` |
| `evil_engine.dmn.cache.hit.total` | counter | — | `[:evil_engine, :dmn, :cache, :hit]` |
| `evil_engine.dmn.cache.miss.total` | counter | — | `[:evil_engine, :dmn, :cache, :miss]` |
| `evil_engine.escalation.raised.total` | counter | `throw_type` | `[:evil_engine, :escalation, :raised]` |
| `evil_engine.escalation.uncaught.total` | counter | — | `[:evil_engine, :escalation, :uncaught]` |
| `evil_engine.db.query.queue_time_ms` | distribution | `repo` | `[:evil_engine, :db, :query]` (`DbQueryHandler`) |
| `evil_engine.db.query.total_time_ms` | distribution | `repo` | same |
| `evil_engine.db.query.count` | counter | `repo`, `source` | same |
| `evil_engine.db.pool.size` | last_value | `repo` | `[:evil_engine, :db, :pool]` (poller) |
| `evil_engine.db.pool.checked_out` | last_value | `repo` | same |
| `evil_engine.db.pool.idle` | last_value | `repo` | same |
| `vm.memory.total` | last_value | — | VM poller |
| `vm.memory.processes` | last_value | — | VM poller |
| `vm.total_run_queue_lengths.total` | last_value | — | VM poller |
| `vm.total_run_queue_lengths.cpu` | last_value | — | VM poller |
| `vm.total_run_queue_lengths.io` | last_value | — | VM poller |
| `vm.system_counts.process_count` | last_value | — | VM poller |

**DB pool pressure:** `DbQueryHandler` attaches to each Repo’s Ecto `:query`
event and re-emits `[:evil_engine, :db, :query]` with millisecond
`queue_time_ms`. Checkout wait above `TDE_DB_QUEUE_TIME_WARNING_MS`
(default 500) logs a warning. `repo` is `:write` or `:read`. `source` is
the Ecto schema source, or a table name parsed from raw SQL so adapter
queries are not all `unknown`.

**Emitted `:telemetry` events with no Prometheus series** (a plugin can
attach; `/metrics` does not):

| Event | Typical site |
|-------|----------------|
| `[:evil_engine, :timer, :armed \| :fired \| :cancelled]` | `core_timers` Scheduler |
| `[:evil_engine, :message, :published \| :arrived]` | `MessagePublisher` |
| `[:evil_engine, :signal, :published \| :arrived]` | `SignalPublisher` |
| `[:evil_engine, :subprocess, :child_started]` | SubProcess / ESP spawn |
| `[:evil_engine, :transaction, :cancelled]` | Transaction cancel |
| `[:evil_engine, :process_instance, :retried]` | PI retry |
| `[:evil_engine, :model_cache, :fetch]` | BPMN `ModelCache` |

### `GET /health` and `GET /info`

Both public, no JWT.

| Endpoint | Body |
|----------|------|
| `GET /health` | empty, status 204 |
| `GET /info` | `{ "engineId", "engineName", "version", "startedAt" }` from `StatsCollector.info/0` |

Load is **not** on `/health` or `/info`. Feature flags are **not** on `/info`.

### Historical / time-series analysis

`/stats` is a point-in-time snapshot. The engine does not keep an
in-memory event ring buffer.

| Question | Where to look |
|----------|----------------|
| Current PI/FNI/user-task counts | `GET /stats` or GraphQL on kernel resources |
| Historical PI/FNI/DO/message/signal state | GraphQL / SQL on kernel tables (lane-visible) |
| Rates, latency, VM, DB pool | Prometheus scrape + operator TSDB |
| Flat typed-event log (lifecycle, plugin events, severity sweeps) | Plugin EventSink (or logs). `process_instance_events` is empty. |

### Not shipped

| Gap | Notes |
|-----|--------|
| Built-in database EventSink | Removed; see Event sinks above |
| Admin stats HTML | `/admin/` is GraphiQL + empty `EvilEngineWeb.Admin` namespace; Swagger is `GET /` ([post-v1-ideas.md](../post-v1-ideas.md) idea 11) |
| `/stats` breakdowns | `byType` / `byAssigneeRole` / `byPlugin` / `monitoringPanelsCount` are stubs |

---

## Public API / Contracts

Env vars (full table: [configuration.md](./configuration.md)):

| Variable | Default | Effect |
|----------|---------|--------|
| `TDE_EVENT_SINK_CONSOLE` | `on` | Register console sink |
| `TDE_EVENT_SINK_TELEMETRY` | `on` | Register telemetry sink (Prometheus event-bus counter) |
| `TDE_EVENT_SINK_WEBSOCKET` | `on` | Register WebSocket sink |
| `TDE_LOG_MIN_SEVERITY` | `info` | Console sink floor |
| `TDE_METRICS_ENABLED` | `true` | Start Prometheus reporter + poller; `GET /metrics` vs 404 |
| `TDE_MAX_CONCURRENT_PIS` | `infinity` | Load level, capacity gauge, admission |
| `TDE_DB_QUEUE_TIME_WARNING_MS` | `500` | DB checkout-wait warning |

EventSink behaviour: [plugins.md](./plugins.md) and
[event-system.md](./event-system.md). REST/GraphQL/WebSocket endpoint
index: [api.md](./api.md).

---

## File Path Reference

| Module | Path |
|--------|------|
| `EvilEngine.Events.EngineEventBus` | `apps/core_events/lib/evil_engine/events/engine_event_bus.ex` |
| `EvilEngine.Events.SinkRegistrar` | `apps/core_events/lib/evil_engine/events/sink_registrar.ex` |
| `EvilEngine.Events.Sinks.Console` | `apps/core_events/lib/evil_engine/events/sinks/console.ex` |
| `EvilEngine.Telemetry.Sink` | `apps/peripheral_telemetry/lib/evil_engine/telemetry/sink.ex` |
| `EvilEngine.Telemetry.StatsCollector` | `apps/peripheral_telemetry/lib/evil_engine/telemetry/stats_collector.ex` |
| `EvilEngine.Telemetry.Metrics` | `apps/peripheral_telemetry/lib/evil_engine/telemetry/metrics.ex` |
| `EvilEngine.Telemetry.Measurements` | `apps/peripheral_telemetry/lib/evil_engine/telemetry/measurements.ex` |
| `EvilEngine.Telemetry.DbQueryHandler` | `apps/peripheral_telemetry/lib/evil_engine/telemetry/db_query_handler.ex` |
| Telemetry OTP application | `apps/peripheral_telemetry/lib/evil_engine/telemetry/application.ex` |
| `EvilEngineWeb.Ws.Sinks.WebSocket` | `apps/api_web/lib/evil_engine_web/ws/sinks/websocket.ex` |
| `EvilEngineWeb.Http.StatsController` | `apps/api_web/lib/evil_engine_web/http/controllers/stats_controller.ex` |
| `EvilEngineWeb.Http.MetricsController` | `apps/api_web/lib/evil_engine_web/http/controllers/metrics_controller.ex` |
| `EvilEngineWeb.Http.HealthController` | `apps/api_web/lib/evil_engine_web/http/controllers/health_controller.ex` |
| `EvilEngineWeb.Http.InfoController` | `apps/api_web/lib/evil_engine_web/http/controllers/info_controller.ex` |
| `EvilEngineWeb.Admin` | `apps/api_web/lib/evil_engine_web/admin.ex` |

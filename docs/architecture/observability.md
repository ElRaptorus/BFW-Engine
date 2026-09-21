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
| `GET /metrics` | none | Prometheus text exposition from `TelemetryMetricsPrometheus.Core`. Disabled with `BFE_METRICS_ENABLED=false` → HTTP 404 `metrics_disabled`. |
| `GET /health` | none | Liveness probe: **204 No Content**, empty body. |
| `GET /info` | none | Engine id, name, version, `startedAt`. |
| WebSocket EventSink | JWT (channel join) | Live `BfwEngine.Types.Event.*` push to Phoenix Channels. |
| Plugin EventSinks | n/a | Operator-authored destinations (Datadog, Kafka, webhook, …). |

`GET /admin/graphiql` is the GraphQL playground (devtools-gated). Swagger UI
is `GET /`. There is no stats dashboard at `/admin/`.

### Event sinks

Everything typed the engine emits at runtime (PI/FNI transitions, messages,
signals, timers, Data Object writes, escalation/compensation, deploy, sink
failures) is published with `EngineEventBus.publish/1`. Each registered
`@behaviour BfwEngine.Plugin.EventSink` receives the event independently
(at-most-once, crash-isolated). Catalog and dispatch: [event-system.md](./event-system.md).

Built-in sinks registered at boot by `BfwEngine.Events.SinkRegistrar`:

| Sink | Module | Default | Filter | Operator effect |
|------|--------|---------|--------|-----------------|
| `console` | `BfwEngine.Events.Sinks.Console` | ON (`BFE_EVENT_SINK_CONSOLE`) | `BFE_LOG_MIN_SEVERITY` (default `info`; `error` / `warn` / `info` / `debug` / `verbose`) | Logger line per accepted event. `SinkFailed` is never accepted. |
| `telemetry` | `BfwEngine.Telemetry.Sink` | ON (`BFE_EVENT_SINK_TELEMETRY`) | none (`accepts?/1` always true) | Increments `[:bfw_engine, :event_bus]` (Prometheus `bfw_engine.event_bus.events.total` by `event_type`). **Does not feed `/stats`.** |
| `websocket` | `BfwEngineWeb.Ws.Sinks.WebSocket` | ON (`BFE_EVENT_SINK_WEBSOCKET`) | rejects only `SinkFailed` | Phoenix.PubSub broadcast to `engine:events`, `process_instance:<id>`, root-PI fan-out, and `user_tasks:pending` where applicable. |

Plugin sinks register from `on_load/1` via
`facade.register_event_sink.(name, module, opts)`.

**Database sink removed.** There is no `BfwEngine.Events.Sinks.Database`,
no `BFE_EVENT_SINK_DATABASE`, and no GraphQL resource over a typed-event
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

`BFE_LOG_MIN_SEVERITY` is the floor. Engine-internal Logger calls outside
the bus (startup, sink-registration warnings, DB pool-pressure warnings,
API `ErrorResponse`, GraphQL `ErrorLogger`) share the same Logger backend.
In production that backend is `logger_json` (`{:logger_json, "~> 7.0", only: :prod}`).
Mix retention purge logs counts to stdout; there is no RetentionRunner heartbeat.

API error audit: [api.md](./api.md) §Audit-trail logging.

### `GET /stats`

JWT-gated. `BfwEngineWeb.Http.StatsController` camelizes
`BfwEngine.Telemetry.StatsCollector.snapshot/0`. Assembly is **live
queries on request**, not a counter cache:

| Block | Source |
|-------|--------|
| `engine` | `:peripheral_telemetry` config, `:core_execution` app vsn, `:persistent_term` start time, load from `DynamicSupervisor.count_children(BfwEngine.Execution.Supervisor)` vs `BFE_MAX_CONCURRENT_PIS` |
| `processInstances` | Ash `count` on `ProcessInstance` per state `running` / `finished` / `fatal` / `aborted` / `error` |
| `flowNodeInstances` | Ash `count` on `FlowNodeInstance` per state including `waiting` / `interrupted` / `error` |
| `userTasksPending.count` | waiting `user_task` FNIs |
| `asyncFlowNodes.waiting` | waiting FNIs that are not user tasks |
| `timers` | Scheduler ETS `:bfw_engine_timers_primary` size + count with `fire_at` ≤ now+60s |
| `plugins` | `BfwEngine.Plugins.Registry.list_plugins/0` |
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
`BFE_MAX_CONCURRENT_PIS` when the cap is a positive integer; always
`normal` when the cap is `:infinity`. The same thresholds drive
`Event.EngineOverloaded` / `Event.EngineRecovered` from the 10s poller
(crossings only, not every tick).

`plugins` is the registry list (`name`, `module`, `manifest`, `status`,
`registeredAt`), not `{loaded, quarantined}`.

### `GET /metrics`

Public Prometheus text (`text/plain`). Definitions:
`BfwEngine.Telemetry.Metrics.metrics/0`. The reporter plus
`:telemetry_poller` (period 10s) start only when
`:peripheral_telemetry, :metrics_enabled` is true.

Scrape names use underscores (dots in the Telemetry.Metrics name become
`_`). Catalog:

| Telemetry.Metrics name | Type | Labels | Source event |
|------------------------|------|--------|--------------|
| `bfw_engine.http.request.total` | counter | `method`, `route`, `status` | `[:bfw_engine, :http, :stop]` (`Plug.Telemetry`) |
| `bfw_engine.http.request.duration_ms` | distribution | — | same |
| `bfw_engine.process_instance.state_change.total` | counter | `old_state`, `new_state` | `[:bfw_engine, :process_instance, :state_change]` |
| `bfw_engine.process_instance.active.count` | last_value | — | `[:bfw_engine, :process_instance, :active]` (poller) |
| `bfw_engine.process_instance.capacity.ratio` | last_value | — | `[:bfw_engine, :process_instance, :capacity]` (poller; `0.0` when cap is infinity) |
| `bfw_engine.flow_node_instance.started.total` | counter | — | `[:bfw_engine, :flow_node_instance, :started]` |
| `bfw_engine.flow_node_instance.state_change.total` | counter | `flow_node_type`, `terminal_state` | `[:bfw_engine, :flow_node_instance, :state_change]` |
| `bfw_engine.event_bus.events.total` | counter | `event_type` | `[:bfw_engine, :event_bus]` (telemetry sink) |
| `bfw_engine.dmn.evaluations.total` | counter | `hit_policy` | `[:bfw_engine, :dmn, :evaluate, :stop]` |
| `bfw_engine.dmn.evaluate.duration.milliseconds` | distribution | — | same |
| `bfw_engine.dmn.evaluations.exceptions.total` | counter | — | `[:bfw_engine, :dmn, :evaluate, :exception]` |
| `bfw_engine.dmn.cache.hit.total` | counter | — | `[:bfw_engine, :dmn, :cache, :hit]` |
| `bfw_engine.dmn.cache.miss.total` | counter | — | `[:bfw_engine, :dmn, :cache, :miss]` |
| `bfw_engine.escalation.raised.total` | counter | `throw_type` | `[:bfw_engine, :escalation, :raised]` |
| `bfw_engine.escalation.uncaught.total` | counter | — | `[:bfw_engine, :escalation, :uncaught]` |
| `bfw_engine.db.query.queue_time_ms` | distribution | `repo` | `[:bfw_engine, :db, :query]` (`DbQueryHandler`) |
| `bfw_engine.db.query.total_time_ms` | distribution | `repo` | same |
| `bfw_engine.db.query.count` | counter | `repo`, `source` | same |
| `bfw_engine.db.pool.size` | last_value | `repo` | `[:bfw_engine, :db, :pool]` (poller) |
| `bfw_engine.db.pool.checked_out` | last_value | `repo` | same |
| `bfw_engine.db.pool.idle` | last_value | `repo` | same |
| `vm.memory.total` | last_value | — | VM poller |
| `vm.memory.processes` | last_value | — | VM poller |
| `vm.total_run_queue_lengths.total` | last_value | — | VM poller |
| `vm.total_run_queue_lengths.cpu` | last_value | — | VM poller |
| `vm.total_run_queue_lengths.io` | last_value | — | VM poller |
| `vm.system_counts.process_count` | last_value | — | VM poller |

**DB pool pressure:** `DbQueryHandler` attaches to each Repo’s Ecto `:query`
event and re-emits `[:bfw_engine, :db, :query]` with millisecond
`queue_time_ms`. Checkout wait above `BFE_DB_QUEUE_TIME_WARNING_MS`
(default 500) logs a warning. `repo` is `:write` or `:read`. `source` is
the Ecto schema source, or a table name parsed from raw SQL so adapter
queries are not all `unknown`.

**Emitted `:telemetry` events with no Prometheus series** (a plugin can
attach; `/metrics` does not):

| Event | Typical site |
|-------|----------------|
| `[:bfw_engine, :timer, :armed \| :fired \| :cancelled]` | `core_timers` Scheduler |
| `[:bfw_engine, :message, :published \| :arrived]` | `MessagePublisher` |
| `[:bfw_engine, :signal, :published \| :arrived]` | `SignalPublisher` |
| `[:bfw_engine, :subprocess, :child_started]` | SubProcess / ESP spawn |
| `[:bfw_engine, :transaction, :cancelled]` | Transaction cancel |
| `[:bfw_engine, :process_instance, :retried]` | PI retry |
| `[:bfw_engine, :model_cache, :fetch]` | BPMN `ModelCache` |

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
| Admin stats HTML | `/admin/` is GraphiQL + empty `BfwEngineWeb.Admin` namespace; Swagger is `GET /` ([post-v1-ideas.md](../post-v1-ideas.md) idea 7) |
| `/stats` breakdowns | `byType` / `byAssigneeRole` / `byPlugin` / `monitoringPanelsCount` are stubs |

---

## Public API / Contracts

Env vars (full table: [configuration.md](./configuration.md)):

| Variable | Default | Effect |
|----------|---------|--------|
| `BFE_EVENT_SINK_CONSOLE` | `on` | Register console sink |
| `BFE_EVENT_SINK_TELEMETRY` | `on` | Register telemetry sink (Prometheus event-bus counter) |
| `BFE_EVENT_SINK_WEBSOCKET` | `on` | Register WebSocket sink |
| `BFE_LOG_MIN_SEVERITY` | `info` | Console sink floor |
| `BFE_METRICS_ENABLED` | `true` | Start Prometheus reporter + poller; `GET /metrics` vs 404 |
| `BFE_MAX_CONCURRENT_PIS` | `infinity` | Load level, capacity gauge, admission |
| `BFE_DB_QUEUE_TIME_WARNING_MS` | `500` | DB checkout-wait warning |

EventSink behaviour: [plugins.md](./plugins.md) and
[event-system.md](./event-system.md). REST/GraphQL/WebSocket endpoint
index: [api.md](./api.md).

---

## File Path Reference

| Module | Path |
|--------|------|
| `BfwEngine.Events.EngineEventBus` | `apps/core_events/lib/bfw_engine/events/engine_event_bus.ex` |
| `BfwEngine.Events.SinkRegistrar` | `apps/core_events/lib/bfw_engine/events/sink_registrar.ex` |
| `BfwEngine.Events.Sinks.Console` | `apps/core_events/lib/bfw_engine/events/sinks/console.ex` |
| `BfwEngine.Telemetry.Sink` | `apps/peripheral_telemetry/lib/bfw_engine/telemetry/sink.ex` |
| `BfwEngine.Telemetry.StatsCollector` | `apps/peripheral_telemetry/lib/bfw_engine/telemetry/stats_collector.ex` |
| `BfwEngine.Telemetry.Metrics` | `apps/peripheral_telemetry/lib/bfw_engine/telemetry/metrics.ex` |
| `BfwEngine.Telemetry.Measurements` | `apps/peripheral_telemetry/lib/bfw_engine/telemetry/measurements.ex` |
| `BfwEngine.Telemetry.DbQueryHandler` | `apps/peripheral_telemetry/lib/bfw_engine/telemetry/db_query_handler.ex` |
| Telemetry OTP application | `apps/peripheral_telemetry/lib/bfw_engine/telemetry/application.ex` |
| `BfwEngineWeb.Ws.Sinks.WebSocket` | `apps/api_web/lib/bfw_engine_web/ws/sinks/websocket.ex` |
| `BfwEngineWeb.Http.StatsController` | `apps/api_web/lib/bfw_engine_web/http/controllers/stats_controller.ex` |
| `BfwEngineWeb.Http.MetricsController` | `apps/api_web/lib/bfw_engine_web/http/controllers/metrics_controller.ex` |
| `BfwEngineWeb.Http.HealthController` | `apps/api_web/lib/bfw_engine_web/http/controllers/health_controller.ex` |
| `BfwEngineWeb.Http.InfoController` | `apps/api_web/lib/bfw_engine_web/http/controllers/info_controller.ex` |
| `BfwEngineWeb.Admin` | `apps/api_web/lib/bfw_engine_web/admin.ex` |

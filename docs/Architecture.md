# ThomasTheDaemonEngine — Architecture

This is the engine's architectural overview: the umbrella layout, the
dependency rules, and where each subsystem lives. Detailed specifications
are in [`architecture/`](./architecture/index.md). Everyday usage is in the
[user handbook](./guides/getting-started/overview.md).

## 1. How to read this

The engine is an **Elixir umbrella**. Each box below is one `apps/`
directory. The layout is a **triangle**: wire surfaces at the top, the
shared service layer `EvilEngine.Api` at the apex, Core and Peripheral
side-by-side as the base.

Arrows show the **permitted** direction of runtime dependencies:

- **API wire → `EvilEngine.Api` → Core / Peripheral** for commands.
- **Core → Peripheral / External** for typed events via `EngineEventBus`.
- **Core never calls API.** Peripheral never blocks Core.
- **Plugins are in-BEAM OTP applications** loaded into the release. They
  call `EvilEngine.Api` **directly** — no HTTP round-trip, no JSON
  re-encode. There is no sidecar / gRPC plugin host.

## 2. Overview

The engine uses domain-driven design in three layers:

- **API** — public interfaces (REST, GraphQL, WebSocket, JWT)
- **Peripheral** — plugin host, telemetry, persistence
- **Core** — BPMN / DMN execution, FEEL, timers, event bus

Each subsystem is a separate OTP application under `apps/`:

```
apps/
├── core_types/              # Shared, behaviour-free structs
├── core_execution/          # PI/FNI runtime
├── core_expressions/        # FEEL evaluator
├── core_bpmn/               # XML parser, AST, ModelCache, linter gate
├── core_dmn/                # DMN 1.5 CL3 decision engine
├── core_timers/             # Timer scheduler, ISO 8601 parser, StartEventManager
├── core_events/             # EngineEventBus + built-in sinks
├── api_facade/              # EvilEngine.Api service-layer facade
├── api_web/                 # REST + GraphQL + WebSocket + Admin
├── api_auth/                # JWT validator (HS256 / RS256 / ES256 / JWKS)
├── peripheral_persistence/  # Ash + AshPostgres (mix evil.retention.purge)
├── peripheral_telemetry/    # :telemetry counters, GET /metrics, GET /stats
├── peripheral_plugins/      # Plugin registry + in-BEAM loader
└── engine_sdk/              # Public behaviours for plugin authors
```

Dependency direction is strictly inward: `API → Peripheral → Core`.
`engine_sdk` re-exports only — it never owns types.

## 3. Layer-by-layer reading guide

### 3.1 API wire surfaces

Two `api_*` apps form the wire surface. `api_web` is a thin adapter over
HTTP / GraphQL / WebSocket: it translates a wire request into a call on
`EvilEngine.Api`. All authenticated ingress passes through `api_auth`.
REST handles trigger-style commands; GraphQL handles complex queries over
the Ash read-model plus the Process Model graph. WebSocket is both
ingress (clients joining PI topics) and egress (the `websocket` EventSink
pushes typed events to subscribers).

Module namespaces (`EvilEngineWeb.Http.*`, `EvilEngineWeb.Ws.*`,
`EvilEngineWeb.Graphql.*`) live inside the single `api_web` app.

### 3.2 Shared service layer — `EvilEngine.Api`

`EvilEngine.Api` is an Ash Code Interface: every engine action
(`start_process_instance/2`, `publish_message/3`, `retry_pi/2`, …) is a
plain Elixir function. Every wire adapter and every plugin converges here:

| Caller | Path |
|--------|------|
| REST controller in `api_web` | `EvilEngine.Api.start_process_instance(input, actor)` |
| GraphQL resolver in `api_web` | same function, after Absinthe decoding |
| WebSocket handler in `api_web` | same function, after channel decoding |
| In-BEAM plugin | **same function — no HTTP round-trip, no JSON re-encode, no auth replay** |

Validation, authorization, and audit hooks live **inside** the Ash
action, so every caller gets identical enforcement. No code path bypasses
the service layer to reach Core or Persistence for commands. Plugins may
register EventSinks and handlers on `EngineEventBus` / the plugin
registry; that is event-level integration, not a command bypass.

Process-instance tree hard-delete is `mix evil.retention.purge` (and the
matching release eval). There is no REST purge endpoint.

### 3.3 Core layer

No Core app imports from API or Peripheral. Runtime services collaborate
around `core_types` for shared, behaviour-free structs. `core_bpmn` owns
the canonical in-memory Process Model AST via `EvilEngine.BPMN.ModelCache`
(per-node, ETS-backed). Handlers and resolvers read the cache; they do
not re-parse XML at runtime.

`core_events` hosts:

- In-process `Phoenix.PubSub` topics for intra-engine coordination
  (subscriptions, correlation registries, pending-event TTL sweeper).
- The public `EngineEventBus`, which fans out every typed
  `EvilEngine.Types.Event.*` to every registered
  `@behaviour EvilEngine.Plugin.EventSink`. **This is the only channel
  through which observability, audit logging, and external integrations
  see engine events.**

### 3.4 Peripheral layer

Three concerns, all decoupled from Core:

1. **`peripheral_persistence`** — Ash resources, AshPostgres migrations,
   `mix evil.partitions.ensure`, and `mix evil.retention.purge` for
   opt-in hard-delete of aged terminal process-instance trees. Receives
   writes from `core_execution` via Ash actions.
2. **`peripheral_telemetry`** — in-process `:telemetry` counters that
   back `GET /stats`, plus the built-in Prometheus scrape at
   `GET /metrics` (`TDE_METRICS_ENABLED`, default on). OpenTelemetry
   does not ship.
3. **`peripheral_plugins`** — plugin registry, in-BEAM loader, quarantine.
   Plugins register under a supervised task tree so a crashing plugin
   cannot take down the engine. Plugin EventSinks attach here on the way
   back into `EngineEventBus`.

### 3.5 EventSink fan-out

Every `Event.*` published via `EngineEventBus.publish/1` fans out in
parallel to every sink that returned `true` from `accepts?/2`. Built-in
sinks:

| Sink | Default | Purpose |
|------|---------|---------|
| `console` | **ON** | `logger_json` → stdout |
| `telemetry` | **ON** | Increments `/stats` counters |
| `websocket` | **ON** | Phoenix.Channels push to connected clients |

The engine does not persist typed events to Postgres. The
`process_instance_events` table exists for schema compatibility and is
not populated by any built-in sink. Operators who need DB-backed event
storage register a plugin sink.

Plugin sinks register from `on_load/1` via
`facade.register_event_sink.(name, module, opts)`. Typical deployments:
Datadog, Kafka, a custom archive. Prometheus **scrape** is built-in
(`GET /metrics`); a plugin sink is only needed if you want a different
metrics wire format.

### 3.6 External surface

- **The Studio** depends on `@elraptorus/daemonengine_client` (which
  depends on `@elraptorus/daemonengine_sdk`). No SQL, no PubSub, no gRPC
  coupling.
- **Other clients** (CLIs, dashboards) use the same REST + GraphQL +
  WebSocket surfaces.
- **PostgreSQL** is the sole persistent backend. The engine owns its
  schema via AshPostgres. Six tables are range-partitioned by timestamp
  (`process_instance_events`, `data_object_writes`, `messages`,
  `pending_messages`, `signals`, `pending_signals`). Boot pre-creates
  `TDE_PARTITION_AHEAD_MONTHS` future partitions.
- **The Seeding Directory** (`TDE_SEEDING_DIRECTORY`) is scanned once at
  boot; every `*.bpmn` file is deployed through the same path as
  `POST /processes`, including the linter-score gate.
- **Observability**: structured logs, JWT-gated `GET /stats`, public
  `GET /metrics` (Prometheus text). Further destinations are plugin
  EventSinks. OpenTelemetry does not ship.

## 4. Mapping to documentation

| Topic | Document |
|-------|----------|
| Everyday usage | [`guides/getting-started/overview.md`](./guides/getting-started/overview.md) |
| Runtime (PI / FNI / handlers) | [`architecture/execution.md`](./architecture/execution.md) |
| Event bus + EventSinks | [`architecture/event-system.md`](./architecture/event-system.md) |
| Timer scheduler | [`architecture/timers.md`](./architecture/timers.md) |
| Message / Signal / Escalation routing | [`architecture/routing.md`](./architecture/routing.md) |
| FEEL | [`architecture/expressions.md`](./architecture/expressions.md) |
| Plugins & SDKs | [`architecture/plugins.md`](./architecture/plugins.md) |
| Engine facade (plugin authors) | [`guides/plugins/engine-facade.md`](./guides/plugins/engine-facade.md) |
| REST + GraphQL + WS | [`architecture/api.md`](./architecture/api.md) |
| `/stats` + `/health` + `/metrics` | [`architecture/observability.md`](./architecture/observability.md) |
| Persistence schema | [`architecture/data-model.md`](./architecture/data-model.md) |
| Persistence (dual pool) | [`architecture/persistence.md`](./architecture/persistence.md) |
| DMN decision engine | [`architecture/dmn.md`](./architecture/dmn.md) |
| TypeScript SDK & client | [`architecture/sdk-client.md`](./architecture/sdk-client.md) |
| Retention, payload cap, compression | [`guides/operations/database.md`](./guides/operations/database.md) |
| Configuration (env vars) | [`architecture/configuration.md`](./architecture/configuration.md) |
| Shipping & deployment | [`guides/operations/deployment.md`](./guides/operations/deployment.md) |
| Testing strategy | [`architecture/testing.md`](./architecture/testing.md) |
| Security | [`architecture/security.md`](./architecture/security.md) |
| JWT auth + authorization | [`architecture/authorization.md`](./architecture/authorization.md) |
| Architecture detail index | [`architecture/index.md`](./architecture/index.md) |
| Decision log | [`decisions.md`](./decisions.md) |
| Post-v1 ideas | [`post-v1-ideas.md`](./post-v1-ideas.md) |
| Glossary | [`Glossary.md`](./Glossary.md) |
| Database schema diagram | [`Schema.md`](./Schema.md) |

# Bifrost Forge World Engine — Architecture

This is the engine's architectural overview: the source layout, the
dependency rules, and where each subsystem lives. Detailed specifications
are in [`architecture/`](./architecture/index.md). Everyday usage is in the
[user handbook](./guides/getting-started/overview.md).

## 1. How to read this

The engine is **one OTP application**, `:bfw_engine`. Each subsystem is a
compile-time boundary under `lib/`, and the boundaries form five layers.
A layer may call only the layers below it (and boundaries of its own layer
that the table in §Subsystem Boundaries lists):

| Layer | Boundaries | Role |
|-------|------------|------|
| Wire | `BfwEngineWeb` | REST, GraphQL, WebSocket, Admin |
| Plugin host | `BfwEngine.Plugins` | Plugin registry and in-BEAM loader; plugins call `BfwEngine.Api` |
| API | `BfwEngine.Api`, `BfwEngine.Auth` | Shared service layer; JWT validation |
| Peripheral | `BfwEngine.Persistence`, `BfwEngine.Telemetry` | Ash + PostgreSQL; metrics and `/stats` |
| Core | `BfwEngine.Types`, `Expressions`, `Timers`, `BPMN`, `DMN`, `Events`, `Execution`, plus the plugin contracts `BfwEngine.Plugin` and `BfwEngine.EngineFacade` | BPMN / DMN execution, FEEL, timers, event bus |

- **Commands** flow downward: wire → `BfwEngine.Api` → Core / Peripheral.
- **Typed events** flow outward through `EngineEventBus` to the registered
  EventSinks (Peripheral, wire, plugins) without Core naming any of them.
- **Ports and adapters:** Core defines behaviours (for example
  `BfwEngine.Execution.Persistence`); Peripheral implements them and Core
  reaches the adapter only through configuration.
- **Plugins are in-BEAM OTP applications** loaded into the release. They
  call `BfwEngine.Api` **directly** — no HTTP round-trip, no JSON
  re-encode.

## 2. Overview

Each subsystem is a boundary inside the single app:

```
lib/
├── bfw_engine/
│   ├── types/            # Shared, behaviour-free structs
│   ├── execution/        # PI/FNI runtime
│   ├── expressions/      # FEEL evaluator (NIF crate in native/feel_nif/)
│   ├── bpmn/             # XML parser, AST, ModelCache, linter gate
│   ├── dmn/              # DMN 1.5 CL3 decision engine
│   ├── timers/           # Timer scheduler, ISO 8601 parser, StartEventManager
│   ├── events/           # EngineEventBus + built-in sinks
│   ├── api/              # BfwEngine.Api service-layer facade
│   ├── auth/             # JWT validator (HS256 / RS256 / ES256 / JWKS)
│   ├── persistence/      # Ash + AshPostgres (mix bfw.retention.purge)
│   ├── telemetry/        # :telemetry counters, GET /metrics, GET /stats
│   ├── plugins/          # Plugin registry + in-BEAM loader
│   ├── plugin/           # Internal plugin contracts (behaviours)
│   └── engine_facade/    # Facade closures handed to plugins
├── bfw_engine_web/       # REST + GraphQL + WebSocket + Admin
└── mix/tasks/            # bfw.* Mix tasks
```

Dependency direction is strictly inward: Wire → Plugin host → API → Peripheral → Core.

### Subsystem Boundaries

Every subsystem root module (`lib/bfw_engine/<subsystem>.ex`,
`lib/bfw_engine_web.ex`) declares `use Boundary, deps: [...], exports: [...]`.
The `:boundary` compiler runs before the Elixir compiler; with
`--warnings-as-errors` a call into an undeclared boundary, or into a module
the target does not export, fails the build. Mix tasks, `BfwEngine.Application`
and test support modules are unchecked boundaries.

| Boundary | May call |
|----------|----------|
| `BfwEngine.Types` | — |
| `BfwEngine.Expressions` | Types |
| `BfwEngine.Timers` | Types |
| `BfwEngine.BPMN` | Types, Expressions, Timers |
| `BfwEngine.DMN` | Types, Expressions |
| `BfwEngine.Plugin` | Types, BPMN |
| `BfwEngine.EngineFacade` | Types, BPMN |
| `BfwEngine.Events` | Types, Plugin |
| `BfwEngine.Execution` | Types, Expressions, Timers, Events, BPMN, DMN |
| `BfwEngine.Persistence` | Types, BPMN, Timers, Events, Execution, Plugin, EngineFacade |
| `BfwEngine.Api` | Types, Timers, Events, BPMN, DMN, Execution, Persistence |
| `BfwEngine.Plugins` | Types, Events, DMN, Execution, Expressions, Plugin, EngineFacade, Api |
| `BfwEngine.Telemetry` | Types, Events, Timers, Persistence, Plugin |
| `BfwEngine.Auth` | Types, Plugin |
| `BfwEngineWeb` | every boundary above; nothing may call it |

`BfwEngine.Plugin` and `BfwEngine.EngineFacade` are internal plugin
contracts, not a public SDK: they hold exactly what the engine needs to load
and call in-BEAM plugins. Plugins depend on `:bfw_engine` itself.

`BfwEngine.Application` starts one supervisor per subsystem in this order:
Timers, BPMN, Events, DMN, Execution, Persistence, Plugins, Telemetry, Auth,
Web (`max_restarts: 0` on the root, so a crashed subsystem stops the node).
`prep_stop/1` shuts process instances down, publishes `EngineShutdown`, and
flushes the event sinks before any subsystem stops.

## 3. Layer-by-layer reading guide

### 3.1 API wire surfaces

`BfwEngineWeb` is the wire surface, a thin adapter over HTTP / GraphQL /
WebSocket: it translates a wire request into a call on `BfwEngine.Api`.
All authenticated ingress passes through `BfwEngine.Auth`.
REST handles trigger-style commands; GraphQL handles complex queries over
the Ash read-model plus the Process Model graph. WebSocket is both
ingress (clients joining PI topics) and egress (the `websocket` EventSink
pushes typed events to subscribers).

Module namespaces (`BfwEngineWeb.Http.*`, `BfwEngineWeb.Ws.*`,
`BfwEngineWeb.Graphql.*`) live inside the single `BfwEngineWeb` boundary.

### 3.2 Shared service layer — `BfwEngine.Api`

`BfwEngine.Api` is an Ash Code Interface: every engine action
(`start_process_instance/2`, `publish_message/3`, `retry_pi/2`, …) is a
plain Elixir function. Every wire adapter and every plugin converges here:

| Caller | Path |
|--------|------|
| REST controller in `BfwEngineWeb` | `BfwEngine.Api.start_process_instance(input, actor)` |
| GraphQL resolver in `BfwEngineWeb` | same function, after Absinthe decoding |
| WebSocket handler in `BfwEngineWeb` | same function, after channel decoding |
| In-BEAM plugin | **same function — no HTTP round-trip, no JSON re-encode, no auth replay** |

Validation, authorization, and audit hooks live **inside** the Ash
action, so every caller gets identical enforcement. No code path bypasses
the service layer to reach Core or Persistence for commands. Plugins may
register EventSinks and handlers on `EngineEventBus` / the plugin
registry; that is event-level integration, not a command bypass.

Process-instance tree hard-delete is `mix bfw.retention.purge` (and the
matching release eval). There is no REST purge endpoint.

### 3.3 Core layer

No Core boundary calls API, Peripheral, the plugin host, or the wire layer. Runtime services collaborate
around `BfwEngine.Types` for shared, behaviour-free structs. `BfwEngine.BPMN` owns
the canonical in-memory Process Model AST via `BfwEngine.BPMN.ModelCache`
(per-node, ETS-backed). Handlers and resolvers read the cache; they do
not re-parse XML at runtime.

`BfwEngine.Events` hosts:

- In-process `Phoenix.PubSub` topics for intra-engine coordination
  (subscriptions, correlation registries, pending-event TTL sweeper).
- The public `EngineEventBus`, which fans out every typed
  `BfwEngine.Types.Event.*` to every registered
  `@behaviour BfwEngine.Plugin.EventSink`. **This is the only channel
  through which observability, audit logging, and external integrations
  see engine events.**

### 3.4 Peripheral layer

Two concerns, both decoupled from Core:

1. **`BfwEngine.Persistence`** — Ash resources, AshPostgres migrations,
   `mix bfw.partitions.ensure`, and `mix bfw.retention.purge` for
   opt-in hard-delete of aged terminal process-instance trees. Implements
   the Core persistence behaviours; Core reaches it only through
   configuration.
2. **`BfwEngine.Telemetry`** — Prometheus scrape at `GET /metrics`
   (`BFE_METRICS_ENABLED`, default on), the telemetry EventSink (event-bus
   counters), and `StatsCollector` for JWT `GET /stats` (live Ash/ETS
   snapshot, not those counters). The `plugins` entry of `/stats` is added
   by `BfwEngineWeb.Http.StatsController`, so Telemetry never reaches the
   plugin host.

### 3.5 Plugin host

**`BfwEngine.Plugins`** — plugin registry, in-BEAM loader, boot-time
quarantine. It sits above `BfwEngine.Api` because the facade closures it
hands to plugins call the service layer. A raising Service Task or Named
Script handler fails only its flow node, and a raising EventSink is
rescued by its worker; see [plugins.md](architecture/plugins.md) for the
isolation model. Plugin EventSinks attach here on the way back into
`EngineEventBus`.

### 3.6 EventSink fan-out

Every `Event.*` published via `EngineEventBus.publish/1` fans out in
parallel to every sink that returned `true` from `accepts?/2`. Built-in
sinks:

| Sink | Default | Purpose |
|------|---------|---------|
| `console` | **ON** | `logger_json` → stdout |
| `telemetry` | **ON** | Increments Prometheus `bfw_engine.event_bus.events.total` |
| `websocket` | **ON** | Phoenix.Channels push to connected clients |

The engine does not persist typed events to Postgres. Operators who need
DB-backed event storage register a plugin sink.

Plugin sinks register from `on_load/1` via
`facade.register_event_sink.(name, module, opts)`. Typical deployments:
Datadog, Kafka, a custom archive. Prometheus **scrape** is built-in
(`GET /metrics`); a plugin sink is only needed if you want a different
metrics wire format.

### 3.7 External surface

- **The Studio** depends on `@elraptorus/bfw_engine_client` (which
  depends on `@elraptorus/bfw_engine_sdk`). No SQL, no PubSub, no gRPC
  coupling.
- **Other clients** (CLIs, dashboards) use the same REST + GraphQL +
  WebSocket surfaces.
- **PostgreSQL** is the sole persistent backend. The engine owns its
  schema via AshPostgres. Five tables are range-partitioned by timestamp
  (`data_object_writes`, `messages`,
  `pending_messages`, `signals`, `pending_signals`). Boot pre-creates
  `BFE_PARTITION_AHEAD_MONTHS` future partitions.
- **The Seeding Directory** (`BFE_SEEDING_DIRECTORY`) is scanned once at
  boot; every `*.bpmn` file is deployed through the same path as
  `POST /processes`, including the linter-score gate.
- **Observability**: structured logs, JWT-gated `GET /stats`, public
  `GET /metrics` (Prometheus text). Further destinations are plugin
  EventSinks.

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
| Post-v1 ideas | [`post-v1-ideas.md`](./post-v1-ideas.md) |
| Glossary | [`Glossary.md`](./Glossary.md) |
| Database schema diagram | [`Schema.md`](./Schema.md) |

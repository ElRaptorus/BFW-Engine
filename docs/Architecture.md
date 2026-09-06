# Daemon Engine — Architecture Diagram

> **Companion document to [`ImplementationPlan.md`](./ImplementationPlan.md)
> and the [`architecture/`](./architecture/index.md) detail documents.**
> This file shows the engine's architecture as a single conceptual picture.
> Detailed specifications for each subsystem live in `docs/architecture/*.md`;
> `ImplementationPlan.md` retains the decision log (§0), runtime specs, and
> testing strategy. Every box below is cross-referenced to a document in §4.

## 1. How to read this

The engine is an **Elixir umbrella project** whose boxes below correspond
one-to-one to the `apps/` directories listed in `ImplementationPlan.md` §2.
The diagram is laid out as a **triangle**: external actors + wire surfaces
at the top, the shared service layer `EvilEngine.Api` at the apex, and the
Core and Peripheral domains side-by-side as the base.

Arrows show the **permitted** direction of runtime dependencies:

- **API wire → `EvilEngine.Api` → Core / Peripheral** for commands (ingress flow).
- **Core → Peripheral / External** for typed events via `EngineEventBus` (egress flow).
- **Core never calls API.** Peripheral never blocks Core.
- **Plugins live at the edges** (`peripheral_plugins`, loaded in-BEAM in v1;
  a gRPC sidecar host is deferred, PLUG-D1) and call `EvilEngine.Api` **directly** for commands
  — no HTTP round-trip, no wire-format re-encode.

## 2. Overview

The Engine uses domain driven design and is basically cut into three rough domains:

- API: Public interfaces for accessing the Engine
- Periphery: Plugin Host, Telemetry, Persistence Layer, etc.
- Core: The actual heart of the Engine, where all the BPMN magic happens

Each DDD subsystem is a separate OTP application under `apps/`:

```
apps/
├── core_types/              # Shared, behaviour-free structs
├── core_execution/          # PI/FNI runtime
├── core_expressions/        # FEEL evaluator, identity resolver
├── core_bpmn/               # XML parser, AST, ModelCache, linter gate
├── core_dmn/                # DMN 1.5 CL3 decision engine
├── core_timers/             # Timer scheduler (ETS + tick + cycle re-arm), ISO 8601 parser, StartEventManager
├── core_events/             # EngineEventBus + built-in sinks
├── api_facade/              # EvilEngine.Api service-layer facade
├── api_web/                 # REST + GraphQL + WebSocket + Admin
├── api_auth/                # JWT validator (HS256 / RS256 / ES256 / JWKS)
├── peripheral_persistence/  # Ash + AshPostgres (mix evil.retention.purge; no RetentionRunner)
├── peripheral_telemetry/    # :telemetry counters backing /stats
├── peripheral_plugins/      # Plugin registry + in-BEAM loader (gRPC sidecar deferred, PLUG-D1)
└── engine_sdk/              # Public behaviours for plugin authors
```

Dependency direction is strictly inward: `API → Peripheral → Core`. `engine_sdk`
re-exports only — it never owns types.

## 3. Layer-by-layer reading guide

### 3.1 API wire surfaces (blue)

Two `api_*` apps form the wire surface. `api_web` is a **thin adapter
over HTTP / GraphQL / WS** — its only job is to translate a wire request
into a call on the shared service layer (§3.2). All ingress passes through
`api_auth` for JWT validation (§13). The REST surface handles
lightweight trigger-style calls; GraphQL handles complex queries over the
Ash read-model plus the Process Model graph. The WebSocket layer is
**both** an ingress surface (clients subscribing to PI topics) and an egress
target (the `websocket` EventSink pushes `Event.*` payloads live to
subscribed clients). Module namespaces (`EvilEngineWeb.Http.*`,
`EvilEngineWeb.Ws.*`, `EvilEngineWeb.Graphql.*`) are preserved inside the
single `api_web` app.

### 3.2 Shared service layer — `EvilEngine.Api` (darker blue)

**The triangle apex of the architecture.** `EvilEngine.Api` is an **Ash Code
Interface**: every Ash action in the engine — `start_process_instance/2`,
`publish_message/3`, `retry_pi/2`, … — is
exposed as a plain Elixir function. Manual REST purge is **deferred / not v1**
(RET-D1); operators run `mix evil.retention.purge`. Every wire adapter above and every
plugin below converges here:

| Caller                                             | Path                                                                                                                                           |
| -------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------- |
| REST controller in `api_web`                       | `EvilEngine.Api.start_process_instance(input, actor)`                                                                                          |
| GraphQL resolver in `api_web`                      | same function call, after Absinthe decoding                                                                                                    |
| WebSocket handler in `api_web`                     | same function call, after channel decoding                                                                                                     |
| In-BEAM plugin (`peripheral_plugins`, §9.2 mode 1) | **same function call — no HTTP round-trip, no JSON re-encode, no auth replay**                                                                 |
| gRPC sidecar plugin (§9.2 mode 2)                  | **Deferred (PLUG-D1).** Not implemented in v1. A future bridge in `peripheral_plugins` would decode the proto into a call on the same function |

This is the guarantee behind the diagram's heavy arrow from `peri_plugins`
to `api_svc` (labelled _direct in-process call · no HTTP_). Validation,
authorization policies, and audit hooks live **inside** the Ash action, so
every caller — wire or plugin — gets identical enforcement. No code path
bypasses the service layer to reach Core or Persistence directly; the
Core-only edges from plugins (`peri_plugins -.-> core_events`) are reserved
for event-level integration (registering handlers and EventSinks), not
commands.

### 3.3 Core layer (green)

No Core domain imports from any API or Peripheral domain (§2). The five
runtime services collaborate around `core_types` for shared, behavior-free
structs — there is no diamond dependency. `core_bpmn` owns the canonical
in-memory Process Model AST (§2.1.3) via `EvilEngine.BPMN.ModelCache`
(per-node, ETS-backed); every handler and resolver goes through the cache,
never re-parsing XML at runtime.

`core_events` is the heart of egress. It hosts:

- The legacy in-process `Phoenix.PubSub` topics (§3.3.1) for intra-engine
  coordination (subscriptions, correlation registries, pending-event TTL
  sweeper).
- The public `EngineEventBus` wrapping PubSub with a sink-routing stage
  that fans out every typed `EvilEngine.Types.Event.*` to every registered
  `@behaviour EvilEngine.Plugin.EventSink`. **This is the only channel through
  which observability, audit logging, and external integrations ever see
  engine events.**

### 3.4 Peripheral layer (pink)

Three distinct concerns, all decoupled from Core:

1. **`peripheral_persistence`** — Ash resources + AshPostgres migrations +
   the `mix evil.partitions.ensure` Mix task and `mix evil.retention.purge`
   for opt-in hard-delete of aged terminal process-instance trees.
   Receives writes from `core_execution` via Ash actions. There is no
   RetentionRunner GenServer (RET-D1).
2. **`peripheral_telemetry`** — in-process `:telemetry` counters that back
   `/stats` (§11). Fed exclusively by the `telemetry` EventSink. **No
   Prometheus, no OpenTelemetry in v1 core** — those integrations ship as
   plugin sinks.
3. **`peripheral_plugins`** — plugin registry, in-BEAM loader, conflict
   detector (§9.3). A gRPC sidecar bridge is specified in §9.2.3 but deferred
   (PLUG-D1). Plugins register under a supervised task tree so a
   crashing plugin cannot take down the engine. This is also where plugin
   EventSinks live on the way back into `EngineEventBus`.

### 3.5 EventSink fan-out (dashed edges in the diagram)

Every `Event.*` published via `EngineEventBus.publish/1` fans out in parallel
to every sink that returned `true` from `accepts?/2`. Built-in sinks:

| Sink        | Default | Purpose                                                                  |
| ----------- | ------- | ------------------------------------------------------------------------ |
| `console`   | **ON**  | `logger_json` → stdout (consumed by `kubectl logs`, Loki, Cloudwatch, …) |
| `telemetry` | **ON**  | Increments `/stats` counters                                             |
| `websocket` | **ON**  | Phoenix.Channels push to connected clients (Studio debugger live view)   |

The built-in `database` sink was removed. The `process_instance_events`
table is retained for migration compatibility but is no longer populated by any
built-in sink. Operators who need DB-backed event storage register a plugin
sink instead.

Plugin sinks (rightmost box) are registered via
`EvilEngine.Plugin.Registry.register(:event_sink, …)` on boot. Typical
deployments: a Datadog sink forwarding `Event.*` to Datadog Logs, a
Prometheus-exporter plugin translating `Event.*` counters into a
Prometheus-format `/metrics` endpoint on its own plug, a Kafka sink with
internal buffering + retry for at-least-once delivery.

### 3.6 External surface

- **The Studio** depends on `@elraptorus/daemonengine_client` (which
  depends on `@elraptorus/daemonengine_sdk`). No SQL, no PubSub, no gRPC
  coupling.
- **Other clients** (CLIs, 3rd-party dashboards) use the same REST + GraphQL +
  WebSocket surfaces.
- **PostgreSQL** is the sole persistent backend. The engine owns its schema
  via AshPostgres migrations; partitioning runs nine tables
  in `PARTITION BY RANGE (timestamp)` with monthly partitions pre-created
  `TDE_PARTITION_AHEAD_MONTHS` ahead on each boot.
- **The Seeding Directory** (`TDE_SEEDING_DIRECTORY`) is scanned once at boot;
  every `*.bpmn` file is deployed through the same code path as `POST
/processes`, including the linter-score gate.
- **Observability** integrations (Prometheus, Datadog, Loki, OTel, Kafka) are
  **not built into the engine core**. They are realized by plugin EventSinks,
  keeping the core unopinionated about wire format.

## 4. Mapping to documentation

| Diagram region                                              | Architecture doc                                            | Plan section                                           |
| ----------------------------------------------------------- | ----------------------------------------------------------- | ------------------------------------------------------ |
| DDD boundaries & invariants                                 | —                                                           | §2                                                     |
| Shared service layer (`EvilEngine.Api`, Ash Code Interface) | [`plugins.md`](./architecture/plugins.md) §9.2.5            | §2.2                                                   |
| Parsed Process Model AST + ModelCache                       | —                                                           | §2.1.3                                                 |
| Runtime (PI / FNI / handlers)                               | [`execution.md`](./architecture/execution.md)               | §3.1, §3.2, §5, §7                                     |
| Event bus + EventSinks                                      | [`event-system.md`](./architecture/event-system.md)         | §3.3                                                   |
| Timer scheduler                                             | [`timers.md`](./architecture/timers.md)                     | §3.4                                                   |
| Message / Signal / Escalation routing                       | [`routing.md`](./architecture/routing.md)                   | §3.5                                                   |
| Pending events (TTL hold)                                   | [`routing.md`](./architecture/routing.md) §3.5.4–§3.5.7     | §3.5                                                   |
| FEEL                                                        | [`expressions.md`](./architecture/expressions.md)           | —                                                      |
| Plugins & SDKs                                              | [`plugins.md`](./architecture/plugins.md)                   | §9                                                     |
| REST + GraphQL + WS                                         | [`api.md`](./architecture/api.md)                           | —                                                      |
| /stats + /health + /info                                    | [`observability.md`](./architecture/observability.md)       | —                                                      |
| Persistence schema                                          | [`data-model.md`](./architecture/data-model.md)             | —                                                      |
| Persistence (dual pool)                                     | [`persistence.md`](./architecture/persistence.md)           | —                                                      |
| DMN decision engine                                         | [`dmn.md`](./architecture/dmn.md)                           | —                                                      |
| TypeScript SDK & client                                     | [`sdk-client.md`](./architecture/sdk-client.md)             | —                                                      |
| Common pitfalls                                             | [`common-pitfalls.md`](./architecture/common-pitfalls.md)   | —                                                      |
| Retention & housekeeping                                    | [`configuration.md`](./architecture/configuration.md) §14.6 | §14.6                                                  |
| Configuration (env vars)                                    | [`configuration.md`](./architecture/configuration.md) §14.3 | —                                                      |
| Linter-score deploy gate                                    | [`configuration.md`](./architecture/configuration.md) §14.5 | §14.5                                                  |
| Shipping & deployment                                       | [`shipping.md`](./architecture/shipping.md)                 | §14                                                    |
| Testing strategy                                            | [`testing.md`](./architecture/testing.md)                   | —                                                      |
| Security                                                    | [`security.md`](./architecture/security.md)                 | §13                                                    |
| JWT auth + authorization                                    | [`authorization.md`](./architecture/authorization.md)       | §13                                                    |
| Architecture detail index                                   | [`architecture/index.md`](./architecture/index.md)          | —                                                      |
| Phases (roll-out order)                                     | —                                                           | [`ImplementationPhases.md`](./ImplementationPhases.md) |
| Glossary of terms                                           | —                                                           | [`Glossary.md`](./Glossary.md)                         |
| Database schema diagram                                     | —                                                           | [`Schema.md`](./Schema.md)                             |

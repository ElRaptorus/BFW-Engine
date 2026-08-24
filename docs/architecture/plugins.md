---
title: "Evil Engine — Plugin System & SDKs"
parent_document: "../ImplementationPlan.md"
---

<!-- Extracted from ImplementationPlan.md §9 ("Plugin system & SDKs"). When §9 changes in the parent plan, update this file to match. -->

## 9. Plugin system & SDKs

### 9.1 Plugin categories (from concept §Extendability)

| Category | Behaviour | Conflict rule |
|---|---|---|
| Service Task handler | `@behaviour EvilEngine.Plugin.ServiceTaskHandler` | Unique by `implementation`; duplicate → error at registration, NOT crash. Async-only: `handle_enter/3` returns `{:async, ref}` or `{:error, reason}` |
| REST API extension | `@behaviour EvilEngine.Plugin.RestApiExtension` | Mounted under configured route prefix. JWT resolved; no engine claim policy. Reserved prefixes rejected (including `/escalations`). |
| Event sink | `@behaviour EvilEngine.Plugin.EventSink` | Many allowed; each registration is an independent fan-out target on `EngineEventBus` ([event-system.md](./event-system.md) §3.3.2). Replaces the pre-EventSink "Lifecycle subscriber" category |
| Named script (for `<evil:scriptRef>`) | `@behaviour EvilEngine.Plugin.NamedScript` | Unique by script-key. Callback: `handle_enter(flow_node, payload, context) :: {:ok, map()} \| {:error, term()}` |
| Auth provider | `@behaviour EvilEngine.Plugin.AuthProvider` | Unique (singleton, first-writer wins). Callback: `verify_and_resolve(token) :: {:ok, Identity.t()} \| {:error, reason}` |

PersistenceAdapter, MonitoringPanel, TimerSource, and DataStoreAdapter plugin capabilities **do not exist** — do not register them. Execution persistence is `EvilEngine.Execution.Persistence` (config `:core_execution, :persistence_adapter`), not a plugin behaviour. BPMN DataStores remain a parser no-op.

**`EventSink` behaviour shape**:

```elixir
defmodule EvilEngine.Plugin.EventSink do
  @moduledoc """
  Receives every `EvilEngine.Types.Event.*` the engine emits (`../ImplementationPlan.md` §2.1.1, `./event-system.md` §3.3.2).
  Runs in its own supervised Task; crashes are isolated by EngineEventBus.
  Sinks MUST NOT call back into core_execution or block the hot path.
  """

  @callback init(opts :: keyword()) :: {:ok, state :: term()} | {:error, term()}

  @doc """
  Called once per published event. MUST be O(1) in observable cost — buffer
  internally if the downstream target is slow. Raising from here is caught
  by EngineEventBus, which emits `%Event.SinkFailed{}` and continues other sinks.
  """
  @callback accepts?(event :: struct()) :: boolean()

  @callback handle_event(event :: struct(), state :: term()) :: {:ok, state :: term()} | :skip

  @doc """
  Called when the engine is shutting down (clean stop only). Sinks that buffer
  internally (Kafka, Datadog, ...) flush here. Not called on SIGKILL.
  """
  @callback handle_shutdown(state :: term()) :: :ok
end
```

The three built-in sinks (`console`, `telemetry`, `websocket` — see [event-system.md](./event-system.md) §3.3.3) all implement this behaviour; they are not special-cased by `EngineEventBus`. The built-in `database` sink was removed. Plugin sinks register from inside their `on_load/1` callback (§9.2.1) using the injected `engine_facade`:

```elixir
def on_load(facade) do
  facade.register_event_sink.("datadog", MyOrg.DatadogSink, api_key_ref: "vault:...")
  :ok
end
```

…and are dispatched identically to the built-in sinks. Plugins MUST NOT call `EvilEngine.Plugin.Registry` directly — the registry is private to `peripheral_plugins`; only the engine-injected facade may write to it.

### 9.2 Loading model ()

The **engine, not the plugin, owns lifecycle.** Plugins never self-register
from their own `Application.start/2` and never decide *when* they take
effect. v1 implements the in-BEAM tier only (PLUG-D1). The sidecar tier
in §9.2.3 is a deferred design. Both tiers, when present, feed the same
`EvilEngine.Plugin.Registry`, so every consumer downstream (Service Task
dispatch, EngineEventBus fan-out, REST API extension routing) is
oblivious to which tier a registration came from.

#### 9.2.1 Lifecycle phases (uniform across both tiers)

The plugin contract has exactly two engine-driven callbacks. Plugins
implement them via `@behaviour EvilEngine.Plugin` (in-BEAM) or the
equivalent gRPC RPCs (sidecar):

| Phase | When the engine fires it | What the plugin may do |
|---|---|---|
| `on_load(engine_facade)` | After `core_execution` reports steady state, **before** the API tier exposes its sockets. Plugins are invoked sequentially in registration order; a failed `on_load` quarantines that plugin without aborting boot of the others (§9.3) | Register handlers via typed facade closures (`facade.register_service_task_handler.(…)`, `facade.register_event_sink.(…)`, etc.); read engine info; subscribe to engine events |
| `on_ready(engine_facade)` | After every loaded plugin's `on_load` has returned, **and** after the API tier has bound its listening sockets | Perform any work that requires the engine to be reachable end-to-end (warm an external cache, dial a partner system, register webhooks). May return `:ok` or `{:error, reason}` — **`{:error, _}` quarantines the plugin** the same way a failed `on_load` does (see §9.3) |

`on_load` is **synchronous from the engine's perspective**: the engine
waits for it to return before invoking the next plugin's `on_load`. This
removes the loading-order race that a "plugin self-registers from its own
`Application.start/2`" model has, where a plugin can race against core
boot or against other plugins' registrations. There is no `on_unload` in
v1 — graceful shutdown sends a typed `EngineShutdown` event over the same
channel and plugins react to it.

#### 9.2.2 In-BEAM OTP-app plugins

Highest performance, idiomatic Elixir.

- A plugin is an OTP application bundled into the engine's release.
  Operators build a custom release (`mix release`) bundling the engine
  umbrella plus their plugin OTP apps as transitive deps of an
  `evil_engine` release.
- The plugin's own `Application.start/2` is a no-op stub (or absent). It
  exists only so the BEAM loads the plugin's modules; it MUST NOT call
  `EvilEngine.Plugin.Registry.register/2` itself.
- **Discovery**: at engine boot, `peripheral_plugins` reads
  `EVIL_PLUGINS_INBEAM` (whitespace- or comma-separated list of OTP-app
  names — [configuration.md](./configuration.md) §14.3). For each entry, it locates the declared `@behaviour
  EvilEngine.Plugin` module via `Application.get_env(app_name, :plugin_module)`.
  OTP application specs do **not** support arbitrary keys like `:plugin_module`; the
  plugin OTP app must set that key in **application env** (for example
  `Application.put_env/3` from `Application.start/2`, or `config :my_plugin,
  :plugin_module, MyPlugin` in the host release). See in
  [`../ImplementationPlan.md` §0](../ImplementationPlan.md).
- **Include / exclude lists**: cross-checked against `EVIL_PLUGINS_INCLUDE` /
  `EVIL_PLUGINS_EXCLUDE` ([configuration.md](./configuration.md) §14.3). Exclude wins on conflict; a name appearing
  in both lists is rejected with a startup log line (`:ambiguous_policy`).
- The engine then calls `on_load(engine_facade)` on each surviving
  plugin in the order they appear in `EVIL_PLUGINS_INBEAM`. Sequential,
  not parallel.
- **Concurrency**: each plugin's worker processes (anything spun up
  inside `on_load`) live under a per-plugin OTP supervisor inside
  `peripheral_plugins`'s supervision tree, never in Core.

> **Why no filesystem hot-load for in-BEAM plugins?**
> Loading uncompiled `.beam` files from `~/.evil/engine/plugins` is
> technically possible (`:code.load_abs/1`, `.ez` archives) but a known
> minefield: diamond dep conflicts (engine bundles `jason 1.4`, plugin
> compiled against `jason 1.3` — both modules in one VM), OTP/compiler
> version skew, no clean `Application` lifecycle for raw modules, no
> release stripping. The Elixir ecosystem's idiomatic answer is "compile
> the plugin into the release," which the engine adopts. This trade-off
> matches Camunda Zeebe (also JVM-side) and every other in-process
> Elixir plugin system in production. The filesystem-drop-in sidecar tier
> is specified in §9.2.3 but is **not implemented in v1** (PLUG-D1). v1
> operators who need other-language work use the built-in HTTP Service
> Task, the public API, or an in-BEAM plugin that execs a local interpreter.

#### 9.2.3 Sidecar plugins

> **Deferred — not in v1 (PLUG-D1).** There is no `SidecarLoader`, no plugin
> gRPC protocol, and no process host. `EVIL_PLUGINS_SIDECAR_*` env vars are
> reserved no-ops. The remainder of this section is the retained design for
> a possible post-v1 revisit, not a v1 contract. Non-Elixir code in v1 uses
> the built-in HTTP Service Task, REST/GraphQL/WebSocket, or an in-BEAM
> plugin that execs a local interpreter (Phase 7 cookbook).

Language-agnostic. The engine drives discovery and lifecycle from a
filesystem directory.

- **Default discovery directory**: `~/.evil/engine/plugins`,
  configurable via `EVIL_PLUGINS_SIDECAR_DIR` ([configuration.md](./configuration.md) §14.3). Setting the dir to
  an empty string disables sidecar loading entirely.
- Each immediate subdirectory is a candidate plugin and contains a
  `plugin.toml` manifest:
  ```toml
  name      = "my_datadog_sink"
  version   = "1.2.0"
  exec      = "./my-datadog-sink"           # path is resolved relative to the manifest
  categories = ["event_sink"]               # informational; concrete handlers are
                                            # registered in the gRPC handshake reply
  env       = { DD_API_KEY_REF = "vault:secret/datadog#api_key" }
  ```
- **Scan order**: deterministic, alphabetical by directory name.
- **Include / exclude lists**: same `EVIL_PLUGINS_INCLUDE` / `EVIL_PLUGINS_EXCLUDE`
  rules as the in-BEAM tier. The names matched are the manifest's
  `name`, not the directory name.
- For each surviving plugin the engine spawns the manifest-declared
  binary as a supervised child (`Port`, restart-with-rate-limited-backoff),
  opens a bidirectional gRPC stream over a Unix-domain socket scoped to
  that plugin instance, and waits for the plugin's `Hello` reply naming
  the concrete handlers it registers. This `Hello` handshake is the
  gRPC-side equivalent of the in-BEAM `on_load`; the engine then sends a
  typed `OnLoadComplete` ack and proceeds to the next plugin.
- After every plugin (in-BEAM and sidecar) has completed `on_load` and
  the API tier has bound its sockets, the engine sends a typed
  `EngineReady` message on every active gRPC stream — that is the
  sidecar-side `on_ready`.
- A sidecar process exit triggers reconnect-with-backoff; after
  `EVIL_PLUGINS_SIDECAR_RECONNECT_LIMIT` consecutive failures ([configuration.md](./configuration.md) §14.3,
  default `5`) the plugin is **quarantined** and an
  `Event.PluginQuarantined` is published on `EngineEventBus` ([event-system.md](./event-system.md) §3.3.2).
  Quarantined plugins are not auto-revived in v1; operator restarts the
  engine.

> **Integration test fixtures**
>
> Multi-language sidecar fixture plugins were planned at `test/fixtures/plugins/`
> (project root). That CI obligation is **not in v1** (PLUG-D1). If the sidecar
> host is revisited post-v1, fixtures would live there: `plugin.toml` + runnable
> binary/script per subdirectory, covering Elixir (escript), Python, Ruby, C#
> (dotnet), and Node.js, with `EVIL_PLUGINS_SIDECAR_DIR` pointed at the fixture
> directory and reset after the run. See [`testing.md`](./testing.md) §12.4.8.

#### 9.2.4 `HandlerContext` (Core → `FlowNodeHandler`)

Service Tasks and other Core `EvilEngine.Execution.FlowNodeHandler` callbacks
receive a **third argument** of type `%EvilEngine.Execution.HandlerContext{}`, not a
raw `pid()`. It carries the standard runtime bindings handlers need to evaluate
FEEL (aligned with §8.1 / [`expressions.md`](./expressions.md)):

| Field | Contents |
|---|---|
| `flow_node_instance_id` | The generated Flow Node Instance UUID — async handlers use this to call `facade.finish_async_service_task.(flow_node_instance_id, result)` |
| `process_instance_id` | The owning Process Instance UUID |
| `identity` | Map derived from the caller's `%EvilEngine.Types.Identity{}` (or empty for synthetic callers) |
| `process` | `%{id, name, version}` from the deployed process model |
| `process_instance` | `%{id, started_at, started_by}` for the active PI |
| `data_objects` | Current in-memory Data Object cache map for the PI |

`@callback handle_enter/3` on `EvilEngine.Execution.FlowNodeHandler` is therefore
`(flow_node, token, %HandlerContext{}) → {:ok, …} | {:wait, …} | {:error, …}` for **most** built-in BPMN handlers. **`FlowNodes.ServiceTask`** exclusively propagates **`{:async, ref}`** from plugin `@behaviour EvilEngine.Plugin.ServiceTaskHandler` implementations (async-only contract) — `ref` is typically the `flow_node_instance_id` from the context; the PI GenServer matches `{:async, _ref}` and parks the FNI. Plugin `ServiceTaskHandler` follows the same arity; the
third argument is this struct (the SDK type spec may still name it `facade` in
legacy call-sites — it is **not** the `engine_facade` injected into `on_load`).

#### 9.2.5 The `engine_facade` (the "engine object" injected into plugins)

`engine_facade` is the single argument that `on_load` and `on_ready`
receive. It exposes identity, capability registration, infrastructure
(events, config), and resource-scoped runtime namespaces.

**Root-level fields** (registration + infrastructure):

| Capability | In-BEAM call | Sidecar gRPC RPC |
|---|---|---|
| Register handlers | Typed registration closures: `register_service_task_handler.(impl, handler)`, `register_named_script.(key, handler)`, `register_rest_api_extension.(prefix, handler)`, `register_auth_provider.(handler)` — each writes a registry entry. PersistenceAdapter, MonitoringPanel, TimerSource, and DataStoreAdapter **do not exist**. | Implicit in the `Hello` reply manifest |
| Subscribe to typed engine events | `facade.register_event_sink.(name, module, opts)` writing into `EvilEngine.Plugin.Registry`; dispatch is then identical to the three built-in sinks ([event-system.md](./event-system.md) §3.3.3) | Server-streaming RPC — engine pushes `Event.*` messages |
| Publish events | `facade.publish_event.(event)` | RPC equivalent |
| Read config | `facade.get_config.(key)` | RPC equivalent |

**Resource-scoped runtime namespaces** (all wired to `EvilEngine.Api.*` via closures):

| Namespace | Operations | Notes |
|---|---|---|
| `facade.processes` | `list`, `get`, `get_latest_version`, `deploy`, `enable`, `disable`, `delete_version`, `undeploy`, `start` | Catalog reads + writes for Process Models / Versions |
| `facade.process_instances` | `get`, `abort`, `retry`, `delete` | Runtime commands on Process Instances |
| `facade.user_tasks` | `finish`, `cancel` | User Task control — Elixir arity is `(flow_node_instance_id, result\|reason, identity)` |
| `facade.service_tasks` | `finish_async`, `fail_async` | Async Service Task completion |
| `facade.flow_node_instances` | `get`, `list_for_process_instance` | FNI reads + per-PI listing |
| `facade.data_objects` | `get`, `list_for_instance`, `history_for_instance` | Data Object reads + audit trail |
| `facade.decisions` | `list`, `get`, `get_latest_version`, `validate`, `deploy`, `evaluate`, `evaluate_by_version`, `evaluate_service`, `get_versions`, `get_xml`, `enable`, `disable`, `delete_version`, `undeploy` | DMN catalog + evaluation |
| `facade.messages` | `publish` | Message publish (`publish/3`) |
| `facade.signals` | `publish` | Signal broadcast (`publish/1`; no payload, no correlation) |
| `facade.escalations` | `publish` | Escalation inject (`publish/1`; waiter delivery, no payload) |
| `facade.adhoc_subprocesses` | `get_enabled_activities`, `activate_activity`, `complete`, `get_status` | Ad-hoc subprocess control |
| `facade.timers` | `trigger_event`, `list_schedules`, `get_schedule`, `enable_schedule`, `disable_schedule` | Timer event trigger + cycle schedule list/enable/disable |
| `facade.graphql` | `query` | Raw GraphQL execution via `Absinthe.run/3` with plugin identity. Query-only; no mutations. |

Each closure is wired by the `Loader` to the corresponding `EvilEngine.Api` function. The plugin's synthetic identity (`%Identity{id: "plugin:<name>", roles: []}`) is pre-injected for operations that require it (deploy, abort, retry, delete). No HTTP round-trip, no JSON re-encode, no JWT replay for in-BEAM plugins.

Audit hooks live inside the Ash action itself, so a plugin's command
is subject to **identical audit recording** as a wire request — every
`EvilEngine.Api.*` invocation records the invoking Identity, whether
that identity comes from a JWT-authenticated wire caller or from the
auto-injected **privileged plugin identity** (`%Identity{id: "plugin:<name>",
roles: [], ...}` — see [`Authorization.md`](./authorization.md) §7).
**Authorization enforcement differs**: plugins bypass claim checks entirely
(they are inside the operator's trust boundary ); wire callers are
subject to the full claim dictionary. **Plugins MUST NOT reach into
`core_execution`, `core_events`, or `peripheral_persistence` modules directly
for command operations** — those modules are private to the service layer;
only event-scoped callbacks (§9.1 behaviours) live inside Core/Peripheral
boundaries. Sidecar plugins physically cannot — they speak gRPC. In-BEAM
plugins can, but the contract forbids it and CI lints against it
(`peripheral_plugins` declares no compile-time dep on `core_execution`).

### 9.2.6 Registration Validation (in-BEAM)

When a plugin registers a capability via any of the typed registration closures (e.g. `facade.register_service_task_handler.(impl, handler)`), the Loader builds a descriptor map and delegates to `EvilEngine.Plugins.Registry.register_capability/3`, which performs two checks in order:

1. **Conflict check** — is the capability's unique key already claimed? (Same as before.)
2. **Behaviour validation** — if the descriptor contains an atom `:module` key, the Registry verifies:
   - The module can be loaded (`Code.ensure_loaded/1`).
   - The module declares `@behaviour <expected>` where `<expected>` is looked up from an internal `@capability_behaviours` map (e.g. `:service_task_handler` → `EvilEngine.Plugin.ServiceTaskHandler`).

If behaviour validation fails, the registration is rejected with `{:error, :invalid_handler, message}` or `{:error, :module_not_loaded, message}`, and a `PluginQuarantined` event is emitted. The capability is **not** added to the registry, so the engine will never dispatch to a handler that doesn't implement the required callbacks.

**Validation is skipped** when:
- The descriptor has no `:module` key (metadata-only or sidecar registration).
- The `:module` value is a string (sidecar gRPC service reference).
- The capability type has no entry in the `@capability_behaviours` map (future/unknown types).

The Loader's facade closure also logs a warning when any registration error is returned, providing operator visibility without auto-quarantining the entire plugin.

### 9.3 Plugin failure isolation

- A plugin crash never crashes the engine. The per-plugin OTP supervisor restarts it (permanent / transient / temporary depending on type).
- Duplicate Service Task registration: **error + log**, not crash, per concept.
- Sidecar timeouts have configurable limits; on timeout the associated operation returns `:plugin_timeout` and the FNI transitions to `fatal`.
- **`on_load` failure (raise / `{:error, _}` return / sidecar `Hello` timeout):** the offending plugin is **quarantined** — it is *not* registered, no further callbacks fire on it, and an `Event.PluginQuarantined{plugin_name, tier, reason, occurred_at}` is published on `EngineEventBus`. Engine boot continues with the remaining plugins. Operators inspect the `plugins` block of `/stats` ([`../ImplementationPlan.md` §11.2](../ImplementationPlan.md)) to see degraded plugins. Quarantined plugins do not auto-revive in v1; operator restarts the engine.
- **Sidecar discovery failures** (manifest invalid, `exec` binary missing, gRPC handshake timeout, manifest excluded by policy) are handled identically: the candidate is rejected with a structured log line (`reason: :manifest_invalid` / `:exec_missing` / `:hello_timeout` / `:denied_by_policy`), `Event.PluginQuarantined` is published, scan continues with the next directory.
- **In-BEAM discovery failures** (named OTP app in `EVIL_PLUGINS_INBEAM` not loaded, missing `:plugin_module` in **application env**, name in `EVIL_PLUGINS_EXCLUDE`) are handled identically. A name appearing in both `EVIL_PLUGINS_INCLUDE` and `EVIL_PLUGINS_EXCLUDE` is rejected with `reason: :ambiguous_policy`.

### 9.4 Default built-in plugins

- `evil:http` — Default HTTP Service Task handler (`EvilEngine.Plugins.Builtin.HttpServiceTaskHandler`). Per , ships in `peripheral_plugins` as the reference implementation (HTTP client stays out of Core); registered before user plugins so operators can override the `http` implementation key.
- Execution persistence is `EvilEngine.Execution.Persistence` (AshPostgres via `ExecutionAdapter` in production, `NoOp` in tests), configured with `:core_execution, :persistence_adapter`. There is no plugin PersistenceAdapter capability.
- No built-in NamedScript handler ships in v1. Inline FEEL evaluation is handled directly by the `ScriptTask` handler without going through the plugin dispatch chain. Plugins register NamedScript handlers via `evil:scriptRef` for custom script languages or complex logic.

**Authentication is pluggable.** The built-in JWT validator in `api_auth`
implements `@behaviour EvilEngine.Plugin.AuthProvider` as the default. Plugins
can register a replacement via `facade.register_auth_provider.(module)` during
`on_load/1`. Only one provider is active at a time (first-writer wins). See
`examples/plugins/auth_providers/ldap/` and `examples/plugins/auth_providers/companygraph/` for
ready-to-copy starting points.

### 9.5 SDK packages

| Audience | Package | Contents |
|---|---|---|
| Elixir plugin authors | `evil_engine_sdk` (Hex, app `apps/engine_sdk`) | All `@behaviour` modules (including `EventSink` — with a `TestSink` Mox fixture that asserts receipt of specific event structs), test helpers, a `mix evil.gen.plugin` scaffolder, reference plugin examples (including a worked `DatadogSink` stub + a worked `KafkaSink` stub). **Per the SDK contract**: `EvilEngine.SDK.BPMN` explicitly re-exports `EvilEngine.BPMN.Model.*` (the AST), `EvilEngine.BPMN.ModelCache.{fetch/1, get/1, fetch_subprocess_model/2, find_message_start_events/1, find_signal_start_events/1}`, and `EvilEngine.BPMN.Parser.parse/1`, so plugins (in-engine and out-of-tree Elixir tooling) parse BPMN XML and consume the AST with the engine's canonical semantics. The SDK also re-exports the full `EvilEngine.Types.Event.*` struct catalog + `EngineEventBus.publish/1` (for test-only synthetic emission) so plugin EventSink authors can pattern-match on stable event types without reaching into the engine's internal modules |
| Non-Elixir plugin authors (Go, Rust, Python, Node, Java, C#) | `evil-engine-plugin-{lang}` — each generated from `evil.engine.plugin.v1.proto` via `buf generate`, published per ecosystem | gRPC client + boilerplate for registering, heartbeating, streaming events |
| Engine API consumers (Studio, dashboards, CLIs) | `@elraptorus/daemonengine_sdk` (contract layer: types, error classes, event types, the authoring-path BPMN XML parser, and the extension vocabulary manifest) + `@elraptorus/daemonengine_client` (transport: REST, GraphQL, WebSocket, depends on the SDK) — both npm packages in `packages/js/` | Typed client for REST triggers + GraphQL queries (including the Model graph, §10.2.2). The SDK ships `extension-manifest.json` (typed export `extensionManifest`, `packages/js/sdk/src/generated/extension-manifest.ts`) — the vocabulary of every `evil:*` element the parser reads, **not** a `bpmn-moddle` descriptor (see below) |

**Studio's engine extensions** depend on `@elraptorus/daemonengine_client` (which depends on `@elraptorus/daemonengine_sdk`). No direct SQL/PubSub/gRPC coupling.

**Extension manifest, not a generated moddle descriptor (decision D-5 = B+).** An earlier plan called for the Engine to auto-generate a `bpmn-moddle` descriptor (`moddle/evil.json`) from the `%EvilEngine.BPMN.Model.*{}` struct definitions. That is **superseded**: roughly half of a moddle descriptor's semantic content — `meta.allowedIn` constraints, the moddle type hierarchy, `xml.tagAlias` — has no counterpart in `sax_handler.ex`, which strips namespace prefixes and matches extension elements by name contextually with no `allowed_in` concept whatsoever. Generating that data would mean inventing it on the Engine side, moving an authoring-time modelling concern into the wrong repository. Instead, `mix evil.gen.extension_manifest` (`apps/core_bpmn/lib/mix/tasks/evil.gen.extension_manifest.ex`) emits the smaller artifact the Engine actually owns — the extension **vocabulary** (`element`, `valueKind`, `carrier`, `attributes`, `applicableTo`, `modelField` per entry, from `EvilEngine.BPMN.ExtensionManifest`) — and the Studio keeps its hand-written `evil-platform.json` moddle descriptor, running a bidirectional conformance test against the manifest instead of consuming a generated one. See `.cursor/plans/process_model_graphql_exposure_205a61a4.plan.md` §5 D-5 for the full rationale.

### 9.6 Example catalogue

The `examples/` directory contains copy-paste starters and runnable demos covering all live plugin capabilities plus the TypeScript SDK and Client. See [`examples/README.md`](../../examples/README.md) for the full navigation table.

| Category | Examples | Location |
|----------|----------|----------|
| Auth Providers | LDAP, CompanyGraph | `examples/plugins/auth_providers/` |
| Service Task Handlers | echo, HTTP enrichment, Redis cache, webhook callback, RabbitMQ roundtrip (all async ) | `examples/plugins/service_task_handlers/` |
| Event Sinks | DataDog metrics, webhook forwarder, structured logger | `examples/plugins/event_sinks/` |
| Named Scripts | custom validators, local script runner | `examples/plugins/named_scripts/` |
| Lifecycle & API | lifecycle-aware, API consumer | `examples/plugins/lifecycle_and_api/` |
| Combined | RabbitMQ-to-engine orchestrator, metrics pipeline | `examples/plugins/combined/` |
| Business Rules | KPI calculator, explain decision, trace publisher, smoke tester, regression tester, dead rule detector, DRD orchestrator, boxed expression showcase | `examples/plugins/business_rules/` |
| JS Sidecar Plugins | decision analytics, decision audit reporter | `examples/sidecar-js/` |
| TypeScript Client | deploy, lifecycle, user tasks, GraphQL, errors, WebSocket, batch ops | `examples/client-js/` |
| TypeScript SDK | BPMN parser, typed payloads, error hierarchy | `examples/sdk-js/` |

**Business Rules examples** demonstrate the observation-only interaction pattern introduced with plugins observe BRT execution via event sinks and analyze results via `facade.decisions` closures, but never replace the BRT execution path. BRT execution is exclusively handled by the engine's built-in `"feel"` and `"dmn"` modes.

**JS Sidecar examples** are sketches against a mocked `@elraptorus/daemonengine_sdk` interface. They are **not supported in v1** (PLUG-D1). Live gRPC sidecar integration is deferred post-v1.

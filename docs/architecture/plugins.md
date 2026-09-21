# Plugin System & SDKs

The engine is extensible through behaviour-based **in-BEAM** plugins:
OTP applications bundled into the release. The engine owns lifecycle
(`on_load` / `on_ready`). Plugins call `BfwEngine.Api` through the
injected `engine_facade` — no HTTP round-trip.

Non-Elixir work uses the built-in HTTP Service Task, the public REST /
GraphQL / WebSocket API, or an in-BEAM plugin that execs a local
interpreter (see `examples/plugins/service_task_handlers/python_script/`
and `node_script/`).

Everyday authoring: [Plugin Development — Getting Started](../guides/plugins/getting-started.md)
and [Engine Facade](../guides/plugins/engine-facade.md).

## Plugin categories

| Category | Behaviour | Conflict rule |
|---|---|---|
| Service Task handler | `@behaviour BfwEngine.Plugin.ServiceTaskHandler` | Unique by `implementation`; duplicate → error at registration, NOT crash. Async-only: `handle_enter/3` returns `{:async, ref}` or `{:error, reason}` |
| REST API extension | `@behaviour BfwEngine.Plugin.RestApiExtension` | Mounted under configured route prefix. JWT resolved; no engine claim policy. Reserved prefixes rejected (including `/escalations`). |
| Event sink | `@behaviour BfwEngine.Plugin.EventSink` | Many allowed; each registration is an independent fan-out target on `EngineEventBus` ([event-system.md](./event-system.md)) |
| Named script (for `<bfw:scriptRef>`) | `@behaviour BfwEngine.Plugin.NamedScript` | Unique by script-key. Callback: `handle_enter(flow_node, payload, context) :: {:ok, map()} \| {:error, term()}` |
| Auth provider | `@behaviour BfwEngine.Plugin.AuthProvider` | Unique (singleton, first-writer wins). Callback: `verify_and_resolve(token) :: {:ok, Identity.t()} \| {:error, reason}` |

PersistenceAdapter, MonitoringPanel, TimerSource, and DataStoreAdapter plugin capabilities **do not exist** — do not register them. Execution persistence is `BfwEngine.Execution.Persistence` (config `:core_execution, :persistence_adapter`), not a plugin behaviour. BPMN DataStores remain a parser no-op.

**`EventSink` behaviour shape**:

```elixir
defmodule BfwEngine.Plugin.EventSink do
  @moduledoc """
  Receives every `BfwEngine.Types.Event.*` the engine emits ([event-system.md](./event-system.md)).
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

The three built-in sinks (`console`, `telemetry`, `websocket` — see [event-system.md](./event-system.md)) all implement this behaviour; they are not special-cased by `EngineEventBus`. The engine does not persist typed events to Postgres. Plugin sinks register from inside their `on_load/1` callback using the injected `engine_facade`:

```elixir
def on_load(facade) do
  facade.register_event_sink.("datadog", MyOrg.DatadogSink, api_key_ref: "vault:...")
  :ok
end
```

…and are dispatched identically to the built-in sinks. Plugins MUST NOT call `BfwEngine.Plugin.Registry` directly — the registry is private to `peripheral_plugins`; only the engine-injected facade may write to it.

## Loading model

The **engine, not the plugin, owns lifecycle.** Plugins never self-register
from their own `Application.start/2` and never decide *when* they take
effect. The shipped loading model is **in-BEAM OTP applications**. Downstream
consumers (Service Task dispatch, EngineEventBus fan-out, REST API extension
routing) read the same `BfwEngine.Plugin.Registry`.

### Lifecycle phases

The plugin contract has exactly two engine-driven callbacks. Plugins
implement them via `@behaviour BfwEngine.Plugin`:

| Phase | When the engine fires it | What the plugin may do |
|---|---|---|
| `on_load(engine_facade)` | After `core_execution` reports steady state, **before** the API tier exposes its sockets. Plugins are invoked sequentially in registration order; a failed `on_load` quarantines that plugin without aborting boot of the others | Register handlers via typed facade closures (`facade.register_service_task_handler.(…)`, `facade.register_event_sink.(…)`, etc.); read engine info; subscribe to engine events |
| `on_ready(engine_facade)` | After every loaded plugin's `on_load` has returned, **and** after the API tier has bound its listening sockets | Perform any work that requires the engine to be reachable end-to-end (warm an external cache, dial a partner system, register webhooks). May return `:ok` or `{:error, reason}` — **`{:error, _}` quarantines the plugin** the same way a failed `on_load` does |

`on_load` is **synchronous from the engine's perspective**: the engine
waits for it to return before invoking the next plugin's `on_load`. This
removes the loading-order race that a "plugin self-registers from its own
`Application.start/2`" model has, where a plugin can race against core
boot or against other plugins' registrations. There is no `on_unload` in
v1 — graceful shutdown sends a typed `EngineShutdown` event over the same
channel and plugins react to it.

### In-BEAM OTP-app plugins

Highest performance, idiomatic Elixir.

- A plugin is an OTP application bundled into the engine's release.
  Operators build a custom release (`mix release`) bundling the engine
  umbrella plus their plugin OTP apps as transitive deps of an
  `bfw_engine` release.
- The plugin's own `Application.start/2` is a no-op stub (or absent). It
  exists only so the BEAM loads the plugin's modules; it MUST NOT call
  `BfwEngine.Plugin.Registry.register/2` itself.
- **Discovery**: at engine boot, `peripheral_plugins` reads
  `BFE_PLUGINS_INBEAM` (whitespace- or comma-separated list of OTP-app
  names — [configuration.md](./configuration.md)). For each entry, it locates the declared `@behaviour
  BfwEngine.Plugin` module via `Application.get_env(app_name, :plugin_module)`.
  OTP application specs do **not** support arbitrary keys like `:plugin_module`; the
  plugin OTP app must set that key in **application env** (for example
  `Application.put_env/3` from `Application.start/2`, or `config :my_plugin,
  :plugin_module, MyPlugin` in the host release).
- **Include / exclude lists**: cross-checked against `BFE_PLUGINS_INCLUDE` /
  `BFE_PLUGINS_EXCLUDE` ([configuration.md](./configuration.md)). Exclude wins on conflict; a name appearing
  in both lists is rejected with a startup log line (`:ambiguous_policy`).
- The engine then calls `on_load(engine_facade)` on each surviving
  plugin in the order they appear in `BFE_PLUGINS_INBEAM`. Sequential,
  not parallel.
- **Concurrency**: each plugin's worker processes (anything spun up
  inside `on_load`) live under a per-plugin OTP supervisor inside
  `peripheral_plugins`'s supervision tree, never in Core.

Plugins are compiled into the release. Dropping uncompiled `.beam` files
into a directory is not supported: diamond dependency conflicts, OTP
compiler skew, and no clean `Application` lifecycle. Non-Elixir work uses
the built-in HTTP Service Task, the public API, or an in-BEAM plugin that
execs a local interpreter.

### `HandlerContext` (Core → `FlowNodeHandler`)

Service Tasks and other Core `BfwEngine.Execution.FlowNodeHandler` callbacks
receive a **third argument** of type `%BfwEngine.Execution.HandlerContext{}`, not a
raw `pid()`. It carries the standard runtime bindings handlers need to evaluate
FEEL ([expressions.md](./expressions.md)):

| Field | Contents |
|---|---|
| `flow_node_instance_id` | The generated Flow Node Instance UUID — async handlers use this to call `facade.finish_async_service_task.(flow_node_instance_id, result)` |
| `process_instance_id` | The owning Process Instance UUID |
| `identity` | Map derived from the caller's `%BfwEngine.Types.Identity{}` (or empty for synthetic callers) |
| `process` | `%{id, name, version}` from the deployed process model |
| `process_instance` | `%{id, started_at, started_by}` for the active PI |
| `data_objects` | Current in-memory Data Object cache map for the PI |

`@callback handle_enter/3` on `BfwEngine.Execution.FlowNodeHandler` is therefore
`(flow_node, token, %HandlerContext{}) → {:ok, …} | {:wait, …} | {:error, …}` for **most** built-in BPMN handlers. **`FlowNodes.ServiceTask`** exclusively propagates **`{:async, ref}`** from plugin `@behaviour BfwEngine.Plugin.ServiceTaskHandler` implementations (async-only contract) — `ref` is typically the `flow_node_instance_id` from the context; the PI GenServer matches `{:async, _ref}` and parks the FNI. Plugin `ServiceTaskHandler` follows the same arity; the
third argument is this struct (the SDK type spec may still name it `facade` in
legacy call-sites — it is **not** the `engine_facade` injected into `on_load`).

### The `engine_facade`

`engine_facade` is the single argument that `on_load` and `on_ready`
receive. It exposes identity, capability registration, infrastructure
(events, config), and resource-scoped runtime namespaces. Author-facing
tables with signatures: [Engine Facade](../guides/plugins/engine-facade.md).

**Root-level fields** (registration + infrastructure):

| Capability | Call |
|---|---|
| Register handlers | Typed registration closures: `register_service_task_handler.(impl, handler)`, `register_named_script.(key, handler)`, `register_rest_api_extension.(prefix, handler)`, `register_auth_provider.(handler)` — each writes a registry entry. PersistenceAdapter, MonitoringPanel, TimerSource, and DataStoreAdapter **do not exist**. |
| Subscribe to typed engine events | `facade.register_event_sink.(name, module, opts)` writing into `BfwEngine.Plugin.Registry`; dispatch is then identical to the three built-in sinks ([event-system.md](./event-system.md)) |
| Publish events | `facade.publish_event.(event)` |
| Read config | `facade.get_config.(key)` |

**Resource-scoped runtime namespaces** (all wired to `BfwEngine.Api.*` via closures):

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

Each closure is wired by the `Loader` to the corresponding `BfwEngine.Api` function. The plugin's synthetic identity (`%Identity{id: "plugin:<name>", roles: []}`) is pre-injected for operations that require it (deploy, abort, retry, delete). No HTTP round-trip, no JSON re-encode, no JWT replay for in-BEAM plugins.

Audit hooks live inside the Ash action itself, so a plugin's command
is subject to **identical audit recording** as a wire request — every
`BfwEngine.Api.*` invocation records the invoking Identity, whether
that identity comes from a JWT-authenticated wire caller or from the
auto-injected **privileged plugin identity** (`%Identity{id: "plugin:<name>",
roles: [], ...}` — see [authorization.md](./authorization.md)).
**Authorization enforcement differs**: plugins bypass claim checks entirely
(they are inside the operator's trust boundary); wire callers are
subject to the full claim dictionary. **Plugins MUST NOT reach into
`core_execution`, `core_events`, or `peripheral_persistence` modules directly
for command operations** — those modules are private to the service layer;
only event-scoped callbacks (plugin behaviours) live inside Core/Peripheral
boundaries. In-BEAM plugins can reach internals, but the contract forbids it
and CI lints against it (`peripheral_plugins` declares no compile-time dep
on `core_execution`).

### Registration validation

When a plugin registers a capability via any of the typed registration closures (e.g. `facade.register_service_task_handler.(impl, handler)`), the Loader builds a descriptor map and delegates to `BfwEngine.Plugins.Registry.register_capability/3`, which performs two checks in order:

1. **Conflict check** — is the capability's unique key already claimed?
2. **Behaviour validation** — if the descriptor contains an atom `:module` key, the Registry verifies:
   - The module can be loaded (`Code.ensure_loaded/1`).
   - The module declares `@behaviour <expected>` where `<expected>` is looked up from an internal `@capability_behaviours` map (e.g. `:service_task_handler` → `BfwEngine.Plugin.ServiceTaskHandler`).

If behaviour validation fails, the registration is rejected with `{:error, :invalid_handler, message}` or `{:error, :module_not_loaded, message}`, and a `PluginQuarantined` event is emitted. The capability is **not** added to the registry, so the engine will never dispatch to a handler that doesn't implement the required callbacks.

Validation is skipped when the descriptor has no atom `:module` key, or when the capability type has no entry in `@capability_behaviours`.

The Loader's facade closure also logs a warning when any registration error is returned, providing operator visibility without auto-quarantining the entire plugin.

## Plugin failure isolation (quarantine)

- A plugin crash never crashes the engine. The per-plugin OTP supervisor restarts it (permanent / transient / temporary depending on type).
- Duplicate Service Task registration: **error + log**, not crash.
- **`on_load` / `on_ready` failure** (raise or `{:error, _}`): the offending plugin is **quarantined** — it is *not* registered, no further callbacks fire on it, and an `Event.PluginQuarantined{plugin_name, reason, occurred_at}` is published on `EngineEventBus`. Engine boot continues with the remaining plugins. Operators inspect the `plugins` block of `/stats` to see degraded plugins. Quarantined plugins do not auto-revive; restart the engine after fixing the plugin.
- **`on_ready` failure** also calls `BfwEngine.Plugins.Registry.unregister_plugin_capabilities/1` (unlike `on_load` failure, which never registered).
- **Discovery failures** (named OTP app in `BFE_PLUGINS_INBEAM` not loaded, missing `:plugin_module` in application env, name in `BFE_PLUGINS_EXCLUDE`) quarantine that candidate and continue. A name appearing in both `BFE_PLUGINS_INCLUDE` and `BFE_PLUGINS_EXCLUDE` is rejected with `reason: :ambiguous_policy`.

See `examples/plugins/lifecycle_and_api/quarantine_demo/` for the author-facing demonstration.

## Default built-in plugins

- `http` — Default HTTP Service Task handler (`BfwEngine.Plugins.Builtin.HttpServiceTaskHandler`). Lives in `peripheral_plugins` (HTTP client stays out of Core); registered before user plugins so operators can override the `http` implementation key.
- Execution persistence is `BfwEngine.Execution.Persistence` (AshPostgres via `ExecutionAdapter` in production, `NoOp` in tests), configured with `:core_execution, :persistence_adapter`. There is no plugin PersistenceAdapter capability.
- No built-in NamedScript handler ships. Inline FEEL evaluation is handled directly by the `ScriptTask` handler without going through the plugin dispatch chain. Plugins register NamedScript handlers via `bfw:scriptRef` for custom script languages or complex logic.

**Authentication is pluggable.** The built-in JWT validator in `api_auth`
implements `@behaviour BfwEngine.Plugin.AuthProvider` as the default. Plugins
can register a replacement via `facade.register_auth_provider.(module)` during
`on_load/1`. Only one provider is active at a time (first-writer wins). See
`examples/plugins/auth_providers/ldap/` and `examples/plugins/auth_providers/companygraph/` for
ready-to-copy starting points.

## SDK packages

| Audience | Package | Contents |
|---|---|---|
| Elixir plugin authors | `bfw_engine_sdk` (Hex, app `apps/engine_sdk`) | All `@behaviour` modules (including `EventSink` — with a `TestSink` Mox fixture), test helpers, and copy-paste reference plugins under `examples/plugins/`. `BfwEngine.SDK.BPMN` re-exports `BfwEngine.BPMN.Model.*`, `ModelCache.{fetch/1, get/1, fetch_subprocess_model/2, find_message_start_events/1, find_signal_start_events/1}`, and `BfwEngine.BPMN.Parser.parse/1`. The SDK also re-exports `BfwEngine.Types.Event.*` + `EngineEventBus.publish/1` (test-only synthetic emission). `mix bfw.gen.plugin` is not shipped. |
| Non-Elixir work | Not a plugin SDK | Use the built-in HTTP Service Task, the public REST / GraphQL / WebSocket API, or an in-BEAM plugin that execs a local interpreter (`python_script` / `node_script` examples). |
| Engine API consumers (Studio, dashboards, CLIs) | `@elraptorus/bfw_engine_sdk` (contract: types, errors, events, BPMN XML parser, extension vocabulary manifest) + `@elraptorus/bfw_engine_client` (transport: REST, GraphQL, WebSocket) in `packages/js/` | Typed client for REST triggers + GraphQL queries including the Process Model graph. The SDK ships `extension-manifest.json` (typed export `extensionManifest`) — the vocabulary of every `bfw:*` element the parser reads, **not** a `bpmn-moddle` descriptor |

**Studio's engine extensions** depend on `@elraptorus/bfw_engine_client` (which depends on `@elraptorus/bfw_engine_sdk`). No direct SQL/PubSub/gRPC coupling.

The Engine emits an **extension vocabulary manifest** (`mix bfw.gen.extension_manifest`) with one entry per `bfw:*` element (`element`, `valueKind`, `carrier`, `attributes`, `applicableTo`, `modelField`). It does **not** generate a `bpmn-moddle` descriptor: the parser matches extension elements by name with no `allowed_in` type hierarchy. The Studio keeps its hand-written `bfw-platform.json` and checks it against this manifest.

## Example catalogue

The `examples/` directory contains copy-paste starters and runnable demos covering all live plugin capabilities plus the TypeScript SDK and Client. See [`examples/README.md`](../../examples/README.md) for the full navigation table.

| Category | Examples | Location |
|----------|----------|----------|
| Auth Providers | LDAP, CompanyGraph | `examples/plugins/auth_providers/` |
| Service Task Handlers | echo, HTTP enrichment, webhook callback, RabbitMQ roundtrip, python_script, node_script (all async) | `examples/plugins/service_task_handlers/` |
| Event Sinks | DataDog metrics, webhook forwarder, structured logger, SSE (`GET /events/stream`) | `examples/plugins/event_sinks/` |
| Named Scripts | custom validators, local script runner | `examples/plugins/named_scripts/` |
| REST API Extensions | echo (`/echo-ext`) | `examples/plugins/rest_api_extension/` |
| Ad-hoc | ai_toolbox | `examples/plugins/adhoc/` |
| Lifecycle & API | lifecycle-aware, API consumer, GitHub BPMN deployer, quarantine_demo | `examples/plugins/lifecycle_and_api/` |
| Combined | RabbitMQ-to-engine orchestrator, metrics pipeline, incident reporter | `examples/plugins/combined/` |
| Business Rules | explain decision, trace publisher, smoke tester, regression tester, DRD orchestrator, boxed expression showcase, decision analytics, decision audit reporter | `examples/plugins/business_rules/` |
| TypeScript Client | deploy, lifecycle, user tasks, GraphQL, errors, WebSocket, batch ops | `examples/client-js/` |
| TypeScript SDK | BPMN parser, typed payloads, error hierarchy | `examples/sdk-js/` |

**Business Rules examples** demonstrate the observation-only interaction pattern: plugins observe BRT execution via event sinks and analyze results via `facade.decisions` closures, but never replace the BRT execution path. BRT execution is exclusively handled by the engine's built-in `"feel"` and `"dmn"` modes.

**CI:** `mix test.examples` runs unit wrappers. `mix test.cookbook` (and the full `mix test.integration` glob) boots each remaining example against a live engine and link-checks READMEs. Those wrappers, and `CookbookPluginHarness`, batch-compile each example's `lib/**/*.ex` via `Examples.Shared.ExampleCompiler` (`Kernel.ParallelCompiler`) so sibling modules do not warn `is yet to be defined`. See [`examples/README.md`](../../examples/README.md).

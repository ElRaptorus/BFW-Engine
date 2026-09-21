# Event system

The engine routes runtime notifications through two complementary
mechanisms: in-process `Phoenix.PubSub` for coordination between process
instances and internal subsystems, and `EngineEventBus` as the single typed
fan-out surface for every `BfwEngine.Types.Event.*` payload. Telemetry in
`core_execution` mirrors that public contract: each `:telemetry.execute/3`
pairs with one `EngineEventBus.publish/1`. Observability, audit, live
clients, and plugin integrations consume events only via registered
`@behaviour BfwEngine.Plugin.EventSink` implementations — parallel,
crash-isolated, and at-most-once per sink.

## Event Bus Layers

The event bus has **two complementary layers**:

1. **In-process PubSub** — low-level transport for intra-engine coordination between PIs, handlers, and the Subscription registry. This is `Phoenix.PubSub` with the in-memory adapter, used by core_execution and the various `Core.Events.*` facades.
2. **`EngineEventBus`** — the single public fan-out surface for every typed `BfwEngine.Types.Event.*` payload emitted anywhere in the engine. Wraps the PubSub layer with a sink-routing stage that dispatches each event to every registered `@behaviour BfwEngine.Plugin.EventSink` ([plugins.md](./plugins.md)). This is the only channel through which observability, audit logging, and external integrations ever see engine events.

## In-process PubSub Topics

- `"process_instance:#{process_instance_id}"` — lifecycle events for one PI (all transitions + domain events).
- `"engine:messages"` — published messages (throw-events + external API triggers).
- `"engine:signals"` — published signals (broadcast).
- `"engine:timers"` — timer-fired notifications.

Escalation and compensation observability is `EngineEventBus` (`Event.EscalationRaised`, `Event.CompensationTriggered`, `Event.ActivityCompensated`). There are no `"engine:escalations"` / `"engine:compensations"` PubSub topics and no dedicated audit tables.

Future clustering: swap PubSub adapter to `Phoenix.PubSub.PG2` (multi-node) or `Redis`.

## EngineEventBus + EventSinks

`EngineEventBus` exposes a single public call:

```
BfwEngine.Events.EngineEventBus.publish(event :: BfwEngine.Types.Event.t()) :: :ok
```

Every `:telemetry.execute/3` call inside core_execution is paired with exactly one `EngineEventBus.publish/1` carrying a typed `BfwEngine.Types.Event.*` struct. The bus then dispatches the event to **every registered sink that declares interest** (`EventSink.accepts?/1` — see [plugins.md](./plugins.md)). Dispatch is:

- **Parallel per sink** — each registered sink runs in its own `BfwEngine.Events.SinkWorker` GenServer (supervised by `BfwEngine.Events.SinkSupervisor`, one_for_one). The bus's `handle_cast({:publish, event}, state)` simply casts the event to each worker's pid; the workers then process events independently. A slow sink fills only its own mailbox and never blocks another sink, the bus, or core_execution.
- **In-order per sink** — each worker is a GenServer, so events arriving via cast are processed serially in arrival order. The documented `handle_event(event, state) → {:ok, new_state}` in-order state-mutation contract is preserved exactly: a sink author writing a stateful sink (counter, batcher, etc.) can rely on events not racing each other for that sink.
- **Crash-isolated by supervision** — if a sink's `handle_event/2` raises, the worker catches the exception via `try/rescue`, emits an `Event.SinkFailed{sink_name, event_kind, reason, occurred_at}` back onto the bus (so other sinks can observe sink health), and continues running. If the worker process itself dies for any other reason, `SinkSupervisor` restarts it (one_for_one); the bus is unaffected.
- **At-most-once per sink** — no retries. Sinks that need delivery guarantees (e.g. a Kafka sink) implement their own buffering/retry inside `handle_event/2`. The engine makes no promises about delivery durability outside a sink's own store; that is the sink author's problem, deliberately.
- **Back-pressure-free on the hot path** — `publish/1` is always a non-blocking cast into a BEAM mailbox; core_execution never waits for sinks to finish. Pathologically slow sinks build up their own worker mailbox without touching the bus.

**Three built-in sinks ship inside the engine release** ([Built-in Sinks](#built-in-sinks)). Additional sinks are registered by plugins from inside their engine-driven `on_load/1` callback via `facade.register_event_sink.("name", MyModule, opts)` (see [plugins.md](./plugins.md)).

## Sink Auto-Registration (SinkRegistrar)

Built-in sinks are automatically registered at application boot by `BfwEngine.Events.SinkRegistrar`, a one-shot `Task` child of the `core_events` Application supervisor. It runs after `EngineEventBus` starts.

The registrar reads `*_sink_enabled` config flags from `:core_events` and a `sink_modules` map (also from `:core_events`) that maps sink names to their implementing modules. This indirection preserves the dependency rule — `core_events` (Core domain) never imports modules from `peripheral_persistence` or `api_web` at compile time.

The registrar checks `Code.ensure_loaded/1` before attempting registration, gracefully skipping sinks whose modules aren't available (e.g. when running tests for a single umbrella app where not all apps are compiled).

Config keys:

| Sink | Enable flag | Module config key |
|---|---|---|
| `console` | `:console_sink_enabled` | `sink_modules["console"]` |
| `telemetry` | `:telemetry_sink_enabled` | `sink_modules["telemetry"]` |
| `websocket` | `:websocket_sink_enabled` | `sink_modules["websocket"]` |

## Built-in Sinks

| Sink | Module | Default | Filtering | Purpose |
|---|---|---|---|---|
| `console` | `BfwEngine.Events.Sinks.Console` | **ON** | global `BFE_LOG_MIN_SEVERITY` (default `info`; values `error`/`warn`/`info`/`debug`/`verbose`) | Structured JSON via `logger_json` to stdout; consumed by whatever log aggregator the operator runs (Loki, Cloudwatch, `kubectl logs`, Docker logging drivers) |
| `telemetry` | `BfwEngine.Telemetry.Sink` (in `peripheral_telemetry`) | **ON** | none (always accepts, increments are O(1)) | Increments `[:bfw_engine, :event_bus]` for Prometheus `bfw_engine.event_bus.events.total`. Does **not** feed `/stats` ([observability.md](./observability.md)) |
| `websocket` | `BfwEngineWeb.Ws.Sinks.WebSocket` (in `api_web`) | **ON** | rejects only `SinkFailed` | Live Phoenix Channels push to subscribed clients, e.g. Studio debugger |

**Database sink removed.** The built-in `database` sink (`BfwEngine.Events.Sinks.Database`) was removed to eliminate a high-frequency write path that competed with execution writes for the shared connection pool. The three remaining built-in sinks (console, telemetry, websocket) are DB-free. Users who need DB-backed event storage can build a plugin sink with its own connection management.

**`data_object_writes` is not a sink concern.** (cross-ref) The `data_object_writes` table is transactionally coupled with the DO snapshot write inside the PI transaction — it is **kernel state** (debugger reconstruction, audit) and is always written regardless of sink configuration.

## EventSink Behaviour

### 9.1 Plugin categories (from concept §Extendability)

| Category | Behaviour | Conflict rule |
|---|---|---|
| Service Task handler | `@behaviour BfwEngine.Plugin.ServiceTaskHandler` | Unique by `implementation`; duplicate → error at registration, NOT crash |
| REST API extension | `@behaviour BfwEngine.Plugin.RestApiExtension` | Mounted under configured route prefix. JWT resolved; no engine claim policy. Reserved prefixes rejected (including `/escalations`). |
| Event sink | `@behaviour BfwEngine.Plugin.EventSink` | Many allowed; each registration is an independent fan-out target on `EngineEventBus` ([EngineEventBus + EventSinks](#engineeventbus--eventsinks)). Replaces the pre-EventSink "Lifecycle subscriber" category |
| Named script (for `<bfw:scriptRef>`) | `@behaviour BfwEngine.Plugin.NamedScript` | Unique by script-key |
| Auth provider | `@behaviour BfwEngine.Plugin.AuthProvider` | Unique (singleton, first-writer wins) |

PersistenceAdapter, MonitoringPanel, TimerSource, and DataStoreAdapter plugin capabilities **do not exist** — do not register them.

**`EventSink` behaviour shape**:

```elixir
defmodule BfwEngine.Plugin.EventSink do
  @moduledoc """
  Receives every `BfwEngine.Types.Event.*` the engine emits ([EngineEventBus + EventSinks](#engineeventbus--eventsinks-d37)).
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

The three built-in sinks (`console`, `telemetry`, `websocket` — see [Built-in Sinks](#built-in-sinks)) all implement this behaviour; they are not special-cased by `EngineEventBus`. Plugin sinks register from inside their `on_load/1` callback ([plugins.md](./plugins.md) — Loading model) using the injected `engine_facade`:

```elixir
def on_load(facade) do
  facade.register_event_sink.("datadog", MyOrg.DatadogSink, api_key_ref: "vault:...")
  :ok
end
```

…and are dispatched identically to the built-in sinks. Plugins MUST NOT call `BfwEngine.Plugin.Registry.register/2` directly — the registry is private to `peripheral_plugins`; only the engine-injected facade may write to it.

## Lifecycle Fan-out

### 3.6 Lifecycle → Persistence → API fan-out

Every state transition inside core_execution calls `:telemetry.execute/3` with the
relevant event name and a typed `BfwEngine.Types.Event.*` payload.
Event names include at least:

- `[:bfw_engine, :process_instance, :state_change]` — PI transitions (`running → finished`, etc.). Metadata includes `parent_process_instance_id` when the PI is a child of a Call Activity.
- `[:bfw_engine, :fni, :state_change]` — FNI transitions (`running → waiting`, etc.). Metadata includes `process_instance_id`.
- `[:bfw_engine, :call_activity, :child_started]` — Call Activity spawned a child PI. Metadata: `call_activity_flow_node_instance_id`, `parent_process_instance_id`, `child_process_instance_id`, `child_process_version_id`.
- `[:bfw_engine, :subprocess, :child_started]` — Embedded SubProcess spawned a child PI. Metadata: `subprocess_flow_node_instance_id`, `parent_process_instance_id`, `child_process_instance_id`, `subprocess_node_id`, `child_process_model_id`, `child_version`.
- `[:bfw_engine, :data_object, :written]` — Data Object write. Emitted **after** the write transaction commits so subscribers never observe uncommitted values.
- `[:bfw_engine, :message, :published]`, `[:bfw_engine, :message, :arrived]` — Message lifecycle (see [routing.md](./routing.md))
- `[:bfw_engine, :signal, :published]`, `[:bfw_engine, :escalation, :raised]`, `[:bfw_engine, :timer, :fired]` — other event lifecycles
Engine lifecycle events (`Event.EngineStarted`, `Event.EngineShutdown`) are published via `EngineEventBus.publish/1` only (no `:telemetry.execute/3` pairing). `EngineStarted` is emitted by `ResumeRunner` after all running PIs have been resumed at boot; `EngineShutdown` is emitted by <code>BfwEngine.Execution.Application.prep_stop/1</code> during graceful shutdown.

- `Event.EngineOverloaded` — Emitted when the engine's load level crosses *upward* into `:elevated` or `:critical`. Published via `EngineEventBus` only (no `:telemetry.execute/3` pairing). The poller in `BfwEngine.Telemetry.Measurements` detects threshold crossings and publishes only on transitions, not every tick. Fields: `level` (`:elevated` | `:critical`), `active_process_instances`, `limit`, `occurred_at`.
- `Event.EngineRecovered` — Symmetric counterpart to `EngineOverloaded`. Emitted when the load level drops back to `:normal` (e.g. elevated→normal, critical→normal). Consumers can use this to release back-pressure. Fields: `previous_level` (`:elevated` | `:critical`), `active_process_instances`, `limit`, `occurred_at`.
- `Event.ProcessInstanceRetried` — Emitted by `Execution.retry_process_instance/1` after successfully starting the retry gen_statem. `process_instance_id` is the root PI, `target_process_instance_id` is the PI the user targeted. Paired with `[:bfw_engine, :process_instance, :retried]` telemetry event. `version`, `previous_version`, and `new_version` are **process version UUIDs** (not `bfw:version` deployment strings); `previous_version`/`new_version` are `nil` when no version migration. `process_model_id` is the BPMN process ID string (resolved from ModelCache). Fields: `process_instance_id`, `target_process_instance_id`, `process_model_id`, `version`, `previous_state`, `previous_version`, `new_version`, `reset_to_flow_node_instance_id`, `retried_by`, `occurred_at`.

Each `:telemetry.execute/3` is paired with exactly one `EngineEventBus.publish/1` of the same typed payload ([EngineEventBus + EventSinks](#engineeventbus--eventsinks-d37)). Consumers of these events fall into two disjoint categories:

**A. Kernel-state persistence** (always-on, transactionally coupled with the PI, not routed through the event bus):

- **`process_instances` / `flow_node_instances` / `messages` / `signals` / `data_objects` / `data_object_writes`** — written by `peripheral_persistence` as part of the PI's own transaction (or the message/signal publish transaction). These writes happen **before or alongside** `EngineEventBus.publish/1`, never after it, so the event payload references a DB row that is already durable. Escalation and compensation observability is EngineEventBus only (`Event.EscalationRaised`, `Event.CompensationTriggered`) — there is no `escalations` table. `data_object_writes` in particular is always-on regardless of observability sink configuration, because downstream write-audit reconstruction is a runtime debugger feature.

**B. Event-bus sinks** (routed through `EngineEventBus`, [EngineEventBus + EventSinks](#engineeventbus--eventsinks) — each sink toggled independently):

- **`console` sink** (default ON) — structured JSON to stdout via `logger_json`, filtered by `BFE_LOG_MIN_SEVERITY`.
- **`telemetry` sink** (default ON, owned by `peripheral_telemetry`) — increments `[:bfw_engine, :event_bus]` (Prometheus event-bus counter). Does **not** assemble `/stats` ([observability.md](./observability.md)).
- **`websocket` sink** (default ON, owned by `api_web`) — broadcasts the typed event on the WebSocket channel for subscribed clients. Data Object writes push `%Event.DataObjectWritten{}` so live debuggers/UIs can render the new value without re-querying. `SinkFailed` is not accepted.
- **plugin sinks** — any number of `@behaviour BfwEngine.Plugin.EventSink` implementations registered on boot ([plugins.md](./plugins.md)). Example plugin targets: Datadog, Prometheus push-gateway, Kafka topic, custom S3 JSONL archive, a replica Postgres with different retention policy. Users who need DB-backed event storage implement this as a plugin sink with its own connection pool.

All sinks run **concurrently** under supervised `Task`s started from `EngineEventBus`. A crash in one sink never affects another sink, never affects kernel-state persistence, and never affects core_execution (see [EngineEventBus + EventSinks](#engineeventbus--eventsinks-d37) for the `Event.SinkFailed` isolation model). `core_execution.publish/1` is always non-blocking — the hot path does not wait for sinks.

**Integration tests** assert kernel tables (`flow_node_instances`,
`data_object_writes`, `gateway_pending_arrivals`, and so on). The engine
does not persist typed events to `process_instance_events`; that table
exists for schema compatibility and stays empty unless a plugin sink
writes it.

## Root Process Instance ID and WebSocket Fan-out

Every Process Instance carries `root_process_instance_id` in its runtime state (`BfwEngine.Execution.ProcessInstance.State`). For root-level PIs (started via REST/API with no parent), this equals `process_instance_id`. For child PIs spawned by Call Activity or Embedded SubProcess handlers, it is inherited from the parent handler's `HandlerContext` via `start_opts`, propagating to any nesting depth.

**Event struct field.** PI-scoped event types include `root_process_instance_id`, always populated from PI runtime state when emitted:

| Event Type | Wire key |
|------------|----------|
| `ProcessInstanceStateChanged` | `rootProcessInstanceId` |
| `FlowNodeInstanceStarted` | `rootProcessInstanceId` |
| `FlowNodeInstanceFinished` | `rootProcessInstanceId` |
| `FlowNodeInstanceStateChanged` | `rootProcessInstanceId` |
| `UserTaskCreated` | `rootProcessInstanceId` |
| `UserTaskFinished` | `rootProcessInstanceId` |
| `DataObjectWritten` | `rootProcessInstanceId` |
| `TimerFired` | `rootProcessInstanceId` |
| `MessageArrived` | `rootProcessInstanceId` |
| `SignalArrived` | `rootProcessInstanceId` |
| `CallActivityChildStarted` | `rootProcessInstanceId` |
| `SubProcessChildStarted` | `rootProcessInstanceId` |
| `CompensationTriggered` | `rootProcessInstanceId` |
| `ActivityCompensated` | `rootProcessInstanceId` |
| `TransactionCancelled` | `rootProcessInstanceId` |
| `MultiInstanceStarted` | `rootProcessInstanceId` |
| `MultiInstanceCompleted` | `rootProcessInstanceId` |

Child-spawn observability events (`CallActivityChildStarted`, `SubProcessChildStarted`) carry both `parent_process_instance_id` and `root_process_instance_id` of the emitting parent PI so a root-only WebSocket subscription receives nested spawns.

A Compensate Intermediate Throw Event does **not** emit `FlowNodeInstanceStateChanged` for a waiting→finished transition. Compensation runs synchronously in the throw handler; the throw FNI goes active→finished and emits `FlowNodeInstanceFinished` (plus `CompensationTriggered` / `ActivityCompensated`). `waitForCompletion="false"` is parsed but treated as `true`.

**WebSocket sink fan-out.** The WebSocket sink (`BfwEngineWeb.Ws.Sinks.WebSocket`, `apps/api_web/lib/bfw_engine_web/ws/sinks/websocket.ex`) broadcasts each accepted event to up to four PubSub topics:

1. `process_instance:<processInstanceId>` — when the event carries `process_instance_id` (primary targeted channel for the PI that produced the event). Events without `process_instance_id` (child-spawn notifications) use `parent_process_instance_id` instead.
2. `process_instance:<rootProcessInstanceId>` — when `root_process_instance_id` is present **and** differs from the primary PI id (`process_instance_id` or, for child-spawn events, `parent_process_instance_id`).
3. `engine:events` — global channel (always). PI-scoped events on this topic are filtered at dispatch by §5.1 visibility stamps plus the FNI lane gate (`EventDelivery.should_deliver?/2`).
4. `user_tasks:pending` — additionally, for `UserTaskCreated` and `UserTaskFinished` only (lane-filtered inbox).

When `root_process_instance_id` equals the primary PI id (a root PI's own events), the sink skips the duplicate root broadcast. `TimerFired` from a cycle Timer Start (no process instance yet) may have both ids `null`.

**Handler propagation.** Call Activity and SubProcess handlers pass `root_process_instance_id: context.root_process_instance_id` in child `start_opts`. Root PI creation sets `root_process_instance_id` to `opts[:root_process_instance_id] || opts.process_instance_id` in `ProcessInstance.init/1`.

## Event Catalog

Selected `BfwEngine.Types.Event.*` structs published via `EngineEventBus`. WebSocket envelopes use camelCase keys. Opaque payload subtrees pass through unchanged.

| Event Type | Key Fields | Notes |
|------------|-----------|-------|
| `ProcessDefinitionDeployed` | `processModelId`, `version`, `source` | Emitted per deployed version from `persist_deploy_batch/3`. `source` is `"user:<id>"` or `"plugin:<name>"` |
| `ProcessDefinitionUndeployed` | `processModelId`, `version`, `source` | Emitted when a process version is soft-deleted. `version` is `null` for bulk undeploy |
| `ProcessDefinitionEnabled` | `processModelId`, `source` | Emitted when a process definition is re-enabled |
| `ProcessDefinitionDisabled` | `processModelId`, `source` | Emitted when a process definition is disabled |
| `MessagePublished` | `messageId`, `messageName`, `correlationValue`, `origin`, `deliveries`, `startedProcessInstanceIds`, `pending` | Emitted after pipeline completes |
| `MessageArrived` | `messageId`, `messageName`, `correlationValue`, `processInstanceId`, `flowNodeInstanceId`, `rootProcessInstanceId`, `laneName` | Emitted when a message reaches a waiting subscription |
| `SignalPublished` | `signalId`, `signalName`, `origin`, `deliveries`, `startedProcessInstanceIds`, `pending`, `occurredAt` | Emitted after the signal broadcast pipeline completes. No payload, no correlation |
| `SignalArrived` | `signalId`, `signalName`, `processInstanceId`, `flowNodeInstanceId`, `rootProcessInstanceId`, `laneName`, `occurredAt` | Emitted when a signal is delivered to a waiting catch/boundary FNI |
| `EscalationRaised` | `escalationCode`, `escalationName`, `processInstanceId`, `rootProcessInstanceId`, `flowNodeInstanceId`, `flowNodeId`, `throwType`, `laneName`, `occurredAt` | Emitted on every escalation throw — both caught and uncaught — and on REST/plugin inject. `throwType`: `"end_event"`, `"intermediate_throw"`, or `"api_trigger"`. Broadcast to `process_instance:<piId>` and `process_instance:<rootPiId>`. Paired with `[:bfw_engine, :escalation, :raised]` telemetry. `laneName` is the throw FNI's lane. |
| `ProcessInstanceStateChanged` | `processInstanceId`, `processModelId`, `version`, `parentProcessInstanceId`, `rootProcessInstanceId`, `oldState`, `newState`, `startedById`, `hasLanelessFlowNode`, `laneNames` | `rootProcessInstanceId` equals `processInstanceId` for root PIs; inherited for child PIs. Visibility stamps (`startedById`, `hasLanelessFlowNode`, `laneNames`) let `engine:events` apply §5.1 without a DB lookup. |
| `ProcessInstanceRetried` | `processInstanceId`, `targetProcessInstanceId`, `processModelId`, `version`, `previousState`, `previousVersion`, `newVersion`, `resetToFlowNodeInstanceId`, `retriedBy`, `startedById`, `hasLanelessFlowNode`, `laneNames` | Same visibility stamps as `ProcessInstanceStateChanged`. |
| `FlowNodeInstanceStarted` | `flowNodeInstanceId`, `processInstanceId`, `rootProcessInstanceId`, `flowNodeId`, `flowNodeType`, `eventType`, `laneName` | `rootProcessInstanceId` on all seven PI-scoped lifecycle events below. `laneName` is `null` for laneless FNIs (always delivered). |
| `FlowNodeInstanceFinished` | Same + `terminalState`, `typeProperties`, `errorInfo` | |
| `FlowNodeInstanceStateChanged` | `flowNodeInstanceId`, `processInstanceId`, `rootProcessInstanceId`, `flowNodeId`, `flowNodeType`, `eventType`, `laneName`, `oldState`, `newState` | Non-terminal state transitions (currently `active` → `waiting`) |
| `UserTaskCreated` | `flowNodeInstanceId`, `processInstanceId`, `rootProcessInstanceId`, `flowNodeId`, `laneName` | Also broadcast to `user_tasks:pending` |
| `UserTaskFinished` | Same + `outcome` | `outcome`: `completed` or `aborted`. Also broadcast to `user_tasks:pending` |
| `DataObjectWritten` | `processInstanceId`, `rootProcessInstanceId`, `flowNodeInstanceId`, `dataObjectId`, `writeId`, `previousValue`, `value`, `createdAt`, `laneName` | Emitted after each successful DOA write |
| `CallActivityChildStarted` | `callActivityFlowNodeInstanceId`, `parentProcessInstanceId`, `childProcessInstanceId`, `childProcessModelId`, `childVersion`, `rootProcessInstanceId`, `laneName` | Paired with `[:bfw_engine, :call_activity, :child_started]` telemetry. `rootProcessInstanceId` is the emitting parent PI's root. |
| `SubProcessChildStarted` | `subprocessFlowNodeInstanceId`, `parentProcessInstanceId`, `childProcessInstanceId`, `subprocessNodeId`, `childProcessModelId`, `childVersion`, `isEventSubprocess`, `isAdHocSubprocess`, `rootProcessInstanceId`, `laneName` | Emitted when an Embedded SubProcess **or** Event Subprocess handler spawns a child PI. `subprocessNodeId` is the BPMN element ID of the `<bpmn:subProcess>` shell; `childProcessModelId` is the synthetic `parentProcessId__subprocess__subprocessNodeId` string. `isEventSubprocess` is `true` for Event Subprocess (`triggeredByEvent="true"`) shells and `false` for plain embedded subprocesses — the debugger's primary Event Subprocess observability signal. `rootProcessInstanceId` is the emitting parent PI's root. Paired with `[:bfw_engine, :subprocess, :child_started]` telemetry |
| `EventSubprocessTriggered` | `scopeProcessInstanceId`, `rootProcessInstanceId`, `subprocessNodeId`, `childProcessInstanceId`, `triggerKind`, `isInterrupting`, `laneName`, `occurredAt` | Engine-level observability signal emitted by the scope PI when an Event Subprocess trigger fires and spawns an Event Subprocess child PI. `triggerKind` is one of `message`, `signal`, `timer`, `error`, `escalation`, `conditional`. Emitted **in addition** to `SubProcessChildStarted` (which is the debugger's primary ESP signal). Paired with `[:bfw_engine, :event_subprocess, :triggered]` telemetry. |
| `CompensationTriggered` | `processInstanceId`, `rootProcessInstanceId`, `flowNodeInstanceId`, `flowNodeId`, `throwType`, `activityRef`, `targetCount`, `laneName`, `occurredAt` | Emitted before handler dispatch. `throwType`: `:throw` or `:end`. `activityRef` may be `null` (broadcast). `targetCount` is 0 if no completed activities have handlers. Fan-out to PI and root PI channels. |
| `ActivityCompensated` | `processInstanceId`, `rootProcessInstanceId`, `compensatedFniId`, `handlerFniId`, `throwFniId`, `flowNodeId`, `handlerActivityId`, `laneName`, `occurredAt` | Emitted after each compensation handler completes. |
| `TimerFired` | `timerRef`, `processInstanceId`, `flowNodeInstanceId`, `flowNodeId`, `kind`, `rootProcessInstanceId`, `laneName`, `occurredAt` | Emitted when a catch, boundary, or start timer fires. `laneName` is `null` when there is no FNI. Cycle Timer Start fires (no PI yet) leave `processInstanceId` and `rootProcessInstanceId` null. Scheduler telemetry `[:bfw_engine, :timer, :armed|:fired|:cancelled]` is the operational counterpart; there are no typed `TimerArmed` / `TimerCancelled` events. |

**Messages vs signals.** Messages are routed by `(messageName, correlationValue)` and carry a payload — subscribers match on both name and correlation (see [routing.md](./routing.md) §3.5). Signals are pure broadcast: every subscription registered for the `signalName` receives a copy, with **no correlation key** and **no payload**. `origin` on `MessagePublished` / `SignalPublished` is a map with `source` (`"api"` \| `"pi"` \| `"plugin"`) plus optional `processInstanceId`, `flowNodeInstanceId`, `pluginName`, and `triggeredBy`. `deliveries` is a list of `{processInstanceId, flowNodeInstanceId}` pairs — one entry per recipient. `startedProcessInstanceIds` lists PIs created via Message/Signal Start Events during the same publish. `pending` is `true` when zero subscriptions matched **and** zero Start Events fired, and the publish was buffered for TTL rematch ([routing.md](./routing.md) §3.5.6 for signals).

Message events are paired with `:telemetry.execute/3` on `[:bfw_engine, :message, :published]` and `[:bfw_engine, :message, :arrived]` respectively. Signal events are paired with `[:bfw_engine, :signal, :published]` and `[:bfw_engine, :signal, :arrived]`. Struct definitions live in `apps/core_types/lib/bfw_engine/types/event.ex`; Jason encoders in `apps/core_events/lib/bfw_engine/events/json_encoders.ex`.

## Multi-Instance / Standard Loop Events

Two new event types support MI/Loop observability:

### `MultiInstanceStarted`

Emitted when a Multi-Instance or Standard Loop shell FNI begins execution.

| Field | Type | Description |
|-------|------|-------------|
| `flowNodeInstanceId` | string | Shell FNI ID |
| `processInstanceId` | string | Owning PI |
| `rootProcessInstanceId` | string or null | Root PI in a tree |
| `flowNodeId` | string | BPMN element ID |
| `flowNodeType` | atom/string | BPMN element type |
| `loopType` | string | `"parallel_mi"`, `"sequential_mi"`, or `"standard_loop"` |
| `totalIterations` | integer or null | Planned count (collection length for MI; null for Standard Loop) |
| `laneName` | string or null | Lane of the shell activity; `null` when laneless |
| `occurredAt` | DateTime | Event timestamp |

### `MultiInstanceCompleted`

Emitted when a Multi-Instance or Standard Loop shell FNI finishes.

| Field | Type | Description |
|-------|------|-------------|
| `flowNodeInstanceId` | string | Shell FNI ID |
| `processInstanceId` | string | Owning PI |
| `rootProcessInstanceId` | string or null | Root PI in a tree |
| `flowNodeId` | string | BPMN element ID |
| `flowNodeType` | atom/string | BPMN element type |
| `loopType` | string | `"parallel_mi"`, `"sequential_mi"`, or `"standard_loop"` |
| `totalIterations` | integer or null | Planned count |
| `completedIterations` | integer | Number of iterations that completed |
| `earlyBreak` | boolean | Whether loop terminated before exhausting all iterations |
| `laneName` | string or null | Lane of the shell activity; `null` when laneless |
| `occurredAt` | DateTime | Event timestamp |

### MI Fields on Existing FNI Events

`FlowNodeInstanceStarted`, `FlowNodeInstanceFinished`, and `FlowNodeInstanceStateChanged` now carry two optional fields for MI/Loop iteration FNIs:

| Field | Type | Description |
|-------|------|-------------|
| `multiInstanceId` | string or null | Shell FNI ID (set on iteration FNIs, null on shell FNIs and non-MI nodes) |
| `iterationIndex` | integer or null | Zero-based iteration position (set on iteration FNIs, null otherwise) |

These fields enable the Studio Debugger to group iteration FNIs under their shell and display iteration progress.

### Wire Format

Both new events are serialized as camelCase JSON by the `Jason.Encoder` implementations in `apps/core_events/lib/bfw_engine/events/json_encoders.ex`. The WebSocket sink broadcasts them to `process_instance:<piId>` and `process_instance:<rootPiId>` channels.

**SDK types:** `MultiInstanceStarted` and `MultiInstanceCompleted` in `@elraptorus/bfw_engine_sdk` (`events/engine-events.ts`). `loopType` is typed as `'parallel_mi' | 'sequential_mi' | 'standard_loop'`.

## Ad-hoc Subprocess Events

Two event types support ad-hoc subprocess observability:

### `AdHocActivityActivated`

Emitted when an inner activity of an ad-hoc subprocess is activated.

| Field | Type | Description |
|-------|------|-------------|
| `processInstanceId` | string | Ad-hoc child PI ID |
| `rootProcessInstanceId` | string or null | Root PI in a tree |
| `adhocFlowNodeInstanceId` | string | Shell FNI ID of the ad-hoc subprocess |
| `activatedFlowNodeInstanceId` | string | FNI ID of the activated inner activity |
| `activatedFlowNodeId` | string | BPMN element ID of the activated inner activity |
| `activationSource` | string | `"engine"`, `"api"`, or `"plugin"` |
| `laneName` | string or null | Lane of the activated inner activity; `null` when laneless |
| `occurredAt` | DateTime | Event timestamp |

### `AdHocSubProcessCompleted`

Emitted when the ad-hoc child PI terminates.

| Field | Type | Description |
|-------|------|-------------|
| `processInstanceId` | string | Ad-hoc child PI ID |
| `rootProcessInstanceId` | string or null | Root PI in a tree |
| `adhocFlowNodeInstanceId` | string | Shell FNI ID of the ad-hoc subprocess |
| `adhocNodeId` | string | BPMN element ID of the ad-hoc subprocess |
| `completionReason` | string | Why the ad-hoc PI completed (e.g. `"completion_signaled"`, `"natural_drain"`) |
| `totalActivations` | integer | Count of persisted FNIs in the ad-hoc child PI |
| `laneName` | string or null | Lane of the ad-hoc shell; `null` when laneless |
| `occurredAt` | DateTime | Event timestamp |

Both events carry `rootProcessInstanceId` and are broadcast to both `process_instance:<piId>` and `process_instance:<rootPiId>` channels via the standard root-PI fan-out.

### `SubProcessChildStarted` — ad-hoc flag

`SubProcessChildStarted` now carries `isAdHocSubprocess: boolean` (default `false`) alongside the existing `isEventSubprocess` flag. This enables the Studio debugger to distinguish ad-hoc child PI spawns from embedded subprocess and event subprocess spawns.

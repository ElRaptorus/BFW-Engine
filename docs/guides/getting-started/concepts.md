# Core Concepts

This page introduces the key concepts you need to work with the engine. For hands-on usage, see the [User Handbook](../handbook/deploying-processes.md).

## BPMN 2.0 in Brief

BPMN (Business Process Model and Notation) 2.0 is an ISO standard for defining executable business processes as directed graphs. A process consists of **flow nodes** (events, activities, gateways) connected by **sequence flows**. When a process instance runs, a logical **token** traverses the graph, carrying a payload through each node.

The engine parses BPMN XML, validates structural rules, and executes processes by dispatching tokens through flow node handlers. Each handler implements the runtime behavior for its BPMN element type.

## Engine Domain Model

### Process and Process Version

A **Process** is a named entry in the catalog, identified by its `processModelId` (the `id` attribute of `<bpmn:process>`). Each deploy creates a new **Process Version** — the engine always starts instances from the latest non-deleted version.

The `<evil:version>` extension element is mandatory on every executable process:

```xml
<bpmn:extensionElements>
  <evil:version>1.0.0</evil:version>
</bpmn:extensionElements>
```

### Process Instance (PI)

A running execution of a process version. PIs are isolated OTP processes (`:gen_statem`) with states: `running`, `finished`, `fatal`, `aborted`, `error`, `compensated`, `escalated`, or `cancelled`.

| State | Meaning | Retryable |
|-------|---------|-----------|
| `running` | In progress | n/a |
| `finished` | All tokens consumed via End Events (normal completion) | No |
| `fatal` | Engine crash / unhandled failure | Yes |
| `aborted` | User/API kill switch (tree-wide) | Yes |
| `error` | Error End Event (modeled BPMN error) | Yes |
| `compensated` | Finished after a Compensation End Event — business outcome, not a failure | No |
| `escalated` | Finished after an uncaught escalation propagated to root — business outcome | No |
| `cancelled` | Transaction subprocess cancelled via Cancel End Event — business outcome | No |

`:error` / `:fatal` / `:aborted` are retryable via the [Retry and Restart](../handbook/retry-restart.md) mechanism. `:compensated`, `:escalated`, and `:cancelled` are **terminal-but-handled** — they are intentional business outcomes and are not retryable.

### Flow Node Instance (FNI)

One step within a PI. When a token reaches a flow node, the engine creates an FNI and dispatches it to the appropriate handler. FNI states: `active` (executing), `waiting` (paused for external input), `finished`, `fatal`, `aborted` (stopped by an external actor), or `interrupted` (stopped by another BPMN element).

### Token

The data flowing through the graph. Each token carries a `payload` map and metadata about its origin. Tokens are subject to the engine-wide size cap (`EVIL_TOKEN_MAX_BYTES`, default 64 KiB).

### Final Tokens

When a PI finishes, each End Event that completed produces a **Final Token** — the token payload decorated with the End Event's ID and name. For linear processes this is a single-element list; parallel paths produce one entry per completed End Event.

### Identity

Every action carries an **Identity** derived from the caller's JWT claims. The identity includes `id`, `name`, `roles`, and domain-specific claims (e.g., `deploy_bpmn`, `lane:accounting`). See [Authentication](../api/authentication.md) for the full claim dictionary.

## The `evil:` Extension Namespace

The engine extends BPMN with custom elements under `xmlns:evil="https://evilengine.dev/schema/bpmn"`:

| Extension | Element Type | Purpose |
|-----------|-------------|---------|
| `evil:version` | Process | Mandatory version identifier |
| `evil:correlationKey` | Process | FEEL expression for message correlation |
| `implementation` (BPMN attr) | Service Task | Handler dispatch key (e.g., `"http"`) |
| `evil:httpUrl`, `evil:httpMethod`, `evil:httpBody`, `evil:httpAuthHeader` | Service Task | Built-in HTTP handler config |
| `evil:assignees` | User Task | FEEL expression that resolves to the list of assignees at runtime (e.g. `identity.groups` or `["clerk_role", "manager_role"]`) |
| `evil:formFields` | User Task | Formkit-opaque form definition |
| `evil:resultContract` | User Task | JSON Schema for result validation |
| `evil:dueDate`, `evil:priority` | User Task | Task metadata |
| `evil:requireConfirmation` | Manual Task | When `true`, task waits for operator confirmation |
| `evil:scriptRef` | Script Task | Named script plugin key (dispatches to `NamedScript` handler) |
| `evil:inputMapping` / `evil:outputMapping` | Call Activity | FEEL expressions mapping variables between parent and child process scopes |
| `evil:valueContract` | Data Object | JSON Schema for validating Data Object writes |

## Data Objects

**Data Objects** are named data containers scoped to a process instance. Flow nodes write to Data Objects via `<bpmn:dataOutputAssociation>` elements and read them via FEEL expressions (`dataObjects.<id>.<property>`). Each write is persisted as a snapshot and an audit trail row. An optional `<evil:valueContract>` JSON Schema can enforce data shape on every write.

See the [Data Objects handbook](../handbook/data-objects.md) for full documentation.

## FEEL Expressions

FEEL (Friendly Enough Expression Language) is the expression language from the DMN specification, used for conditions, mappings, and computed values. The engine evaluates FEEL via a high-performance Rust NIF.

Expressions operate within a context of seven root bindings: `token`, `this`, `context`, `dataObjects`, `process`, `processInstance`, and `identity`. An optional `loop` overlay is added during Multi-Instance iterations.

For the full expression reference including types, built-in functions, and examples, see [FEEL Expressions](../handbook/expressions.md).

## Plugin System

The engine is extensible through a behaviour-based plugin system. Plugins implement one or more `@behaviour` modules from the `engine_sdk`:

| Behaviour | Purpose |
|-----------|---------|
| `EvilEngine.Plugin.ServiceTaskHandler` | Handle Service Task execution for an `implementation` key |
| `EvilEngine.Plugin.EventSink` | Receive engine events (logging, monitoring, etc.) |
| `EvilEngine.Plugin.RestApiExtension` | Mount additional REST/HTTP routes |
| `EvilEngine.Plugin.NamedScript` | Handle `evil:scriptRef` execution |
| `EvilEngine.Plugin.AuthProvider` | Replace the built-in JWT verifier with custom identity resolution |
| `EvilEngine.Plugin.PersistenceAdapter` | **Not in v1** — registration may be accepted and ignored |
| `EvilEngine.Plugin.MonitoringPanel` | **Not in v1** — registration may be accepted and ignored |
| `EvilEngine.Plugin.TimerSource` | **Not in v1** — registration may be accepted and ignored |
| `EvilEngine.Plugin.DataStoreAdapter` | **Not in v1** — DataStores are a parser no-op; registration may be accepted and ignored |

Plugins are loaded at engine boot via `on_load(engine_facade)` and receive an `on_ready(engine_facade)` callback once the full engine is reachable. See [Plugin Development](../plugins/getting-started.md) for implementation details.

## Link Events

**Link Events** provide an intra-process GOTO. A Link Throw Event transfers the token to a matching Link Catch Event within the same process scope by name, without requiring explicit sequence flows between them. They are always intermediate events and are validated at runtime (orphan throws or duplicate catches cause `fatal`).

See the [Link Events handbook](../handbook/link-events.md) for full documentation.

## Process Instance Retry

Terminal PIs (`fatal`, `aborted`, or `error`) can be restarted via `PUT /process-instances/{id}/retry`. Retry supports optional version migration to a newer compatible process definition and checkpoint-based partial restarts. `:compensated`, `:escalated`, and `:cancelled` are not retryable.

See the [Retry and Restart handbook](../handbook/retry-restart.md) for full documentation.

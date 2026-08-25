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

`:error` / `:fatal` / `:aborted` are retryable via the [Retry](../handbook/retry.md) mechanism. `:compensated`, `:escalated`, and `:cancelled` are **terminal-but-handled** — they are intentional business outcomes and are not retryable.

### Flow Node Instance (FNI)

One step within a PI. When a token reaches a flow node, the engine creates an FNI and dispatches it to the appropriate handler. FNI states: `active` (executing), `waiting` (paused for external input), `finished`, `fatal`, `aborted` (stopped by an external actor), `interrupted` (stopped by another BPMN element such as a Terminate End Event or interrupting boundary), or `error` (this FNI threw a modeled BPMN Error End Event, or was collateral of one).

### Token

The data flowing through the graph. Each token carries a `payload` map and metadata about its origin. Tokens are subject to the engine-wide size cap (`EVIL_TOKEN_MAX_BYTES`, default 64 KiB).

### Final Tokens

When a PI finishes, each End Event that completed produces a **Final Token** — the token payload decorated with the End Event's ID and name. For linear processes this is a single-element list; parallel paths produce one entry per completed End Event.

### Identity

Every action carries an **Identity** derived from the caller's JWT claims. The identity includes `id`, `roles`, `groups`, and `claims` (e.g. `deploy_bpmn`, `lane:accounting`). There is **no** `name` field. See [Authentication](../api/authentication.md) for the full claim dictionary.

## The `evil:` Extension Namespace

The engine extends BPMN with custom elements under `xmlns:evil="https://evilengine.dev/schema/bpmn"`. The catalog below is the live engine extension vocabulary. FEEL notes live in [FEEL Expressions](../handbook/expressions.md).

### Process and definitions

| Extension | Where | Purpose |
|-----------|-------|---------|
| `evil:version` | Process (required) | Deployment version string |
| `evil:correlationKey` | Process | Catch-side FEEL correlation for messages |
| `evil:LinterRulesetScore` | Definitions → `evil:Properties` | Studio linter-gate scores (`rulesetId`, `scorePercent`, …) |

### Shared data pipeline

| Extension | Where | Purpose |
|-----------|-------|---------|
| `evil:inputMapping` / `evil:outputMapping` | Tasks, Call Activity, SubProcess, throw/catch events | FEEL `source` → `target` |
| `evil:payloadContract` / `evil:resultContract` | Tasks, throw/catch message events (flow-node `extensionElements`, never inside the event definition) | JSON Schema on input / output |
| `evil:dataContract` | Any flow node | JSON Schema with `direction` `input` or `output` |

### Service Task

| Extension | Notes |
|-----------|-------|
| `implementation` (BPMN attribute) | Required dispatch key (e.g. `"http"`) |
| `evil:httpUrl` / `evil:httpMethod` | Static text (not FEEL) |
| `evil:httpBody` / `evil:httpAuthHeader` / `evil:httpResponseHeaders` | FEEL |

### Business Rule Task

| Extension | Notes |
|-----------|-------|
| `implementation` | `"feel"` (inline `<script>`) or `"dmn"` |
| `evil:decisionRef` | Required for `"dmn"` |
| `evil:decisionElementId` | Which `<decision>` in a multi-decision model |
| `evil:resultVariable` | Output variable name |
| `evil:traceUnmatchedRules` | When `true`, DMN traces unmatched rules |

### Script, User, Manual

| Extension | Element | Notes |
|-----------|---------|-------|
| `evil:scriptRef` | Script Task | Named script plugin key |
| `evil:assignees` | User Task | FEEL list of assignees |
| `evil:formFields` | User Task | Formkit-opaque JSON |
| `evil:dueDate` | User Task | FEEL **or** ISO 8601 |
| `evil:priority` | User Task | Integer |
| `evil:requireConfirmation` | Manual Task | When `true`, waits for `FinishUserTask` |

### Message events

| Extension | Side | Notes |
|-----------|------|-------|
| `evil:inputMapping` | Throw / Send | FEEL maps the token into the published message body |
| `evil:outputMapping` | Catch / Receive | FEEL maps the received message into the token |
| `evil:correlationRetrievalExpression` | Throw | FEEL stamp on the published message |
| `evil:correlationKey` | Process (catch) | Catch-side expected correlation |

### Error (never on escalation)

| Extension | Where |
|-----------|-------|
| `evil:errorCode` / `evil:errorMessage` | Inside `<errorEventDefinition>` only |

Escalation identity is the global `<bpmn:escalation escalationCode="…">` referenced by `escalationRef`. Do not put `evil:errorCode` on an escalation definition.

### Call Activity / SubProcess / Ad-hoc

| Extension | Notes |
|-----------|-------|
| `evil:startEventId` | Call Activity: which child start event |
| `evil:activeElements` | Ad-hoc: FEEL list of inner activity IDs |
| `implementation` | Ad-hoc: plugin-managed mode when set |
| `<bpmn:completionCondition>` | Ad-hoc: standard FEEL completion |

### Multi-Instance / Standard Loop

| Extension / attribute | Notes |
|-----------------------|-------|
| `evil:inputCollection` / `evil:outputCollection` | MI collections |
| `evil:elementVariable` / `evil:outputElementVariable` | Item / output names |
| `evil:loopBreakCondition` | Sequential early exit |
| `evil:loopInterval` | ISO 8601 pause between sequential iterations |
| `evil:maxIterations` | Sequential: truncates. Parallel: fail-fast `collection_exceeds_max_iterations` |
| `testBefore` / `loopMaximum` / `<loopCondition>` | Standard loop |

### Data Object

| Extension | Purpose |
|-----------|---------|
| `evil:valueContract` | JSON Schema on every write |

## Data Objects

**Data Objects** are named data containers scoped to a process instance. Flow nodes write to Data Objects via `<bpmn:dataOutputAssociation>` elements and read them via FEEL expressions (`dataObjects.<id>.<property>`). Each write is persisted as a snapshot and an audit trail row. An optional `<evil:valueContract>` JSON Schema can enforce data shape on every write.

See the [Data Objects handbook](../handbook/data-objects.md) for full documentation.

## FEEL Expressions

FEEL (Friendly Enough Expression Language) is the expression language from the DMN specification, used for conditions, mappings, and computed values. The engine evaluates FEEL via a high-performance Rust NIF.

Expressions operate against seven root bindings (`token`, `this`, `context`, `dataObjects`, `process`, `processInstance`, `identity`) plus overlays: `loop.*` (MI / Standard Loop), `activatedCount` / `incomingCount` (Complex Join), and `performedActivities` / `activeCount` / `totalActivities` (ad-hoc completion). Identity has `id`, `roles`, `groups`, `claims` — **no** `name`.

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

Plugins are loaded at engine boot via `on_load(engine_facade)` and receive an `on_ready(engine_facade)` callback once the full engine is reachable. See [Plugin Development](../plugins/getting-started.md) for implementation details.

## Link Events

**Link Events** provide an intra-process GOTO. A Link Throw Event transfers the token to a matching Link Catch Event within the same process scope by name, without requiring explicit sequence flows between them. They are always intermediate events and are validated at runtime (orphan throws or duplicate catches cause `fatal`).

See the [Link Events handbook](../handbook/link-events.md) for full documentation.

## Process Instance Retry

Terminal PIs (`fatal`, `aborted`, or `error`) can be retried via `PUT /process-instances/{id}/retry`. There is no separate restart command. Retry supports optional version migration to a newer compatible process definition and checkpoint-based partial restarts. `:compensated`, `:escalated`, and `:cancelled` are not retryable.

See the [Retry handbook](../handbook/retry.md) for full documentation.

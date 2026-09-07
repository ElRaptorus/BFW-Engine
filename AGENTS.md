# ThomasTheDaemonEngine — Agent & Contributor Guide

> **TEST DATABASE — NON-NEGOTIABLE:** Before running ANY test command (`mix quality`, `mix test`, `mix test.integration`, etc.), you MUST ensure the PostgreSQL container is running. Copy-paste this one-liner:
>
> ```bash
> (docker inspect --format='{{.State.Running}}' evil-engine-postgres-test 2>/dev/null | grep -q true) || (docker start evil-engine-postgres-test 2>/dev/null || bash scripts/create-test-db.sh) && docker exec evil-engine-postgres-test pg_isready -U evil_engine && MIX_ENV=test mix ecto.migrate
> ```
>
> **"Integration tests deferred because the database is not running" is a rule violation. Start the container yourself. No exceptions.**
>
> **QUALITY GATE — NON-NEGOTIABLE:** After any Engine code change, run `mix quality` from the project root (after the database one-liner). That alias in `mix.exs` is the only acceptable completion check. Do not substitute a subset (`mix compile`, `mix test apps/…`, `mix credo`) and claim the work is verified. See `.cursor/rules/build.mdc`.

This document is the domain knowledge reference for ThomasTheDaemonEngine,
a BPMN 2.0 Workflow Engine built with Elixir/OTP and oceans of sacrificial blood collected from all over the false emperors rotting domain in honor of the [Blood God](https://wh40k.lexicanum.com/wiki/Khorne).
It covers the engine's custom BPMN extension vocabulary, parser expectations, validator rules, FEEL expression conventions, and project structure.

**Scope:** This reference covers Phase 0 through Phase 9 capabilities (BPMN
execution engine + DMN CL3 DRG decision engine + DMN observability traces +
BPMN compensation + ad-hoc subprocesses). It will be extended as new phases land.

**Coding conventions, build verification, test conventions, and review
checklists** are maintained in the Cursor-specific `.cursor/rules/` and
`.cursor/skills/` directories. This document does not duplicate that content.

---

## Test Database Container — MANDATORY

**Every agent MUST start the PostgreSQL test container before running any tests.** This is non-negotiable. "Integration tests deferred because the database is not running" is a rule violation.

### One-liner (copy-paste)

```bash
(docker inspect --format='{{.State.Running}}' evil-engine-postgres-test 2>/dev/null | grep -q true) || (docker start evil-engine-postgres-test 2>/dev/null || bash scripts/create-test-db.sh) && docker exec evil-engine-postgres-test pg_isready -U evil_engine && MIX_ENV=test mix ecto.migrate
```

### Step-by-step (if the one-liner fails)

```bash
# Check container status
docker inspect --format='{{.State.Running}}' evil-engine-postgres-test 2>/dev/null
# "true" → running, skip to migrations
# "false" → docker start evil-engine-postgres-test
# error/empty → bash scripts/create-test-db.sh

# Verify readiness
docker exec evil-engine-postgres-test pg_isready -U evil_engine

# Run pending migrations
MIX_ENV=test mix ecto.migrate
```

Container: `evil-engine-postgres-test` | Port: `5543` | User: `evil_engine` | Image: `postgres:16-alpine`

### Prohibited behaviors

- DO NOT write "deferred: requires running engine" in any plan, checklist, or TODO
- DO NOT mark integration tests as "N/A" or "skipped"
- DO NOT report "DB not available" without first attempting to start it
- DO NOT ask the user whether to start the container — just start it
- DO NOT treat integration tests as optional — they are part of the quality gate

**Relevant rules and skills:**
- `.cursor/rules/build.mdc` — `mix quality` is the required completion gate after every Engine code change (always-applied)
- `.cursor/rules/test-db-mandatory.mdc` — Zero-tolerance DB policy (always-applied)
- `.cursor/skills/ensure-test-db/SKILL.md` — Detailed troubleshooting steps
- `.cursor/skills/integration-testing/SKILL.md` — Full integration test guide
- `.cursor/skills/thorough-review/SKILL.md` — Full review checklist; §1 is `mix quality`

---

## Namespace Declaration

ThomasTheDaemonEngine uses standard BPMN 2.0 XML with custom extension
elements under the `evil:` namespace. The **canonical namespace URI** is
`https://evilengine.dev/schema/bpmn`. All new and existing BPMN files
**must** use this URI — older variants (`http://evilengine.dev/bpmn`,
`http://evilengine.io/schema/bpmn`) are deprecated and must not be used.

Every BPMN file consumed by the engine must declare the namespace in the
`<bpmn:definitions>` root element:

```xml
<bpmn:definitions
  xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL"
  xmlns:bpmndi="http://www.omg.org/spec/BPMN/20100524/DI"
  xmlns:dc="http://www.omg.org/spec/DD/20100524/DC"
  xmlns:di="http://www.omg.org/spec/DD/20100524/DI"
  xmlns:evil="https://evilengine.dev/schema/bpmn"
  targetNamespace="https://evilengine.dev/schema/bpmn"
  id="Definitions_1">
```

The parser strips namespace prefixes before matching element names, so
`evil:version` and `version` inside an `<extensionElements>` block are
treated identically.

---

## JSON Wire Contract

REST and WebSocket JSON surfaces use **camelCase structural keys**. GraphQL was already camelCase via AshGraphql. The three wire surfaces now agree.

**Boundary rule:** Structural fields defined in engine structs are camelCased by per-struct `Jason.Encoder` implementations in `EvilEngine.Types.Wire`. Opaque user-payload subtrees (`payload`, `result`, `inputToken`, `outputToken`, `startedWithContext`, `claims`, `formFields`, `typeProperties`, `errorInfo`, etc.) pass through unchanged — their nested keys are NOT transformed.

**Implementation:** `apps/core_types/lib/evil_engine/types/wire.ex` (conversion logic), `apps/core_events/lib/evil_engine/events/json_encoders.ex` (Jason.Encoder implementations).

---

## Extension Elements Reference

All `evil:*` extensions live inside `<bpmn:extensionElements>` on the
owning BPMN element. The parser (`SaxHandler`) reads them; the validator
enforces required ones.

### Process-Level Extensions

#### `evil:version` (required)

The deployment version string. The validator rejects any executable process
that does not carry a non-blank `<evil:version>`.

```xml
<bpmn:process id="order-process" name="Order Process" isExecutable="true">
  <bpmn:extensionElements>
    <evil:version>1.0.0</evil:version>
  </bpmn:extensionElements>
  ...
</bpmn:process>
```

#### `evil:correlationKey`

Optional process-level FEEL expression evaluated on **catch-side** subscribe
(Intermediate Catch, Boundary, Receive Task) against current PI state (token,
Data Objects, identity). The result becomes the subscription's
`expected_correlation_value` so only messages with a matching correlation
stamp are delivered. Also evaluated against the incoming payload when a
Message Start Event creates a new PI (there is no PI state yet).

```xml
<evil:correlationKey>token.orderId</evil:correlationKey>
```

#### `evil:LinterRulesetScore` (definitions-level)

Carries linter gate scores attached to the **definitions** at design time by
the Studio. Read by the deploy-time linter gate. Unlike other `evil:*`
extensions, these live at the **definitions level** — inside
`<bpmn:definitions>/<bpmn:extensionElements>/<evil:Properties>`, **not** on a
process. The element name is capitalised (`evil:LinterRulesetScore`, upper-L).

Every field is a string attribute; numeric values are bare (no `%` suffix):

| Attribute | Meaning |
|-----------|---------|
| `rulesetId` | Ruleset identifier (matched against gate config keys) |
| `scorePercent` | Score percentage as a bare number (e.g. `"92.5"`) |
| `complianceStatus` | Compliance status string (e.g. `"compliant"`) |
| `computedAtIso` | ISO 8601 timestamp of computation |
| `schemaVersion` | Score schema version string |
| `maxPoints` | Maximum achievable points |
| `penaltyPoints` | Penalty points deducted |
| `rawErrorFindings` | Number of error-level findings |
| `rawWarningFindings` | Number of warning-level findings |

```xml
<bpmn:definitions ...>
 <bpmn:extensionElements>
 <evil:Properties>
 <evil:LinterRulesetScore
 rulesetId="evil-default"
 scorePercent="92.5"
 complianceStatus="compliant"
 computedAtIso="2026-07-03T12:00:00Z"
 schemaVersion="1"
 maxPoints="100"
 penaltyPoints="7.5"
 rawErrorFindings="0"
 rawWarningFindings="2" />
 </evil:Properties>
 </bpmn:extensionElements>
 <bpmn:process id="order-process" ...>...</bpmn:process>
</bpmn:definitions>
```

The gate maps its six checks to these fields: `requirePresence` ← entry
present, `minScorePercent` ← `scorePercent`, `maxErrors` ← `rawErrorFindings`,
`maxWarnings` ← `rawWarningFindings`, `requireComplianceStatus` ←
`complianceStatus`, `schemaVersion` ← `schemaVersion`. See
`docs/architecture/configuration.md` §Linter Gate.

### ServiceTask Extensions

**Async-only contract:** All Service Task handlers must return
`{:async, flow_node_instance_id}` from `handle_enter/3` and complete later via
`facade.service_tasks.finish_async.(flow_node_instance_id, result)` or
`facade.service_tasks.fail_async.(flow_node_instance_id, code, message)`.
The `code` matches Error Boundaries with the same ranking as enter-time errors
(specific resolved `errorRef` / inline code before catch-all).
Synchronous `{:ok, %FlowNodeResult{}}` returns are not supported. For local,
synchronous computation, use a Script Task with a Named Script plugin instead.

#### `implementation` attribute (required)

Standard BPMN 2.0 attribute on `<bpmn:serviceTask>`. The string value is the
dispatch key for the plugin registry (for example `http` for the built-in HTTP
handler). The validator rejects any ServiceTask missing a non-blank
`implementation` attribute.

```xml
<bpmn:serviceTask id="Task_charge" name="Charge Payment" implementation="http">
</bpmn:serviceTask>
```

#### `evil:payloadContract`

Optional JSON Schema (as a JSON string) validated against the task's input
payload at runtime.

```xml
<evil:payloadContract>{"type":"object","required":["amount"]}</evil:payloadContract>
```

Also supported on throw-side message events (`IntermediateThrowEvent`,
`EndEvent`) and `SendTask` — placed at the flow-node's `<extensionElements>`
level (never inside `<messageEventDefinition>`).

#### `evil:resultContract`

Optional JSON Schema validated against the task's output at runtime. The
engine transitions the FNI to Fatal on schema violation.

```xml
<evil:resultContract>{"type":"object","required":["transactionId"]}</evil:resultContract>
```

Also supported on `<bpmn:userTask>` and on catch-side message events
(`IntermediateCatchEvent`, `BoundaryEvent`, `StartEvent`) and `ReceiveTask`
— placed at the flow-node's `<extensionElements>` level (never inside
`<messageEventDefinition>`).

#### ServiceTask HTTP extensions (`implementation` = `"http"`)

Used by the built-in `EvilEngine.Plugins.Builtin.HttpServiceTaskHandler`. **`evil:httpUrl`** and **`evil:httpMethod`** are **static** text (not FEEL). **`evil:httpBody`**, **`evil:httpAuthHeader`**, and **`evil:httpResponseHeaders`** are **FEEL** expressions evaluated with the standard bindings (`token`, `this`, `context`, `dataObjects`, `process`, `processInstance`, `identity`) plus any active `loop.*` overlay.

| Element | FEEL? | Description |
|---------|-------|-------------|
| `evil:httpUrl` | No | Request URL (required for the HTTP handler) |
| `evil:httpMethod` | No | HTTP verb; default `GET` |
| `evil:httpBody` | Yes | Request body |
| `evil:httpAuthHeader` | Yes | Value for the `Authorization` header |
| `evil:httpResponseHeaders` | Yes | Maps selected response headers into the task output (handler-specific) |

```xml
<bpmn:serviceTask id="Task_http" name="Call API" implementation="http">
  <bpmn:extensionElements>
    <evil:httpUrl>https://api.example.com/v1/echo</evil:httpUrl>
    <evil:httpMethod>POST</evil:httpMethod>
    <evil:httpBody>{ "message": token.message }</evil:httpBody>
    <evil:httpAuthHeader>"Bearer " + token.apiToken</evil:httpAuthHeader>
  </bpmn:extensionElements>
</bpmn:serviceTask>
```

### BusinessRuleTask Extensions

The Business Rule Task has two execution modes selected by the **standard
BPMN `implementation` attribute**:

| `implementation` | Mode | Required companion | Description |
|-------------------|------|--------------------|-------------|
| `"feel"` | FEEL | `<bpmn:script>` child element | Evaluate an inline FEEL expression |
| `"dmn"` | DMN | `evil:decisionRef` | Evaluate a deployed DMN decision table via `DecisionResolver` → `ModelCache` → `Evaluator` |

**Standard BPMN properties:** `implementation` (XML attribute) and `<bpmn:script>`
(child element) are standard BPMN 2.0 properties. The `<script>` child element
reuses the same pattern as `<bpmn:scriptTask>`.

> Business Rule Tasks exclusively evaluate business rules via FEEL or DMN.
> Plugins observe BRT execution via engine events and analyze results through
> the facade — they never replace the execution path.

#### `evil:decisionRef`

DMN decision model reference. Required when `implementation="dmn"`. The engine
resolves the latest version of the DMN model at runtime.

```xml
<bpmn:businessRuleTask id="BRT_1" name="Evaluate Table" implementation="dmn">
  <bpmn:extensionElements>
    <evil:decisionRef>discount-rules</evil:decisionRef>
  </bpmn:extensionElements>
</bpmn:businessRuleTask>
```

#### `evil:decisionElementId`

Optional. When a DMN model contains multiple `<decision>` elements,
specifies which decision element to evaluate as the DRG root. Passed
as `decision_id` to `DMN.Evaluator.evaluate/4`. When omitted, the
evaluator auto-resolves single-decision models; multi-decision models
without this element produce `{:error, {:ambiguous_decision, ...}}`.

```xml
<bpmn:businessRuleTask id="BRT_1" name="Evaluate Risk" implementation="dmn">
  <bpmn:extensionElements>
    <evil:decisionRef>order-risk-rules</evil:decisionRef>
    <evil:decisionElementId>Decision_Risk_Level</evil:decisionElementId>
  </bpmn:extensionElements>
</bpmn:businessRuleTask>
```

#### `evil:resultVariable`

Output variable name for the decision result.

#### `evil:traceUnmatchedRules`

When `true` and `implementation="dmn"`, the DMN evaluator includes full detail
for unmatched rules in the execution trace.

#### FEEL mode example

```xml
<bpmn:businessRuleTask id="BRT_1" name="Discount Rule" implementation="feel">
  <bpmn:script>{ discount: if token.amount > 100 then 0.1 else 0 }</bpmn:script>
</bpmn:businessRuleTask>
```

BusinessRuleTask also supports the shared data pipeline extensions:
`evil:inputMapping`, `evil:outputMapping`, `evil:payloadContract`,
`evil:resultContract` — same semantics as ServiceTask and ScriptTask.

### ScriptTask Extensions

#### `evil:scriptRef`

Named script plugin key. When set, the engine dispatches to the plugin
registered under this key (via `ScriptDispatch` → `ScriptRegistryDispatch`).
Takes precedence over the inline `<script>` body. The standard BPMN
`scriptFormat` attribute and `<script>` child element are parsed natively.

```xml
<bpmn:scriptTask id="Script_1" name="Custom Validation">
  <bpmn:extensionElements>
    <evil:scriptRef>my_validation_plugin</evil:scriptRef>
  </bpmn:extensionElements>
</bpmn:scriptTask>
```

ScriptTask also supports the shared data pipeline extensions:
`evil:inputMapping`, `evil:outputMapping`, `evil:payloadContract`,
`evil:resultContract` — same semantics as ServiceTask and UserTask.

### UserTask Extensions

#### `evil:assignees`

FEEL expression that resolves to the list of assignees at runtime.

```xml
<bpmn:userTask id="Task_review" name="Review Order">
  <bpmn:extensionElements>
    <evil:assignees>identity.groups</evil:assignees>
  </bpmn:extensionElements>
</bpmn:userTask>
```

**Cancel:** `cancel_user_task` aborts the **entire process tree** — the same
effect as `PUT /process-instances/{id}/abort`. Error Boundary Events do not
catch the abort.

#### `evil:formFields`

JSON string defining the form schema (Formkit-opaque).

```xml
<evil:formFields>{"fields":[{"name":"approved","type":"boolean"}]}</evil:formFields>
```

#### `evil:dueDate`

FEEL expression or ISO 8601 string for the task's due date.

```xml
<evil:dueDate>2025-12-01T10:00:00Z</evil:dueDate>
```

#### `evil:priority`

Integer priority value.

```xml
<evil:priority>5</evil:priority>
```

### ManualTask Extensions

#### `evil:requireConfirmation`

When `true`, the ManualTask waits for an explicit `FinishUserTask` call
instead of passing through immediately.

```xml
<bpmn:manualTask id="Task_pack" name="Pack Order">
  <bpmn:extensionElements>
    <evil:requireConfirmation>true</evil:requireConfirmation>
  </bpmn:extensionElements>
</bpmn:manualTask>
```

### Message Event Extensions

These extensions live inside the `<bpmn:extensionElements>` of a
`<bpmn:messageEventDefinition>`.

**Contract placement:** Message event contracts are **not** placed
inside the event definition. They use `<evil:payloadContract>` (throw-side) or
`<evil:resultContract>` (catch-side) at the **flow-node's own**
`<extensionElements>` level — the same location as task contracts. See the
`evil:payloadContract` and `evil:resultContract` sections above.

#### `evil:correlationRetrievalExpression`

FEEL expression evaluated on **throw-side** events (Intermediate Throw,
Message End Event, Send Task) against the outgoing token / handler context.
The result is stamped onto the published message as `correlation_value`
before delivery. Catch-side events do not use this extension — they rely on
the process-level `evil:correlationKey` instead.

```xml
<bpmn:intermediateThrowEvent id="Throw_payment" name="Notify Payment">
<bpmn:messageEventDefinition messageRef="Msg_payment">
  <bpmn:extensionElements>
      <evil:correlationRetrievalExpression>token.orderId</evil:correlationRetrievalExpression>
  </bpmn:extensionElements>
</bpmn:messageEventDefinition>
  <bpmn:incoming>Flow_In</bpmn:incoming>
  <bpmn:outgoing>Flow_Out</bpmn:outgoing>
</bpmn:intermediateThrowEvent>
```

Throw-side message shaping uses `evil:inputMapping` on the flow node (not the
event definition). Catch-side shaping uses `evil:outputMapping`. There is no
`evil:payload` or `evil:eventMapping` extension.

**One-sided Send / Receive pipeline:** Send Task and throw-side message events
consume `evil:inputMapping` + `evil:payloadContract` only (`outputMapping` in
XML is ignored). Receive Task and catch-side message events consume
`evil:resultContract` + `evil:outputMapping` only (`inputMapping` in XML is
ignored). Do not apply the unused side at runtime.

### Signal Event Extensions

Signals use **standard BPMN only** for identity — no `evil:*` correlation or
payload extensions. Signal routing is based on the global `<bpmn:signal>`
definition's `name` attribute, resolved via `signalRef` on the event definition.

| Mechanism | Applies to | Notes |
|-----------|------------|-------|
| `signalRef` on `<bpmn:signalEventDefinition>` | All signal event positions | Must reference a global `<bpmn:signal id="..." name="...">` |
| Global `<bpmn:signal@name>` | Routing key | Runtime resolves `signalRef` → `SignalDefinition.name`; blank `name` → FNI fatal (`:signal_name_blank`) |
| `evil:inputMapping` | Throw, End (signal) | FEEL over current token before publish (same semantics); does **not** become signal payload |
| `evil:outputMapping` | Catch, Boundary (signal) | FEEL over **existing token** after `{:signal_arrived, ...}`; signals carry no inbound payload |

**Not supported on signals:** `evil:correlationKey`,
`evil:correlationRetrievalExpression`. Signals carry no payload.

**Semantics:** broadcast-all by `signal_name`; no payload; no
correlation; Signal Start + catch/boundary fire **simultaneously** (no
catch-wins-over-start); pending signals use **FIFO single-claim** drain.

### Error Event Extensions

These live inside `<bpmn:extensionElements>` of an
`<bpmn:errorEventDefinition>`.

#### `evil:errorCode`

Runtime error code for matching boundary error events.

```xml
<evil:errorCode>VALIDATION_FAILED</evil:errorCode>
```

Catch-side Error Boundary matching resolves the boundary's code the same way as
throw-side: inline `evil:errorCode` if present, else global `<bpmn:error errorCode>`
via `errorRef`, else `nil` (catch-all). Ranking among boundaries on the same host:
first specific resolved-code match, then first catch-all. Document order is not a
specificity tiebreak. `fail_async` `error_code` uses this same matcher.

#### `evil:errorMessage`

Human-readable error message attached to the error event.

```xml
<evil:errorMessage>Input validation failed</evil:errorMessage>
```

### Compensation Extensions

#### `isForCompensation` (standard BPMN attribute on activities)

Boolean attribute on `<bpmn:task>`, `<bpmn:serviceTask>`, `<bpmn:scriptTask>`, `<bpmn:userTask>`, `<bpmn:manualTask>`, `<bpmn:sendTask>`, `<bpmn:receiveTask>`, and `<bpmn:callActivity>`. When `true`, the activity is a compensation handler — it will not be reached via normal sequence flow. Instead, it is linked to a Compensation Boundary Event via a `<bpmn:association>` and dispatched only when compensation is triggered.

```xml
<bpmn:task id="Task_UndoBooking" name="Undo Booking" isForCompensation="true" />
```

#### `<bpmn:association>` (standard BPMN)

Links a Compensation Boundary Event to its handler activity. `sourceRef` is the boundary event ID; `targetRef` is the handler activity ID. The parser resolves this at model-build time and stores the `compensation_handler_id` on the boundary event's data struct.

```xml
<bpmn:association id="Assoc_1" sourceRef="BE_Comp" targetRef="Task_UndoBooking" associationDirection="One" />
```

#### Compensation Boundary Event

A `<bpmn:boundaryEvent>` with `<bpmn:compensateEventDefinition>` and `cancelActivity="false"`. It does NOT execute at runtime — it serves as a passive registration carrier that links the host activity to a compensation handler via association.

```xml
<bpmn:boundaryEvent id="BE_Comp" attachedToRef="Task_Book" cancelActivity="false">
  <bpmn:compensateEventDefinition />
</bpmn:boundaryEvent>
```

#### Compensate Intermediate Throw Event

`<bpmn:intermediateThrowEvent>` with `<bpmn:compensateEventDefinition>`. Triggers compensation and the current path continues after all handlers complete.

- No `activityRef` → broadcast: all completed activities with compensation handlers are compensated in LIFO order
- `activityRef="Task_Book"` → targeted: only the specified activity's handler fires
- `waitForCompletion` (standard BPMN attribute on `<bpmn:compensateEventDefinition>`): default `true`. The engine always executes compensation synchronously (handlers run to completion before the token proceeds). `waitForCompletion="false"` is parsed but treated as `true` — asynchronous fire-and-forget compensation is not supported.

```xml
<bpmn:intermediateThrowEvent id="Throw_Comp" name="Compensate">
  <bpmn:compensateEventDefinition />
</bpmn:intermediateThrowEvent>
```

#### Compensate End Event

`<bpmn:endEvent>` with `<bpmn:compensateEventDefinition>`. Same handler dispatch as throw, but token is consumed (like a None End Event). If `compensation_end_reached` flag is set when the PI quiesces, terminal state is `:compensated` instead of `:finished`.

```xml
<bpmn:endEvent id="End_Compensate" name="Compensate and End">
  <bpmn:compensateEventDefinition />
</bpmn:endEvent>
```

### CallActivity Extensions

#### `evil:startEventId`

Selects which Start Event the called child process should begin at.
Required when the child process has multiple untyped Start Events;
optional when the child has exactly one. If specified but the target
Start Event does not exist in the child process, the engine returns
a `:start_event_not_found` error. If the child has multiple untyped
Start Events and this property is omitted, the engine returns an
`:ambiguous_start_event` error.

```xml
<bpmn:callActivity id="Call_fulfill" name="Fulfill Order" calledElement="order-fulfillment">
  <bpmn:extensionElements>
    <evil:startEventId>Start_Express</evil:startEventId>
  </bpmn:extensionElements>
</bpmn:callActivity>
```

#### `evil:inputMapping` / `evil:outputMapping`

Maps variables between the calling and called process scopes. `source` is
a FEEL expression, `target` is a variable name.

```xml
<bpmn:callActivity id="Call_fulfill" name="Fulfill Order">
  <bpmn:extensionElements>
    <evil:inputMapping source="token.orderId" target="orderId" />
    <evil:outputMapping source="result.trackingNumber" target="trackingNumber" />
  </bpmn:extensionElements>
</bpmn:callActivity>
```

### SubProcess Extensions

Embedded SubProcesses (`triggeredByEvent="false"`) support the same data pipeline extensions as Call Activity, except there is no `calledElement` or `evil:startEventId` — the inner scope is defined inline in the BPMN XML and the engine auto-selects the single None Start Event at runtime.

#### `evil:inputMapping` / `evil:outputMapping`

Maps variables between the parent process token and the subprocess child PI scope. `source` is a FEEL expression, `target` is a variable name. Semantics match Call Activity (see above).

```xml
<bpmn:subProcess id="SubProcess_validate" name="Validate Order">
  <bpmn:extensionElements>
    <evil:inputMapping source="token.orderId" target="orderId" />
    <evil:outputMapping source="result.validated" target="validated" />
  </bpmn:extensionElements>
  ...
</bpmn:subProcess>
```

#### `evil:payloadContract` / `evil:resultContract`

JSON Schema contracts on the subprocess shell's input and output, validated at runtime via `MappingHelper` (same semantics as Call Activity — violations are fatal to the shell FNI).

Boundary events may be attached to the subprocess shell or to activities inside the inner scope; error boundaries on the shell receive BPMN errors bubbled up from the child PI.

### Ad-hoc Subprocess Extensions

Standard BPMN attributes on `<bpmn:adHocSubProcess>`:

| Attribute | Type | Default | Description |
|-----------|------|---------|-------------|
| `ordering` | `Parallel` or `Sequential` | `Parallel` | Whether inner activities execute in parallel or one-at-a-time |
| `cancelRemainingInstances` | `true` or `false` | `true` | If true, remaining active/waiting FNIs are interrupted when the completion condition is met |

Standard BPMN child element:

#### `<bpmn:completionCondition>`

FEEL expression evaluated after each inner activity completes. The expression
receives special bindings: `performedActivities` (integer count of finished
inner FNIs), `activeCount` (currently active/waiting FNIs), `totalActivities`
(total inner activities in the model). When the expression evaluates to `true`,
the ad-hoc subprocess completes.

#### `evil:activeElements`

FEEL expression that returns a list of flow node IDs to activate initially.
Evaluated against the standard FEEL bindings (`token`, `this`, `context`, etc.).
Required when `ordering="Sequential"` and no `implementation` is set.
Sequential engine-managed mode activates **only the first** matching ID in that
list; remaining IDs are logged and ignored at start. `AdHocMode` auto-chain then
advances through remaining unperformed inner activities (model order).

#### `implementation` attribute

Optional. When set, the ad-hoc subprocess operates in plugin-managed mode —
the plugin controls which activities are activated via the facade. When absent,
the engine manages activation based on `evil:activeElements` or activates all
inner activities.

Also supports: `evil:inputMapping`, `evil:outputMapping`, `evil:payloadContract`,
`evil:resultContract` — same semantics as embedded SubProcess.

### Event Subprocess Extensions / Semantics

An **Event Subprocess (ESP)** is a `<bpmn:subProcess triggeredByEvent="true">`
placed inside a process (top-level) or inside an embedded subprocess. It has
**no incoming or outgoing sequence flows** — it is not entered by a token.
Instead it lies dormant until its single **event start event** is triggered
by an event that occurs within its enclosing **scope** (the process or
subprocess that contains it). When triggered, the engine spawns a **child
process instance** running the ESP's inner flow — the same execution model as
an embedded subprocess (`EvilEngine.Execution.FlowNodes.EventSubprocess`
handler; child PI within the same deployment/version, no separate deploy).

#### Trigger types

The ESP start event's event definition selects the trigger. Two mechanisms
back them:

| Trigger | Mechanism | Notes |
|---------|-----------|-------|
| Message | Subscription registered at scope activation | Gated start event — **not** a message fan-out delivery (ESP-D13) |
| Signal | Subscription registered at scope activation | Broadcast-all by signal name |
| Timer | Scheduler registration at scope activation | `timeDuration` / `timeDate` / `timeCycle`; cyclic supported for non-interrupting (see below) |
| Conditional | Edge-triggered re-evaluation | Fires on a `false → true` transition of the FEEL condition |
| Error | Reactive hook (`EventSubprocessResolver`) | Catches a BPMN error raised within the scope; **must be interrupting** (ESP-D7) |
| Escalation | Reactive hook (`EventSubprocessResolver`) | Catches an escalation raised within the scope |
| Compensation | Reactive hook (`CompensationResolver`) | Consumes a thrown compensation for the scope; registered as scope's compensation handler (COMP-D5) |

#### `isInterrupting` (standard BPMN attribute on the ESP start event)

`isInterrupting="true"` (the BPMN default) makes the ESP **interrupting**;
`isInterrupting="false"` makes it **non-interrupting**. This is
modeler-controlled only — there is no property-pane toggle and no `evil:*`
override.

- **Interrupting:** on trigger, the engine cancels every other active/waiting
  Flow Node Instance in the scope (`interrupt_remaining_fnis`, terminal state
  `:interrupted`), runs the ESP child, then the scope finishes. The
  interrupting fire does **not** kill the scope PI itself — the scope reaches
  `:finished` (never `:aborted`/`:fatal` merely because the ESP fired). Two
  concurrent interrupting triggers are idempotent: the first wins, the second
  is a no-op.
- **Non-interrupting:** the ESP child runs in parallel with the rest of the
  scope. It may fire multiple times (each fire spawns an independent child
  PI). The scope only finishes once the main flow **and** every ESP child PI
  have completed.

#### Start-event scope (which triggers may be interrupting vs non-interrupting)

| Trigger | Interrupting | Non-interrupting |
|---------|:---:|:---:|
| Message | ✓ | ✓ |
| Signal | ✓ | ✓ |
| Timer | ✓ | ✓ |
| Conditional | ✓ | ✓ |
| Escalation | ✓ | ✓ |
| Error | ✓ | — (Error must interrupt, ESP-D7) |
| Compensation | ✓ | — (Compensation consumes scope, always interrupting) |

#### Cyclic timer ESP starts

A `timeCycle` (e.g. `R/PT1H`) is supported on a **non-interrupting** timer
ESP start. The recurrence is owned by the **scope** (the scope re-arms the
cycle timer after each tick); each tick spawns a fresh, independent ESP child
PI. The child's own timer start passes through as a None start event on its
initial dispatch, so the child does not re-schedule the cycle.

#### Message / escalation precedence

- **ESP-D13:** an Intermediate Catch or Boundary event **always** beats an ESP
  Message Start for the same message — the ESP message start is a gated start
  event, not a fan-out delivery. **ESP-D13b:** an ESP Message Start beats a
  standalone Message Start Event (a running instance handles the message; no
  new top-level PI is created).
- **Escalation proximity:** a scope-level escalation ESP start catches an
  escalation raised in that scope (interrupting or non-interrupting) **before**
  it propagates to the parent, resolved via
  `EventSubprocessResolver.find_matching_escalation_start/2`. A **specific**
  escalation code beats a **catch-all** (no-code) ESP escalation start. The
  same specificity rule applies to error ESP starts.

#### Observability

Triggering emits an `EventSubprocessTriggered` engine event, and the child
spawn emits `SubProcessChildStarted` carrying the mandatory
`is_event_subprocess: true` flag (ESP-D16). See §Engine Events and
[`docs/architecture/event-system.md`](docs/architecture/event-system.md).

#### Not supported

Multiple / Parallel-Multiple start events are not supported.

### Data Contract Extension

#### `evil:dataContract`

JSON string defining a typed data contract on any flow node. Contains
`direction` (`"input"` or `"output"`) and `schema` (JSON Schema map).

```xml
<evil:dataContract>{"direction":"input","schema":{"type":"object","required":["orderId"]}}</evil:dataContract>
```

### Data Object Extensions

#### `evil:valueContract`

JSON Schema string on a `<bpmn:dataObject>` element. Validates every value
written to this Data Object via DOA. Violation is fatal to the causing FNI.

```xml
<bpmn:dataObject id="DO_Order" name="Order">
  <bpmn:extensionElements>
    <evil:valueContract>{"type":"object","required":["status"]}</evil:valueContract>
  </bpmn:extensionElements>
</bpmn:dataObject>
```

#### `<bpmn:dataOutputAssociation>` (standard BPMN)

Declares that a flow node writes to a Data Object on completion.
`<bpmn:targetRef>` points to a `DataObjectReference` ID.
Optional `<bpmn:transformation>` contains a FEEL expression for value projection.

```xml
<bpmn:serviceTask id="Task_1">
  <bpmn:dataOutputAssociation id="DOA_1">
    <bpmn:targetRef>OrderDataRef</bpmn:targetRef>
    <bpmn:transformation>token.payment_result</bpmn:transformation>
  </bpmn:dataOutputAssociation>
</bpmn:serviceTask>
```

#### `<bpmn:dataInputAssociation>` (standard BPMN)

Declares that a flow node reads from a Data Object. Parsed for BPMN fidelity
and diagram rendering; at runtime, reads happen via FEEL `dataObjects.*`.

```xml
<bpmn:dataInputAssociation id="DIA_1">
  <bpmn:sourceRef>OrderDataRef</bpmn:sourceRef>
</bpmn:dataInputAssociation>
```

### Multi-Instance Extensions

These live inside `<bpmn:extensionElements>` of a
`<bpmn:multiInstanceLoopCharacteristics>` element.

**Iteration scope model:** Multi-Instance uses a **lightweight iteration scope**
— iteration FNIs are created within the same process instance as the shell FNI,
grouped by `multi_instance_id` (a UUID column on `flow_node_instances`). No child
PIs are spawned. See the execution architecture docs for details.

**`loopCardinality` is NOT supported.** The parser stores the text, and the
validator rejects the deploy with `:loop_cardinality_not_supported`. Iteration
count is exclusively determined by the input collection length (or
`evil:maxIterations` cap).

#### `evil:inputCollection` / `evil:outputCollection`

FEEL expressions for the input collection to iterate over and the output
collection to aggregate results into.

```xml
<bpmn:multiInstanceLoopCharacteristics isSequential="false">
  <bpmn:extensionElements>
    <evil:inputCollection>token.items</evil:inputCollection>
    <evil:outputCollection>processedItems</evil:outputCollection>
  </bpmn:extensionElements>
</bpmn:multiInstanceLoopCharacteristics>
```

#### `evil:elementVariable`

Name of the variable bound to the current collection item in each iteration.
When set, the item is accessible as `loop.item` in FEEL expressions. Falls
back to `<bpmn:inputDataItem>` if the extension is absent.

```xml
<evil:elementVariable>item</evil:elementVariable>
```

#### `evil:outputElementVariable`

Name of the variable used to collect the output of each iteration into the
output collection. Falls back to `<bpmn:outputDataItem>` if the extension
is absent. When set, the engine uses this variable name as the key for
aggregating per-iteration results.

```xml
<evil:outputElementVariable>processedItem</evil:outputElementVariable>
```

#### `evil:loopBreakCondition`

FEEL expression evaluated after each iteration; loop terminates early when
it evaluates to `true`.

```xml
<evil:loopBreakCondition>errorCount > 3</evil:loopBreakCondition>
```

#### `evil:loopInterval`

Interval between sequential loop iterations (e.g. rate-limiting).

```xml
<evil:loopInterval>PT1S</evil:loopInterval>
```

#### `evil:maxIterations`

Safety cap on the number of iterations. Behavior differs by MI mode:

- **Sequential MI:** caps the collection — items beyond the limit are silently
  skipped (truncation).
- **Parallel MI:** fails with `collection_exceeds_max_iterations` if the input
  collection size exceeds the limit (fail-fast). This prevents accidentally
  spawning an unbounded number of parallel iterations.

```xml
<evil:maxIterations>100</evil:maxIterations>
```

### Standard Loop Extensions

Standard loop characteristics (`<bpmn:standardLoopCharacteristics>`) use
standard BPMN attributes and one `evil:*` extension.

**Standard BPMN properties:**

| Property | XML location | Description |
|----------|-------------|-------------|
| `testBefore` | XML attribute | `true` = while-do (check before first iteration); `false` (default) = do-while |
| `loopMaximum` | XML attribute | Optional hard cap on iteration count |
| `<bpmn:loopCondition>` | Child element | FEEL expression; loop continues while `true` |

**Engine extension:**

| Extension | Description |
|-----------|-------------|
| `evil:loopInterval` | ISO 8601 duration between iterations (polling/healthcheck pattern) |

```xml
<bpmn:scriptTask id="Task_poll" name="Poll Status" scriptFormat="feel">
  <bpmn:script>{ counter: loop.completed + 1 }</bpmn:script>
  <bpmn:standardLoopCharacteristics testBefore="true" loopMaximum="10">
    <bpmn:loopCondition>loop.completed &lt; 5</bpmn:loopCondition>
    <bpmn:extensionElements>
      <evil:loopInterval>PT1S</evil:loopInterval>
    </bpmn:extensionElements>
  </bpmn:standardLoopCharacteristics>
</bpmn:scriptTask>
```

Standard Loop uses the same lightweight iteration scope as Multi-Instance:
iteration FNIs in the same PI, grouped by `multi_instance_id`.

---

## Supported BPMN Element Types

The parser recognizes the following BPMN element types. Any element not in
this list is silently ignored.

### Activities

| XML element | Internal type | Type-specific data struct |
|-------------|---------------|--------------------------|
| `<bpmn:task>` | `:task` | `FlowNodeData.Task` |
| `<bpmn:userTask>` | `:user_task` | `FlowNodeData.UserTask` |
| `<bpmn:serviceTask>` | `:service_task` | `FlowNodeData.ServiceTask` |
| `<bpmn:manualTask>` | `:manual_task` | `FlowNodeData.ManualTask` |
| `<bpmn:scriptTask>` | `:script_task` | `FlowNodeData.ScriptTask` |
| `<bpmn:businessRuleTask>` | `:business_rule_task` | `FlowNodeData.BusinessRuleTask` |
| `<bpmn:sendTask>` | `:send_task` | `FlowNodeData.SendTask` |
| `<bpmn:receiveTask>` | `:receive_task` | `FlowNodeData.ReceiveTask` |
| `<bpmn:callActivity>` | `:call_activity` | `FlowNodeData.CallActivity` |
| `<bpmn:subProcess>` | `:sub_process` | `FlowNodeData.SubProcess` |
| `<bpmn:transaction>` | `:sub_process` | `FlowNodeData.SubProcess` (`is_transaction: true`) |
| `<bpmn:adHocSubProcess>` | `:sub_process` | `FlowNodeData.SubProcess` (`is_ad_hoc: true`) |

`<bpmn:subProcess>` covers both embedded subprocesses (`triggeredByEvent="false"`,
the default) and **Event Subprocesses** (`triggeredByEvent="true"`) — both are
supported. The `triggered_by_event` boolean on `FlowNodeData.SubProcess`
distinguishes them, and the ESP variant is dispatched to the
`EventSubprocess` handler. See §Event Subprocess Extensions / Semantics.

`<bpmn:transaction>` is parsed as `:sub_process` with `is_transaction: true` on
`FlowNodeData.SubProcess`. The handler routing in `SubProcess.handle_enter` branches
on this flag to use `TransactionSubProcess` handler. The optional `method` attribute is
parsed and stored as `transaction_method` but not executed (no wire-level protocol
integration). See §Transaction Subprocess + Cancel Events.

`<bpmn:adHocSubProcess>` is parsed as `:sub_process` with `is_ad_hoc: true` on
`FlowNodeData.SubProcess`. The handler routing dispatches to
`FlowNodes.AdHocSubProcess`. Standard BPMN attributes `ordering` (`Parallel` /
`Sequential`), `cancelRemainingInstances` (`true` / `false`), and optional
`implementation` are parsed from the XML element. Inner activities have no
sequence flows — they are activated on demand or by the engine. See §Ad-hoc
Subprocess Extensions.

All activity types support the standard BPMN `isForCompensation="true"` attribute (default `false`). When set, the activity is a compensation handler — it has no incoming or outgoing sequence flows and is linked to a Compensation Boundary Event via `<bpmn:association>`. Activities with `isForCompensation="true"` are exempt from orphan-node checks. See §Compensation Extensions.

### Gateways

| XML element | Internal type | Type-specific data struct |
|-------------|---------------|--------------------------|
| `<bpmn:exclusiveGateway>` | `:exclusive_gateway` | `FlowNodeData.ExclusiveGateway` |
| `<bpmn:parallelGateway>` | `:parallel_gateway` | `FlowNodeData.ParallelGateway` |
| `<bpmn:inclusiveGateway>` | `:inclusive_gateway` | `FlowNodeData.InclusiveGateway` |
| `<bpmn:eventBasedGateway>` | `:event_based_gateway` | `FlowNodeData.EventBasedGateway` |
| `<bpmn:complexGateway>` | `:complex_gateway` | `FlowNodeData.ComplexGateway` |

`<bpmn:parallelGateway>` is **fully implemented**: AND-split fork (all outgoing sequence flows), AND-join merge (PI-level `dispatch_parallel_join` with last-wins-per-key token merge via `Map.merge/2`), crash-safe join persistence via `gateway_pending_arrivals`, resume mid-join via `ProcessInstance.Resumption.rebuild_join_arrivals/2`, and runtime rejection of mixed gateways (`{:error, :mixed_gateway}`). See [`docs/architecture/execution.md`](docs/architecture/execution.md) §Parallel Gateway.

### Events

| XML element | Internal type | Type-specific data struct |
|-------------|---------------|--------------------------|
| `<bpmn:startEvent>` | `:start_event` | `FlowNodeData.StartEvent` |
| `<bpmn:endEvent>` | `:end_event` | `FlowNodeData.EndEvent` |
| `<bpmn:intermediateCatchEvent>` | `:intermediate_catch_event` | `FlowNodeData.IntermediateCatchEvent` |
| `<bpmn:intermediateThrowEvent>` | `:intermediate_throw_event` | `FlowNodeData.IntermediateThrowEvent` |
| `<bpmn:boundaryEvent>` | `:boundary_event` | `FlowNodeData.BoundaryEvent` |

### Event Definitions

| XML element | Internal kind |
|-------------|---------------|
| `<bpmn:messageEventDefinition>` | `:message` |
| `<bpmn:signalEventDefinition>` | `:signal` |
| `<bpmn:timerEventDefinition>` | `:timer` |
| `<bpmn:errorEventDefinition>` | `:error` |
| `<bpmn:escalationEventDefinition>` | `:escalation` |
| `<bpmn:conditionalEventDefinition>` | `:conditional` |
| `<bpmn:compensateEventDefinition>` | `:compensation` |
| `<bpmn:terminateEventDefinition>` | `:terminate` |
| `<bpmn:cancelEventDefinition>` | `:cancel` |
| `<bpmn:linkEventDefinition>` | `:link` |

### Global Definitions

These are declared at the `<bpmn:definitions>` level (outside any process)
and referenced by ID from within event definitions or tasks:

| XML element | Referenced via |
|-------------|---------------|
| `<bpmn:message>` | `messageRef` attribute on event definitions, SendTask, ReceiveTask |
| `<bpmn:signal>` | `signalRef` attribute on signal event definitions |
| `<bpmn:error>` | `errorRef` attribute on error event definitions |
| `<bpmn:escalation>` | `escalationRef` attribute on escalation event definitions |

### Associations

| XML element | Internal type | Notes |
|-------------|---------------|-------|
| `<bpmn:association>` | `Association` | Parsed at model-build time; links Compensation Boundary Events to handler activities. Not a flow node. |

---

## Event Definition Position Rules

Not every event definition type is valid in every event position. The
validator rejects invalid combinations.

| Position | Allowed definitions |
|----------|---------------------|
| StartEvent (top-level / embedded-subprocess None start) | None, Message, Signal, Timer, Conditional |
| StartEvent (Event Subprocess) | Message, Signal, Timer, Conditional, Error, Escalation, Compensation |
| EndEvent | None, Message, Signal, Error, Escalation, Terminate, Cancel, Compensation |
| IntermediateCatchEvent | None, Message, Signal, Timer, Conditional, Link |
| IntermediateThrowEvent | None, Message, Signal, Escalation, Compensation, Link |
| BoundaryEvent | None, Message, Signal, Error, Timer, Escalation, Conditional, Compensation, Cancel |

**Cancel scope constraints (enforced at deploy time):**
- A **Cancel End Event** (`<bpmn:cancelEventDefinition>` on an `<bpmn:endEvent>`) is only valid inside a `<bpmn:transaction>` subprocess. Violation: `:cancel_end_outside_transaction`.
- A **Cancel Boundary Event** (`<bpmn:cancelEventDefinition>` on a `<bpmn:boundaryEvent>`) may only be attached to a `<bpmn:transaction>` subprocess shell. Violation: `:cancel_boundary_not_on_transaction`.
- At most one Cancel Boundary Event per transaction shell (spec constraint).
- Nested transactions are rejected at deploy time: `:nested_transaction`.

An **Event Subprocess start event** must carry a typed event definition —
Error, Escalation, and Compensation are valid there (unlike a top-level
StartEvent), and a None (untyped) start is rejected
(`:event_subprocess_untyped_start`). An Error ESP start must be interrupting
(ESP-D7). A Compensation start consumes a thrown compensation for its scope
(COMP-D5).

---

## Validator Rules

The validator (`EvilEngine.BPMN.Validator`) collects all violations and
returns them as a single error list so the user can fix every issue in one
pass. It never short-circuits on the first problem.

### Process-level checks

- Every executable process must have a non-blank `<evil:version>`
- Every executable process must contain at least one StartEvent
- Every executable process must contain at least one EndEvent

### Essential property completeness

- Every FlowNode must have a non-blank `id`
- Every SequenceFlow must have `id`, `sourceRef`, and `targetRef`
- Flow-node IDs must be **globally unique** across the process and every nested
  subprocess scope (recursively). A collision yields `duplicate_flow_node_id`.
  This keeps start-event resolution and subprocess scoping unambiguous — see
  Subprocess Start-Event Isolation below.

### Type-specific required properties

| Element type | Required properties |
|--------------|---------------------|
| CallActivity | `calledElement` |
| ServiceTask | `implementation` attribute |
| SendTask | `messageRef` |
| ReceiveTask | `messageRef` |
| ScriptTask | `script` or `scriptRef` (at least one) |
| BusinessRuleTask | `implementation` (must be `"feel"` or `"dmn"`); `feel` requires `<script>`, `dmn` requires `evil:decisionRef` |
| ComplexGateway (join) | `activationCondition` — required only when the gateway is a **join** (many incoming, one outgoing). See Complex Gateway rules below. |
| BoundaryEvent | `attachedToRef` |

### Event definition completeness

| Definition type | Required properties |
|-----------------|---------------------|
| MessageEventDefinition | `messageRef` |
| SignalEventDefinition | `signalRef` |
| TimerEventDefinition | `timeDate`, `timeDuration`, or `timeCycle` (exactly one) |
| ConditionalEventDefinition | `condition` expression |
| LinkEventDefinition | `name` |
| Error, Escalation, Compensation, Terminate, Cancel | No mandatory fields |

### Reference integrity

- SequenceFlow `sourceRef` / `targetRef` must point to existing FlowNode IDs
- Non-event FlowNodes (except start/end/boundary and Link events) must be connected to at least one SequenceFlow
- Link Intermediate Throw/Catch events with a `%EventDefinition.Link{}` are **exempt** from orphan-node checks (they intentionally lack outgoing/incoming sequence flows respectively)
- StartEvents must not have incoming SequenceFlows
- EndEvents must not have outgoing SequenceFlows
- DataObjectReference `dataObjectRef` must point to an existing DataObject ID
- DataOutputAssociation `targetRef` must point to an existing DataObjectReference ID
- DataInputAssociation `sourceRef` (when present) must point to an existing DataObjectReference ID
- `evil:valueContract` JSON Schema must be parseable by `ExJsonSchema`
- Event definition `messageRef` / `signalRef` / `errorRef` / `escalationRef` must match a global definition
- SendTask / ReceiveTask `messageRef` must match a global MessageDefinition
- BoundaryEvent `attachedToRef` must point to an existing FlowNode in the same process

### Event-Based Gateway checks

- Receive Tasks that are direct successors of an Event-Based Gateway must not have boundary events attached (boundary events on EBG targets create ambiguous cancellation semantics)

### Complex Gateway checks (deploy-time)

The Complex Gateway (`<bpmn:complexGateway>`) is executable with opinionated,
engine-specific semantics (**not portable BPMN**). `Validator.check_complex_gateways/1`
classifies each Complex Gateway by its incoming/outgoing flow counts and enforces:

- **Mixed rejection** — a gateway with `> 1` incoming **and** `> 1` outgoing is a
  mixed gateway → violation `complex_gateway_mixed`. A Complex Gateway must be
  a split (one in, many out) or a join (many in, one out), never both.
- **Split completeness is runtime, not deploy** — an unmarked non-default
  outgoing flow on a Complex Split fatals `:complex_gateway_unconditional_flow`
  when the split is entered. WIP diagrams may still deploy. Studio lints
  warning (`bpmn-development`) / error (`bpmn-production-ready`). Exclusive
  Gateway unmarked non-default outgoings are the same class: runtime fatal
  `:exclusive_gateway_unconditional_flow` before FEEL, no deploy validator.
  A single unmarked Exclusive Gateway outgoing is pass-through; a single
  outgoing that carries a condition is still evaluated (false + no default →
  `:no_matching_condition`).
- **Join rule** — for a join (`> 1` incoming), a non-blank `<bpmn:activationCondition>`
  is required → violation `complex_gateway_join_missing_activation_condition` when
  absent. The join is a single-fire **threshold** join: it fires when the FEEL
  `activationCondition` (with `activatedCount` / `incomingCount` bindings) becomes
  true. If all branches resolve but the condition is never met, the join FNI fatals
  with `complex_join_condition_unmet` (Twist 1).
- **Pairing / SESE rule (Twist 2)** — every Complex Join must pair to exactly one
  dominating Complex Split (`S = idom_complex(J)`), and the region between them must
  be single-entry / single-exit. `ComplexRegionAnalysis.region_violations/1` (folded
  into `check_complex_gateways/1`) rejects: an unpaired join
  (`complex_join_no_paired_split`), a flow that escapes the region other than through
  the split/join (`complex_region_cross_boundary`), and partially overlapping regions
  (`complex_region_overlap` — regions must be disjoint or strictly nested).

Runtime split outcomes: `complex_gateway_unconditional_flow` (unmarked
non-default outgoing), `complex_split_no_matching_condition` (zero truthy, no
default), `complex_split_condition_failed` (FEEL error). Runtime join outcomes:
`complex_join_condition_failed` (FEEL error). **Twist 2 cancellation:** when a
Complex Join fires, every `:active`/`:waiting` FNI whose flow node lies inside the
paired SESE region is interrupted (`Process.exit` + `handle_aborted/1` cleanup +
recursive child-PI abort) and persisted as `:interrupted` with reason
`:cancelled_by_complex_join`; unlike a Terminate/Error End Event this is scoped to
the region and does not purge process-wide subscriptions. Because cancellation
removes the losers, a straggler token reaching an already-fired join is absorbed
silently (Phase 5.1's interim `complex_join_already_fired` fatal was removed). See
[`docs/architecture/execution.md`](docs/architecture/execution.md) §Complex Gateway
and the user handbook `docs/guides/handbook/complex-gateways.md`.

### Embedded subprocess structural checks (deploy-time)

Non-event embedded subprocesses (`triggered_by_event: false`) are validated recursively at deploy time. Semantic rules (exactly one untyped Start Event, no typed start events, at least one End Event) are enforced at **runtime** in the SubProcess handler — WIP diagrams may deploy with incomplete start/end patterns inside subprocesses.

Inner-scope checks (messages prefixed with `[in SubProcess '<id>']`):

- Inner SequenceFlow `sourceRef` / `targetRef` must point to flow nodes inside the subprocess
- Inner non-event FlowNodes must be connected to at least one inner SequenceFlow (start/end/boundary, Link events, and event subprocess containers are exempt)
- Inner BoundaryEvent `attachedToRef` must resolve within the subprocess scope
- Inner flow nodes undergo the same type-specific completeness checks as top-level nodes (recursive for nested subprocesses)
- Cross-boundary flows are rejected: parent-scope SequenceFlows must not reference inner subprocess node IDs; inner SequenceFlows must not reference parent-scope node IDs

Event Subprocesses (`triggeredByEvent="true"`) **are** validated recursively at
deploy time (`validate_event_subprocess_structure`). They undergo the same
inner-scope structural checks as embedded subprocesses (messages prefixed
`[in Event SubProcess '<id>']`) **plus** ESP-specific start-event rules:

| Atom | Rejected condition |
|------|--------------------|
| `:event_subprocess_has_sequence_flow` | The ESP shell has an incoming or outgoing SequenceFlow (an ESP is triggered, never token-entered) |
| `:event_subprocess_no_start_event` | The ESP has no start event |
| `:event_subprocess_multiple_start_events` | The ESP has more than one start event |
| `:event_subprocess_untyped_start` | The ESP start event carries no event definition (a None start is not a valid trigger) |
| `:event_subprocess_error_start_must_interrupt` | The ESP start event is an Error start with `isInterrupting="false"` (Error must interrupt, ESP-D7) |

### Ad-hoc SubProcess structural checks (deploy-time)

Ad-hoc subprocesses (`<bpmn:adHocSubProcess>`, parsed as `:sub_process` with
`is_ad_hoc: true`) are validated at deploy time. Standard inner-scope validation
runs first, then ad-hoc-specific checks are applied on top:

| Atom | Rejected condition |
|------|--------------------|
| `:adhoc_subprocess_empty` | The ad-hoc subprocess contains no activities (tasks, call activities, subprocesses) |
| `:adhoc_subprocess_has_start_event` | The ad-hoc subprocess contains a Start Event |
| `:adhoc_subprocess_has_end_event` | The ad-hoc subprocess contains an End Event |
| `:adhoc_sequential_missing_active_elements` | `adhoc_ordering == :sequential` with no `implementation` and no `evil:ActiveElements` expression |
| `:adhoc_subprocess_empty_implementation` | `implementation` attribute is present but blank (whitespace-only) |

Nesting restrictions (checked recursively across all subprocess scopes):

| Atom | Rejected condition |
|------|--------------------|
| `:nested_adhoc_subprocess` | An ad-hoc subprocess is nested inside another ad-hoc subprocess |
| `:adhoc_inside_event_subprocess` | An ad-hoc subprocess is nested inside an event subprocess |

### Compensation-specific checks

- Activities with `isForCompensation="true"` are **exempt from orphan-node checks** — they intentionally have no incoming or outgoing sequence flows. They are linked to their host activity's Compensation Boundary Event via `<bpmn:association>`, not via sequence flows.
- A Compensation Start Event (`<bpmn:compensateEventDefinition>` on a `<bpmn:startEvent>`) is valid **only** inside an Event Subprocess (`triggeredByEvent="true"`). A Compensation Start on a top-level or embedded-subprocess start event is rejected by the Event Definition Position Rules.

### Subprocess Start-Event Isolation

A Start Event nested inside an embedded / event / (future) transactional
subprocess can **never** be started directly by an external caller (REST,
plugin, or Call Activity). Inner scopes are reachable only when the owning
subprocess element is executed by its parent process instance.

- **Public start contract:** `POST /processes/{model_id}/start` (and
  `EvilEngine.Api.start_process_instance/3`) accept only Model/Version + Start
  Event + payload/context/businessKey. `subprocess_node_id`,
  `parent_process_instance_id`, and `triggerer_flow_node_instance_id` are
  internal execution options, **not** public parameters. Extraneous request-body
  params are ignored (consistent with other endpoints), not rejected. The REST
  controller builds `start_opts` from only the public fields, so internal keys are
  structurally absent from that path.
- **Core invariant (authoritative guard):** `Execution.start_process_instance/1`
  rejects any call where `subprocess_node_id` is set but
  `parent_process_instance_id` is nil, returning `{:error, :orphan_subprocess_start}`.
  Every entry point (REST, plugin, Call Activity, SubProcess, ESP) flows through
  this single chokepoint.
- **Resolution scoping:** `ProcessInstance.resolve_start_event/2` resolves start
  events strictly against `process_model.flow_nodes` (top-level model, or the
  synthetic inner-scope model only when `subprocess_node_id` is set). Inner nodes
  live under `type_data.flow_nodes` and are never visible to top-level resolution.
- **Start-event indexing:** `ModelCache.find_message_start_events/1` and
  `find_signal_start_events/1` index only top-level start events; an inner
  Message/Signal Start Event can never be triggered by publishing its
  message/signal.
- **Deploy-time uniqueness:** the `duplicate_flow_node_id` validator rule (above)
  guarantees flow-node IDs do not collide across the process and nested subprocess
  scopes, removing resolution ambiguity.

See [`docs/architecture/security.md`](docs/architecture/security.md)
§Subprocess Start-Event Isolation and
[`docs/architecture/common-pitfalls.md`](docs/architecture/common-pitfalls.md)
(inner Start Events are never externally startable).

### Link event pair validation (runtime-only)

Link pair consistency checks are **not** performed at deploy time — they
happen at **runtime** when a Link Throw Event is reached:

- **No matching catch**: Link Throw with `link_name` "X" but no Link Catch
  with the same name in the same process → FNI fatal with
  `reason: :no_matching_link_catch`
- **Duplicate catches**: Multiple Link Catches share the same `link_name`
  → FNI fatal with `reason: :ambiguous_link_catch`
- **Exactly one match**: Token is routed directly to the matching Link
  Catch, bypassing sequence-flow resolution

This design allows WIP diagrams to be deployed in development environments.
In production, the Linter Gate and the Studio's linter catch these
issues at design time before the diagram reaches the engine.

### Error message format

All violations follow a consistent pattern:

```
[ElementType] '[elementId]' is missing required properties: [comma-separated list]
```

Example: `ServiceTask 'Task_charge' is missing required properties: implementation`

---

## FEEL Expressions

The engine evaluates FEEL (Friendly Enough Expression Language) expressions
via a Rust NIF wrapping the `dsntk` FEEL crates through Rustler.

### Context bindings

Every FEEL expression is evaluated against a context with these root
bindings (camelCase per the FEEL spec). All bindings are assembled by
`Context.from_handler_context/2` which converts atom-keyed runtime maps
to the string-keyed format required by the Rust NIF.

| Binding | Description |
|---------|-------------|
| `token` | Current flow node's input token (the runtime payload) |
| `this` | Current flow node metadata (`id`, `name`, `type`) — built by `Context.flow_node_this/1` |
| `context` | Immutable process-level variables from the start payload (`started_with_context`), available unchanged for the entire PI lifetime |
| `dataObjects` | Data objects attached to the process (by ID) |
| `process` | Process metadata (`id`, `name`, `version`) — string-keyed |
| `processInstance` | Instance metadata (`id`, `startedAt`, `startedBy`) — camelCase string-keyed |
| `identity` | Caller identity (`id`, `roles`, `groups`, `claims`) — string-keyed |
| `loop` | Iteration-scoped overlay (Multi-Instance / Standard Loop; `nil` when not in a loop). Sub-keys: `loop.index` (0-based), `loop.total` (collection length or `nil` for Standard Loop), `loop.completed` (count of finished iterations so far), `loop.results` (list of prior iteration results), `loop.item` (current collection element for MI; `nil` for Standard Loop) |
| `activatedCount` | Complex-Join overlay: number of incoming branches that have delivered a token so far. Present **only** while evaluating a Complex Gateway join's `<bpmn:activationCondition>` |
| `incomingCount` | Complex-Join overlay: total number of incoming sequence flows into the Complex Join. Present **only** while evaluating a Complex Gateway join's `<bpmn:activationCondition>` |
| `performedActivities` | Ad-hoc overlay: integer count of inner FNIs in `:finished` state. Present only while evaluating an ad-hoc subprocess's `<bpmn:completionCondition>` |
| `activeCount` | Ad-hoc overlay: integer count of inner FNIs in `:active` or `:waiting` state. Present only during ad-hoc completion condition evaluation |
| `totalActivities` | Ad-hoc overlay: total number of inner activities in the ad-hoc subprocess model. Present only during ad-hoc completion condition evaluation |

### Where FEEL appears

- `<bpmn:conditionExpression>` on **Split-Gateway-outgoing** SequenceFlows only (Exclusive, Inclusive, and Complex). Conditions on sequence flows whose source is anything other than a Split Gateway (Activity, Event, Gateway-join) are silently ignored at runtime; those flows are followed unconditionally. The Studio enforces this at modeling time.
- `<bpmn:script>` inside ScriptTasks and BusinessRuleTasks (when `implementation="feel"`)
- `<bpmn:condition>` inside `<bpmn:conditionalEventDefinition>` — FEEL expression re-evaluated by the PI on every state mutation until it becomes true
- `<bpmn:activationCondition>` inside `<bpmn:complexGateway>` (join only) — FEEL threshold expression re-evaluated on every arrival / state change; gets the `activatedCount` / `incomingCount` overlay bindings
- `<bpmn:timeDuration>`, `<bpmn:timeDate>`, `<bpmn:timeCycle>` (expression-based)
- `evil:assignees`, `evil:dueDate`,
  `evil:correlationRetrievalExpression`, `evil:correlationKey`,
  `evil:inputCollection`, `evil:outputCollection`, `evil:loopBreakCondition`,
  `<bpmn:completionCondition>` (MI), `<bpmn:loopCondition>` (Standard Loop)
- `evil:httpBody`, `evil:httpAuthHeader`, `evil:httpResponseHeaders` on Service Tasks with `implementation` `"http"` (built-in HTTP handler)
- `evil:inputMapping` / `evil:outputMapping` `source` attributes
- `<bpmn:completionCondition>` on ad-hoc subprocess — FEEL expression evaluated after each inner activity completion
- `evil:activeElements` — FEEL expression returning list of element IDs for initial activation
- `evil:dataContract` / `evil:payloadContract` / `evil:resultContract` do
  **not** contain FEEL — they contain JSON Schema

### Precompilation

Expressions are parsed at deploy time into an opaque compiled reference
using `EvilEngine.Expressions.compile/2`. At runtime,
`EvilEngine.Expressions.evaluate/2` evaluates the compiled reference
against the context without re-parsing.

For architecture details, see [`docs/architecture/expressions.md`](docs/architecture/expressions.md).

---

## Engine Events (WebSocket Wire Types)

Events are delivered via WebSocket in a camelCase JSON envelope:

```json
{
  "type": "ProcessInstanceStateChanged",
  "data": { ... },
  "occurredAt": "2026-05-07T12:00:00Z"
}
```

Selected `EvilEngine.Types.Event.*` structs fan out through `EngineEventBus`. Full catalog and sink semantics: [`docs/architecture/event-system.md`](docs/architecture/event-system.md).

### Current Events

| Event Type | Key Fields | Notes |
|------------|-----------|-------|
| `EngineStarted` | `engineId` | |
| `EngineShutdown` | `engineId` | |
| `EngineOverloaded` | `level`, `activeProcessInstances`, `limit` | Levels: `elevated`, `critical` |
| `EngineRecovered` | `previousLevel`, `activeProcessInstances`, `limit` | Symmetric counterpart to `EngineOverloaded`; emitted when load drops back to normal |
| `PluginQuarantined` | `pluginName`, `reason` | |
| `ProcessInstanceStateChanged` | `processInstanceId`, `processModelId`, `version`, `parentProcessInstanceId`, `rootProcessInstanceId`, `oldState`, `newState`, `startedById`, `hasLanelessFlowNode`, `laneNames` | `processModelId` is the BPMN process ID string; `version` is the `evil:version` string. `rootProcessInstanceId` equals `processInstanceId` for root PIs; inherited from parent for child PIs (SP-13). Visibility stamps drive `engine:events` dispatch without a DB lookup. |
| `FlowNodeInstanceStarted` | `flowNodeInstanceId`, `processInstanceId`, `rootProcessInstanceId`, `flowNodeId`, `flowNodeType`, `eventType`, `laneName`, `multiInstanceId`, `iterationIndex` | `flowNodeType` uses `FlowNodeType` enum values; `eventType` is the event definition subtype (`message`, `timer`, `error`, etc.) or `null` for non-event nodes and plain events. `multiInstanceId` / `iterationIndex` are set on MI/Loop iteration FNIs, `null` otherwise. `laneName` is `null` for laneless FNIs (always delivered on WebSocket). |
| `FlowNodeInstanceFinished` | Same + `terminalState`, `typeProperties`, `errorInfo`, `multiInstanceId`, `iterationIndex` | `terminalState` uses `FlowNodeInstanceState` enum values; `typeProperties` carries handler-specific metadata (e.g. DMN trace, hit policy, matched rules for BRTs); defaults to `%{}` for non-success states; `errorInfo` is a normalized `%{error_code, message, detail?}` map for fatal FNIs, `null` otherwise |
| `FlowNodeInstanceStateChanged` | `flowNodeInstanceId`, `processInstanceId`, `rootProcessInstanceId`, `flowNodeId`, `flowNodeType`, `eventType`, `laneName`, `oldState`, `newState`, `multiInstanceId`, `iterationIndex` | Emitted on non-terminal state transitions (currently `active` → `waiting`). Enables the Studio Debugger to track FNI state without polling. |
| `MultiInstanceStarted` | `flowNodeInstanceId`, `processInstanceId`, `rootProcessInstanceId`, `flowNodeId`, `flowNodeType`, `loopType`, `totalIterations`, `laneName`, `occurredAt` | Emitted when an MI or Standard Loop shell FNI begins execution. `loopType`: `"parallel_mi"`, `"sequential_mi"`, or `"standard_loop"`. `totalIterations` is the collection length for MI, `null` for Standard Loop. `laneName` is `null` for laneless shells (always delivered on WebSocket). |
| `MultiInstanceCompleted` | Same + `completedIterations`, `earlyBreak` | Emitted when an MI or Standard Loop shell FNI finishes. `earlyBreak` is `true` when the loop terminated before exhausting all iterations (e.g. `evil:loopBreakCondition` or `completionCondition`) |
| `UserTaskCreated` | `flowNodeInstanceId`, `processInstanceId`, `rootProcessInstanceId`, `flowNodeId`, `laneName` | Also broadcast to `user_tasks:pending`. `laneName` is `null` for laneless user tasks. |
| `UserTaskFinished` | Same + `outcome` | `outcome`: `completed` or `aborted`. Also broadcast to `user_tasks:pending` |
| `UserTaskValidationFailed` | Same + `violations` | `violations`: array of `{message, path}` |
| `PluginAsyncFlowNodeRehydrated` | `flowNodeInstanceId`, `processInstanceId`, `pluginName`, `laneName` | `pluginName` may be `null` |
| `CallActivityChildStarted` | `callActivityFlowNodeInstanceId`, `parentProcessInstanceId`, `childProcessInstanceId`, `childProcessModelId`, `childVersion`, `rootProcessInstanceId`, `laneName` | `childProcessModelId` is the child's BPMN process ID string; `childVersion` is the child's `evil:version` string. `laneName` is the Call Activity shell's lane. `rootProcessInstanceId` is the emitting parent PI's root (SP-13). |
| `SubProcessChildStarted` | `subprocessFlowNodeInstanceId`, `parentProcessInstanceId`, `childProcessInstanceId`, `subprocessNodeId`, `childProcessModelId`, `childVersion`, `isEventSubprocess`, `isAdHocSubprocess`, `rootProcessInstanceId`, `laneName`, `occurredAt` | Emitted when an Embedded SubProcess, Event Subprocess, or Ad-hoc SubProcess handler spawns a child PI. `subprocessNodeId` is the BPMN element ID of the `<bpmn:subProcess>` shell; `childProcessModelId` is the synthetic `parentProcessId__subprocess__subprocessNodeId` string. `isEventSubprocess` (mandatory, ESP-D16) is `true` when the child is an Event Subprocess spawn, `false` otherwise. `isAdHocSubprocess` is `true` when the child is an Ad-hoc SubProcess spawn, `false` otherwise. `rootProcessInstanceId` is the emitting parent PI's root (SP-13). Paired with `[:evil_engine, :subprocess, :child_started]` telemetry. |
| `EventSubprocessTriggered` | `scopeProcessInstanceId`, `rootProcessInstanceId`, `subprocessNodeId`, `childProcessInstanceId`, `triggerKind`, `isInterrupting`, `laneName`, `occurredAt` | Emitted by the scope PI when an Event Subprocess trigger fires and spawns an ESP child PI. `triggerKind` is one of `message`, `signal`, `timer`, `error`, `escalation`, `conditional`. `isInterrupting` reflects the ESP start event's `isInterrupting` attribute. The Studio debugger primarily consumes `SubProcessChildStarted` (with `isEventSubprocess`); this event additionally exposes the trigger kind |
| `DataObjectWritten` | `processInstanceId`, `rootProcessInstanceId`, `flowNodeInstanceId`, `dataObjectId`, `writeId`, `previousValue`, `value`, `createdAt`, `laneName` | Emitted after each successful DOA write. `previousValue` is computed from the in-memory cache (not stored in DB). `laneName` is the causing FNI's lane. |
| `TimerFired` | `timerRef`, `processInstanceId`, `flowNodeInstanceId`, `flowNodeId`, `kind`, `rootProcessInstanceId`, `laneName`, `occurredAt` | Emitted when a catch, boundary, or start timer fires. `laneName` is `null` when there is no FNI (cycle start-event fire). Cycle Timer Start fires leave `processInstanceId` and `rootProcessInstanceId` null. Scheduler telemetry `[:evil_engine, :timer, :armed|:fired|:cancelled]` covers arm/cancel; there are no typed `TimerArmed` / `TimerCancelled` events. |
| `ProcessDefinitionDeployed` | `processModelId`, `version`, `source` | Emitted per deployed version from `persist_deploy_batch/3` |
| `ProcessDefinitionUndeployed` | `processModelId`, `version`, `source` | `version` is `null` for bulk undeploy |
| `ProcessDefinitionEnabled` | `processModelId`, `source` | Emitted when a process is re-enabled via REST or plugin |
| `ProcessDefinitionDisabled` | `processModelId`, `source` | Emitted when a process is disabled via REST or plugin |
| `DecisionDefinitionDeployed` | `decisionDefinitionId`, `version`, `source` | `source` is `"user:<id>"` or `"plugin:<name>"` |
| `DecisionDefinitionUndeployed` | `decisionDefinitionId`, `version`, `source` | `version` is `null` for bulk undeploy |
| `DecisionEvaluated` | `decisionDefinitionId`, `decisionModelId`, `version`, `decisionVersionId`, `durationMicroseconds`, `source` | Ad-hoc evaluations only (REST + plugin facade); BRT evaluations are observable via `FlowNodeInstanceFinished.typeProperties` |
| `ProcessInstanceRetried` | `processInstanceId`, `targetProcessInstanceId`, `processModelId`, `version`, `previousState`, `previousVersion`, `newVersion`, `resetToFlowNodeInstanceId`, `retriedBy`, `startedById`, `hasLanelessFlowNode`, `laneNames` | `processInstanceId` is the root PI; `targetProcessInstanceId` is the user-targeted PI. `version`, `previousVersion`, `newVersion` are **process version UUIDs** (not `evil:version` strings). `previousVersion`/`newVersion` are `null` when no version migration. `resetToFlowNodeInstanceId` is `null` when no checkpoint. Visibility stamps match `ProcessInstanceStateChanged`. |
| `MessagePublished` | `messageId`, `messageName`, `correlationValue`, `origin`, `deliveries`, `startedProcessInstanceIds`, `pending`, `occurredAt` | Emitted after pipeline completes |
| `MessageArrived` | `messageId`, `messageName`, `correlationValue`, `processInstanceId`, `flowNodeInstanceId`, `rootProcessInstanceId`, `laneName`, `occurredAt` | Emitted when a message reaches a waiting subscription. `laneName` is copied from the catch-side subscription. `rootProcessInstanceId` is copied from the subscription (SP-13). |
| `SignalPublished` | `signalId`, `signalName`, `origin`, `deliveries`, `startedProcessInstanceIds`, `pending`, `occurredAt` | No payload, no correlation; true broadcast. Emitted after pipeline completes |
| `SignalArrived` | `signalId`, `signalName`, `processInstanceId`, `flowNodeInstanceId`, `rootProcessInstanceId`, `laneName`, `occurredAt` | No payload — signal identity and recipient only. `laneName` is copied from the catch-side subscription. `rootProcessInstanceId` is copied from the subscription (SP-13). |
| `EscalationRaised` | `escalationCode`, `escalationName`, `processInstanceId`, `rootProcessInstanceId`, `flowNodeInstanceId`, `flowNodeId`, `throwType`, `laneName`, `occurredAt` | Emitted on every escalation throw (both caught and uncaught) and on REST/plugin inject. `throwType`: `"end_event"`, `"intermediate_throw"`, or `"api_trigger"`. Broadcast to `process_instance:<piId>` and `process_instance:<rootPiId>`. `laneName` is the throw FNI's lane. |
| `CompensationTriggered` | `processInstanceId`, `rootProcessInstanceId`, `flowNodeInstanceId`, `flowNodeId`, `throwType`, `activityRef`, `targetCount`, `laneName`, `occurredAt` | Emitted before handler dispatch. `throwType`: `throw` or `end`. `activityRef` may be `null` (broadcast). `targetCount` is 0 if no completed activities have handlers. |
| `ActivityCompensated` | `processInstanceId`, `rootProcessInstanceId`, `compensatedFniId`, `handlerFniId`, `throwFniId`, `flowNodeId`, `handlerActivityId`, `laneName`, `occurredAt` | Emitted after each compensation handler finishes. `compensatedFniId` is the original completed FNI; `handlerFniId` is the handler FNI that ran. |
| `TransactionCancelled` | `processInstanceId`, `rootProcessInstanceId`, `transactionNodeId`, `compensationHandlerCount`, `laneName`, `occurredAt` | Emitted after all automatic LIFO compensation completes and the transaction child PI is about to transition to `:cancelled`. `compensationHandlerCount` is the number of compensation handlers that ran (0 if no completed compensable activities). Broadcast to both `process_instance:<processInstanceId>` and `process_instance:<rootProcessInstanceId>`. `laneName` is the transaction shell's lane. |
| `AdHocActivityActivated` | `processInstanceId`, `rootProcessInstanceId`, `adhocFlowNodeInstanceId`, `activatedFlowNodeInstanceId`, `activatedFlowNodeId`, `activationSource`, `laneName`, `occurredAt` | `activationSource`: `engine` or `api` or `plugin`. `laneName` is the activated activity's lane. |
| `AdHocSubProcessCompleted` | `processInstanceId`, `rootProcessInstanceId`, `adhocFlowNodeInstanceId`, `adhocNodeId`, `completionReason`, `totalActivations`, `laneName`, `occurredAt` | `completionReason`: `completed`, `fatal`, `error`, `aborted`, `crashed`, `escalation`, `unknown`. `laneName` is the ad-hoc shell's lane. |
| `SinkFailed` | `sinkName`, `eventType`, `error` | Does NOT reach WebSocket sink; only in-process EventSinks see it |

**`rootProcessInstanceId` and root PI WebSocket fan-out (SP-13):** Event types that carry `rootProcessInstanceId` include PI lifecycle, FNI lifecycle, user-task, data-object, compensation, multi-instance, `TimerFired`, `MessageArrived`, `SignalArrived`, `CallActivityChildStarted`, and `SubProcessChildStarted`. For root-level PIs, `rootProcessInstanceId` equals `processInstanceId`. For child PIs (Call Activity or Embedded SubProcess at any depth), it points to the top-level root PI. The WebSocket sink (`EvilEngineWeb.Ws.Sinks.WebSocket`) broadcasts events with a distinct root to both the primary PI topic (`process_instance:<processInstanceId>` or, for child-spawn events, `process_instance:<parentProcessInstanceId>`) and `process_instance:<rootProcessInstanceId>`, so a Studio debugger subscribed only to the root channel receives descendant FNI, user-task, data-object, compensation, timer, message/signal arrival, and nested spawn events. See [`docs/architecture/event-system.md`](docs/architecture/event-system.md) §Root Process Instance ID and WebSocket Fan-out.

**`EngineOverloaded` / `EngineRecovered` detail:** Emitted on load-threshold **crossings** (`normal` ↔ `elevated` ↔ `critical`), not on every poller tick. `EngineOverloaded` fires on upward transitions (normal→elevated, elevated→critical, normal→critical). `EngineRecovered` fires on downward transitions to normal (elevated→normal, critical→normal). Published via `EngineEventBus` only (no `:telemetry.execute/3` pairing). Detection lives in `EvilEngine.Telemetry.Measurements`.

### Error Diagnostics

Fatal flow node instances, PI-level failures, and REST error responses share a normalized `errorInfo` shape (camelCase on the wire ; string keys in Elixir persistence):

| Field | Type | Description |
|-------|------|-------------|
| `error_code` | string | Programmatic key for client-side branching (e.g. `"in_mapping_failed"`, `"no_handler_for_implementation"`) |
| `message` | string | Human-readable diagnostic sentence for display in the Studio debugger, logs, and API error bodies |
| `detail` | string, object, array, or `null` | Optional structured payload for programmatic inspection; opaque to wire camelCase conversion |

Example (WebSocket `FlowNodeInstanceFinished.errorInfo`):

```json
{
  "errorCode": "in_mapping_failed",
  "message": "Input mapping failed: FEEL expression 'token.x' could not be evaluated — unknown variable 'x'",
  "detail": {
    "expression": "token.x",
    "reason": "unknown variable 'x'"
  }
}
```

**Diagnostic quality requirement:** Every `message` must be a complete English sentence that names the specific element or construct that failed and explains why. Good messages include flow node IDs, BPMN element names, FEEL expression text, `implementation` values, DMN decision refs, contract violation summaries, or payload size figures. Generic fallbacks such as `"An unexpected error occurred"` or atom-to-words conversions (`"In mapping failed"`) are temporary placeholders — each must be replaced with a specific `humanize_error/1` clause in `apps/core_execution/lib/evil_engine/execution/process_instance/helpers.ex` as the error shape is identified.

**Implementation contract:**

- `Helpers.build_error_info/1` is the canonical entry point for constructing `errorInfo` maps; it delegates message text to `humanize_error/1`.
- New error shapes returned by handlers **must** add an explicit `humanize_error/1` clause — never rely on the catch-all fallback or on `sanitize_error_info/1` in `fni_lifecycle.ex` as the primary humanization path.
- REST controllers (e.g. `ProcessController`) format errors at the API boundary with the same diagnostic standard; never expose `inspect/1` output, `Exception.message/1`, or bare atom names in the `message` field.

See also `docs/architecture/common-pitfalls.md` (error messages must be diagnostic sentences).

### Planned Events (Phase 2)

These event names are reserved for future implementation:

- `MessagePending` / `MessageRematched` — pending-message observability events (publish/drain lifecycle is implemented; dedicated typed events not yet emitted)

---

## PI Retry / Restart (Runtime API)

Process Instance retry is a **runtime API feature**, not a BPMN modelling
concern. There are no `evil:*` extension elements related to retry — the
capability is exposed exclusively through:

- **REST:** `PUT /process-instances/{id}/retry` (body: optional `version`,
  optional `resetToFlowNodeInstanceId`)
- **Plugin facade:** `facade.process_instances.retry.(id, opts)`
- **Auth claim:** `retry_process_instance` (`none` | `own` | `all`)

Retry applies to terminal PIs (`fatal`, `aborted`, or `error`). It uses a 3-phase
mechanism: (1) targeted reset of the specified PI, (2) tree reset of
ancestors and descendants (for Call Activity trees), (3) resume from root
via the standard `ResumeRunner` codepath. Optional version migration and
checkpoint reset (`resetToFlowNodeInstanceId`) are supported.

**Compensation and retry/resume:** Compensation handler FNIs are ordinary FNIs — they are persisted as `:finished` and handled by the existing retry/reset machinery. The PI's `compensation_registry` is an in-memory data structure; on resume, `Resumption.rebuild_compensation_registry/1` re-derives it from persisted `:finished` FNIs by matching each FNI's flow node against the BPMN model's compensation boundary events.

**Retry checkpoint error codes** (HTTP 422):

| Error code | Message |
|------------|---------|
| `retry_checkpoint_is_join_gateway` | Cannot retry at a parallel join gateway. Retry at the fork gateway or at a node upstream of it. |
| `retry_checkpoint_is_mi_iteration` | Cannot retry at an MI/Loop iteration FNI. Retry at the shell activity or at a node upstream of it. |
| `retry_inside_adhoc_subprocess` | Cannot retry a PI that is a child of an ad-hoc subprocess scope |
| `retry_checkpoint_inside_adhoc_subprocess` | Cannot set a retry checkpoint to an FNI inside an ad-hoc subprocess scope |

For implementation details see
[`docs/architecture/execution.md`](docs/architecture/execution.md) §Retry
and [`docs/architecture/api.md`](docs/architecture/api.md) §`PUT /process-instances/:id/retry`.

---

## PI Abort (Tree-Wide Kill Switch)

Abort is a **tree-wide kill switch**. Aborting any PI in a process tree
(via REST `PUT /process-instances/{id}/abort` or plugin facade) aborts the
**entire** process tree — root, children, and grandchildren.

### Cascade directions

- **Downward:** When a PI aborts, `abort_all_fnis` invokes `handle_aborted/1`
  on each active/waiting FNI handler. Call Activity and SubProcess handlers
  cascade `ProcessInstance.abort` to their child PIs.
- **Upward:** When a child PI aborts, it sends `{:child_pi_aborted, self()}`
  to the handler Task via `notify_parent(data, :aborted)`. The handler Task
  returns `:abort_cascade`, and the parent PI handles this by aborting itself
  (including notifying *its* parent).

### Error Boundary Events do NOT catch aborts

Abort bypasses all error handling. The `:abort_cascade` result is handled
directly by the PI state machine — it never passes through
`BoundaryAwareHandler` or `BoundaryResolver`. This is intentional: abort
is the user's emergency stop, not a modeled business error.

### Distinction from fatal and error

| | Abort | Fatal | Error |
|---|---|---|---|
| Trigger | User/API kill switch | Engine crash | Error End Event (BPMN) |
| PI state | `:aborted` | `:fatal` | `:error` |
| FNI state | `:aborted` | `:fatal` | `:error` |
| Upward cascade | Yes (`:abort_cascade`) | No | Yes (`{:child_pi_bpmn_error, ...}`) |
| Boundary catchable | **No** | Yes (`CHILD_FATAL`) | Yes (error code match) |
| Retryable | Yes | Yes | Yes |

For implementation details see
[`docs/architecture/execution.md`](docs/architecture/execution.md) §Abort cascade.

### Process Instance terminal states

| PI state | Trigger | Retryable |
|----------|---------|-----------|
| `:finished` | All tokens consumed via End Events (normal completion) | No |
| `:compensated` | PI finished after a Compensation End Event — business outcome, not a failure | No |
| `:escalated` | PI finished after an uncaught escalation propagated to root — business outcome | No |
| `:cancelled` | Transaction subprocess PI cancelled via Cancel End Event — business outcome | No |
| `:error` | Error End Event (modeled BPMN error) — may be retried | Yes |
| `:fatal` | Engine crash / unhandled failure — may be retried | Yes |
| `:aborted` | User/API kill switch (tree-wide) — may be retried | Yes |

> `:compensated`, `:escalated`, and `:cancelled` are **terminal-but-handled** states. They represent intentional business outcomes, not failures. They are not retryable — there is nothing to fix. Only `:error`, `:fatal`, and `:aborted` indicate something went wrong and may be retried.

---

## EngineFacade (Plugin API Surface)

The `EvilEngine.EngineFacade` behaviour (in `apps/engine_sdk/lib/evil_engine/engine_facade.ex`) provides the runtime API available to plugins. It is the Elixir-side counterpart of the TypeScript `EngineFacade` interface in `@elraptorus/daemonengine_sdk`.

### Key corrections (2026-05-07 audit)

- `fail_async_service_task/3` takes three string arguments: `(flow_node_instance_id, reason, details)` — not a map for details
- Typed registration closures (`register_service_task_handler/2`, `register_named_script/2`, `register_rest_api_extension/2`, `register_auth_provider/1`) return `:ok`, `{:error, :conflict, incumbent_plugin_name}`, `{:error, :invalid_handler, message}`, or `{:error, :module_not_loaded, message}`. For in-BEAM plugins, the Registry validates at registration time that the handler module implements the expected `@behaviour` (e.g. `EvilEngine.Plugin.ServiceTaskHandler` for service task handlers, `EvilEngine.Plugin.AuthProvider` for auth providers). Auth provider is a singleton capability — first-writer wins, duplicate registration is rejected and the offending plugin is quarantined. Sidecar descriptors (string handler) skip the behaviour check. PersistenceAdapter, MonitoringPanel, TimerSource, and DataStoreAdapter plugin capabilities **do not exist** — do not register them.
- `register_event_sink/3` returns `{:ok, :registered}` or `{:error, :already_registered}` — duplicate sink names are rejected
- `get_config/1` retrieves engine configuration by key

### Signal facade

- `facade.signals.publish.(signal_name)` → `EvilEngine.Api.publish_signal/3` (with `skip_claims: true` for plugins)
  (no payload, no correlation; plugin identity injected into `origin`)
- Returns `{:ok, %{signal_id, signal_name, deliveries, started_process_instance_ids, pending}}`

### Escalation facade

- `facade.escalations.publish.(escalation_code)` → `EvilEngine.Api.trigger_escalation/3` (with `skip_claims: true` for plugins)
  (no payload; engine-wide waiter delivery to ESP starts and waiting Escalation Boundary FNIs)
- Returns `{:ok, %{escalation_code, deliveries, pending: false}}`

### Timer event manual trigger and schedules

- REST: `POST /timer-events/{flow_node_instance_id}/trigger` — manually fire a waiting timer FNI
- Client: `EventClient.triggerTimer(flowNodeInstanceId)` → `TimerTriggerResult` (`{ triggered: boolean }`)
- Api: `EvilEngine.Api.trigger_timer_event/3` — lane access + type/state validation, then `Execution.trigger_timer_event/2`
- No dedicated JWT trigger claim; gated by `lane:<name>` (same model as User Task finish)
- Facade: `facade.timers.trigger_event.(flow_node_instance_id)` plus schedule `list_schedules` / `get_schedule` / `enable_schedule` / `disable_schedule` (wired through `EvilEngine.Api`, skip_claims)

### Process catalog facade

- `facade.processes.list.()` → `EvilEngine.Api.list_processes/1`
- `facade.processes.undeploy.(process_model_id, version)` → `EvilEngine.Api.undeploy_process/3` (`skip_claims: true`)
- Also on the processes namespace: `get`, `deploy`, `enable`, `disable`, `delete_version`, `start`

### alignment

All external entry points converge through `EvilEngine.Api`. REST controllers are thin HTTP adapters — they call facade functions and map errors; claim and lane enforcement lives in the facade via `EvilEngine.Api.Validation`. Plugins call the same facade with `skip_claims: true`. A static enforcement test (`apps/api_web/test/architecture/d51_enforcement_test.exs`) scans all `api_web` lib files and fails if any direct `Ash.*` call is found.

---

## DMN Decision Engine (Phase 3–7)

The `core_dmn` umbrella app implements a DMN 1.5 CL3-conformant decision
engine. It parses DMN XML, validates structural constraints, precompiles
FEEL expressions, and evaluates decisions with full DRG chaining, boxed
expressions, and Decision Services.

### Supported DMN Element Types

#### Top-level definitions

| XML element | Internal type | Notes |
|-------------|---------------|-------|
| `<definitions>` | `Definitions` | Root container; holds `targetNamespace` |
| `<decision>` | `Decision` | Executable decision with value expression |
| `<businessKnowledgeModel>` | `BusinessKnowledgeModel` | Reusable logic via `FunctionDefinition` |
| `<knowledgeSource>` | `KnowledgeSource` | Non-executable, preserved for roundtrip |
| `<inputData>` | `InputData` | Named external input |
| `<itemDefinition>` | `ItemDefinition` | Type constraint (supports nesting, collections) |
| `<import>` | `Import` | Cross-model namespace reference |
| `<decisionService>` | `DecisionService` | `<outputDecision>`, `<encapsulatedDecision>`, `<inputDecision>`, `<inputData>` children with `href` attributes |

#### Decision children

Each `<decision>` carries exactly one value expression (stored as `expression` on `%Decision{}`), which must be one `Types.expression_body()` variant: `DecisionTable`, `LiteralExpression`, or any boxed expression type below.

| XML element | Purpose |
|-------------|---------|
| `<informationRequirement>` | Links to `<requiredDecision>` or `<requiredInput>` |
| `<knowledgeRequirement>` | Links to `<requiredKnowledge>` (BKM) |
| `<authorityRequirement>` | Governance link (authority, decision, input) |
| `<variable>` | Output `InformationItem` (name, typeRef) |

#### Boxed expressions (CL3)

| XML element | Internal type |
|-------------|---------------|
| `<context>` | `BoxedContext` |
| `<contextEntry>` | `ContextEntry` |
| `<invocation>` | `BoxedInvocation` |
| `<binding>` | `Binding` |
| `<list>` | `BoxedList` |
| `<relation>` | `Relation` |
| `<conditional>` | `BoxedConditional` |
| `<filter>` | `BoxedFilter` |
| `<for>` | `BoxedFor` |
| `<every>` | `BoxedEvery` |
| `<some>` | `BoxedSome` |
| `<functionDefinition>` | `FunctionDefinition` — also standalone on `<decision>` and `<contextEntry>` (not only inside BKM `<encapsulatedLogic>`) |

#### BKM children

| XML element | Purpose |
|-------------|---------|
| `<encapsulatedLogic>` | `FunctionDefinition` wrapper; `kind` attr (`:feel` only in CL1) |
| `<formalParameter>` | Named parameter with optional `typeRef` |
| `<variable>` | Output `InformationItem` |
| `<knowledgeRequirement>` | BKM-to-BKM chain |
| `<authorityRequirement>` | Governance link |

The body of `<encapsulatedLogic>` (`FunctionDefinition.body`) can be any
`expression_body()` type — same variants as a `<decision>` value expression.

#### ItemDefinition children

| XML element | Purpose |
|-------------|---------|
| `<typeRef>` | FEEL type name or reference to another ItemDefinition |
| `<allowedValues>` | Unary test constraint on values |
| `<itemComponent>` | Nested ItemDefinition for composite types |

#### Authority requirement children

| XML element | Maps to field |
|-------------|---------------|
| `<requiredAuthority>` | `required_authority_id` (→ KnowledgeSource) |
| `<requiredDecision>` | `required_decision_id` (→ Decision) |
| `<requiredInput>` | `required_input_id` (→ InputData) |

#### DMNDI (not parsed)

DMNDI elements (`<DMNDI>`, `<DMNDiagram>`, `<DMNShape>`, `<DMNEdge>`,
`<Bounds>`, `<waypoint>`) are **silently skipped** by the engine parser.
They have no relevance for evaluation — the engine does not render diagrams.
The raw XML (including DMNDI) is preserved verbatim in `%Definitions{raw_xml: ...}`
for retrieval via `GET /decisions/:id?includeXml=true`; the Studio's SDK
parser (`@elraptorus/daemonengine_sdk`) handles DMNDI extraction client-side.

### DMN Evaluation Pipeline

```
DMN XML → Parser → Validator → Precompiler → ModelCache
                                                  ↓
Input + decision_id → DependencyResolver (topo sort)
                    → Evaluator (chain: upstream → target)
                    → BkmInvoker (if knowledge requirements)
                    → TypeResolver (input coercion)
                    → ImportResolver (cross-model refs)
                    → %EvaluationResult{result, trace}
```

### DMN Error Codes (HTTP)

| Error code | HTTP status | Trigger |
|------------|-------------|---------|
| `dmn_cycle_error` | 422 | DRG or BKM cycle detected |
| `bkm_not_found` | 404 | Referenced BKM does not exist |
| `dmn_evaluation_error` | 422 | Catch-all for evaluation failures |
| `dmn_parse_error` | 400 | Invalid DMN XML |
| `validation_failed` | 422 | Structural validation errors |
| `decision_definition_not_found` | 404 | Unknown decision definition ID |
| `service_not_found` | 404 | Decision Service ID not found in deployed DMN model |
| `ambiguous_decision` | 422 | Multiple decisions, no `decisionModelId` specified |
| `input_value_violation` | 422 | Input value does not satisfy `inputValues` constraint |
| `missing_service_input` | 422 | Required `inputData` not provided for Decision Service |

### Phase 7 trace structs (observability)

Phase 7 extends `EvaluationTrace` and `EvaluationResult` with nested trace types for Studio debugger "step-into" navigation. Modules live under `EvilEngine.DMN.EvaluationTrace` in `apps/core_dmn/lib/evil_engine/dmn/evaluation_trace.ex`.

#### `BkmTrace`

Recursive struct recording a single BKM invocation. Emitted by `BkmInvoker` on every `knowledgeRequirement` resolution.

| Field | Type | Description |
|-------|------|-------------|
| `bkm_id` | string | Referenced BKM element ID |
| `bkm_name` | string \| null | BKM display name |
| `formal_parameters` | `[%{name, bound_value}]` | Formal parameter bindings at invocation time |
| `result` | term | BKM output value |
| `duration_microseconds` | integer | Wall-clock duration of this invocation |
| `dependent_bkm_traces` | `[BkmTrace]` | Nested traces for BKM-to-BKM chains |

Stored on each `DecisionTrace` as `bkm_traces`. REST responses camelCase to `bkmTraces` via `Wire.camelize_keys/1` on `EvaluationResult.to_json_map/1`.

#### `ImportTrace`

Wraps a full `EvaluationTrace` for the imported model so cross-model `<import>` references are navigable in the debugger.

| Field | Type | Description |
|-------|------|-------------|
| `namespace` | string | Import namespace prefix |
| `decision_id` | string | Decision ID evaluated in the imported model |
| `source_definitions_id` | string | `Definitions.id` of the imported DMN model |
| `evaluation_trace` | `EvaluationTrace` | Complete sub-DRG trace (all upstream decisions in dependency order) |
| `result` | term | Result value returned from the import |
| `duration_microseconds` | integer | Wall-clock duration of the import evaluation |

Stored on each `DecisionTrace` as `import_traces`. Multi-hop imports (A → B → C) produce nested import trace chains.

#### `CoercionTrace`

Records per-input type coercion performed by `TypeResolver` before evaluation. Includes inputs that required no transformation (`coerced: false`) so the debugger can show "not coerced" explicitly.

| Field | Type | Description |
|-------|------|-------------|
| `input_name` | string | Input variable name |
| `original_value` | term | Value before coercion |
| `coerced_value` | term | Value after coercion (same as original when `coerced` is false) |
| `target_type` | string | FEEL type name from `typeRef` / ItemDefinition |
| `coerced` | boolean | Whether a transformation was applied |

Stored at the root `EvaluationTrace` level as `input_coercions`.

#### `EvaluationResult` enrichment fields

`EvaluationResult` carries three optional metadata fields populated by the evaluator and REST/BRT callers:

| Field | Description |
|-------|-------------|
| `definitions_id` | `Definitions.id` from the parsed DMN model |
| `definitions_namespace` | `Definitions.namespace` (target namespace URI) |
| `decision_version_id` | Deployed decision version ID (from BusinessRuleTask runtime or REST evaluate caller) |

---

## Timer Events

Timer events use a two-layer architecture: `core_timers` provides the
metadata-opaque scheduling infrastructure, while `core_execution`
handlers translate BPMN semantics into Scheduler registrations.

### Timer Event Types on BPMN Elements

| Position | timeCycle | timeDate | timeDuration |
|----------|-----------|----------|--------------|
| StartEvent | Auto-scheduled by `StartEventManager`. Scheduler fires → `TimerStartListener` creates PI. | PI-scoped blocking gate. Blocks Start FNI until configured datetime. | PI-scoped delay. Blocks Start FNI for configured duration. |
| IntermediateCatchEvent | **Not supported** (rejected by handler). | Blocks FNI until datetime. Past date = immediate complete. | Blocks FNI for duration. |
| BoundaryEvent (interrupting) | Fires once (first cycle iteration), interrupts host, siblings cancelled. | Fires at datetime, interrupts host. Past date = immediate fire. | Fires after duration, interrupts host. |
| BoundaryEvent (non-interrupting) | Loops: each fire spawns a parallel branch via `{:boundary_cycle_fire, ...}`. Final fire finishes the boundary FNI. | Fires at datetime, spawns parallel branch. Host continues. | Fires after duration, spawns parallel branch. Host continues. |

### Boundary Event Trigger Models

Boundary events use two distinct trigger models:

1. **Error boundaries** (resolved at `handle_enter` time): Wrapped by
   `BoundaryAwareHandler`, which intercepts `{:error, reason}` from
   activity handlers and checks for matching error boundary definitions
   via `BoundaryResolver`.

2. **Subscription boundaries** (timer, message, signal): The boundary
   handler Task runs alongside the host activity. It subscribes to an
   external source (Scheduler for timers) and returns
   `{:boundary, node_id, payload, cancel_activity}` when triggered.

### Timer Cleanup Guarantees

Timers cannot outlive their Flow Node Instance:
- **Interrupting boundary fires**: Host FNI interrupted, sibling boundary FNIs interrupted (handler Tasks killed, timers cancelled).
- **Host activity completes**: `cancel_boundary_fnis_for_host` interrupts all boundary FNIs and kills their Tasks. Scheduler's PID monitor auto-cancels timers for dead PIDs.
- **PI fatals/aborts**: `handle_fni_fatal` / `handle_fni_aborted` call handler callbacks (`handle_fatal/1`, `handle_aborted/1`) which explicitly cancel timers via `Scheduler.cancel/1` or `Scheduler.cancel_all_for_target/1`.

### Scheduler Architecture

The Scheduler uses two ETS tables:
- **Primary** (`:ordered_set`): `{{fire_at_unix_ms, timer_ref}, target, metadata, cycle_info}` — ordered by fire time.
- **Target index** (`:bag`): `{target_key, timer_ref, fire_at_unix_ms}` — enables efficient `cancel_all_for_target/1`.

PID targets are monitored; on `:DOWN`, all timers for that PID are auto-cancelled.

For architecture details see [`docs/architecture/timers.md`](docs/architecture/timers.md).

---

## Terminate End Event

A Terminate End Event behaves like a normal End Event (passes through its
input token, stores `end_event_id` / `end_event_name` in
`type_properties`) but additionally instructs the Process Instance to
**interrupt all remaining active/waiting Flow Node Instances** within the
same process scope.

### Handler return shape

`FlowNodes.TerminateEndEvent.handle_enter/3` returns
`{:terminate, %FlowNodeResult{}}` — a dedicated tuple tag that the
Process Instance recognises in its `:running` state machine. This keeps
the termination semantics in the handler's return value rather than
embedding BPMN element awareness into the PI.

### PI reaction

1. The PI finishes the terminate FNI normally (same path as `{:ok, ...}`
   — persist, emit `FlowNodeInstanceFinished`, build `FinalToken`).
2. `interrupt_remaining_fnis/2` iterates all other `active`/`waiting`
   FNIs:
   - Kills the FNI process (`Process.exit(pid, :kill)`)
   - Calls `handle_aborted/1` on the handler for resource cleanup (timer
     cancellation, child PI abort, etc.)
   - Persists the FNI as `:interrupted` with reason
     `:terminated_by_end_event`
   - Emits `FlowNodeInstanceFinished` with `terminal_state: :interrupted`
3. `maybe_finish_or_continue` sees `active_count == 0` and finishes the
   PI as `:finished`. The terminate end event's token is included in
   `build_final_tokens/1`.

### State choice

Interrupted FNIs use state `:interrupted` (not `:aborted`). `:aborted` is
reserved for manual API cancellation. `:interrupted` is already used by
Interrupting Boundary Events — Terminate End Event reuses it with a
distinct reason atom.

For architecture details see [`docs/architecture/execution.md`](docs/architecture/execution.md).

---

## Error End Event

An Error End Event behaves like a Terminate End Event (interrupts all
remaining active/waiting sibling FNIs in the same process scope) but
additionally transitions the PI to `:error` state and notifies the
parent process with structured error information for boundary matching.

### Handler return shape

`FlowNodes.ErrorEndEvent.handle_enter/3` returns
`{:bpmn_error, error_info, %FlowNodeResult{}}` — a dedicated tuple tag
that the Process Instance recognises in its `:running` state machine.

The `error_info` map contains `error_code` and `error_message`, resolved
with the following priority:
1. Inline `evil:errorCode` on the `<errorEventDefinition>` (highest)
2. Global `<bpmn:error errorCode="...">` referenced via `errorRef`
3. `nil` (catch-all compatible — any boundary without a filter matches)

### FNI state

The Error End Event FNI is persisted in `:error` state via
`FniLifecycle.finish_as_error/4` (not `:finished`). This provides
clear visual distinction in the debugger:

| FNI | State | Visual meaning |
|-----|-------|----------------|
| Error End Event | `:error` | "This element threw the error" |
| Active/waiting siblings | `:error` | "Collateral — stopped by the error" |
| Previously completed FNIs | `:finished` | "Completed before the error occurred" |

### PI reaction

1. The PI calls `record_fni_error/3` to update the in-memory FNI state
   and emit `FlowNodeInstanceFinished` with `terminal_state: :error`
2. `error_all_remaining_fnis/2` transitions all other active/waiting FNIs
   to `:error` state (with `error_code: "process_error"`), symmetric
   with `fatal_all_fnis` for fatal and `abort_all_fnis` for abort
3. `maybe_finish/1` sees `bpmn_error_info != nil` → transitions PI to
   `:error` state and persists via `persist_pi_error/2`
4. `notify_parent/2` sends `{:child_pi_bpmn_error, pid, error_info,
   final_tokens}` to the parent (if any)

### Error propagation to parent

When a child PI (via Call Activity) throws a BPMN error:
- The Call Activity handler receives `{:child_pi_bpmn_error, ...}` in
  `await_child_completion/3` and routes through
  `BoundaryResolver.find_matching_error_boundary/4`
- **Match found** → `{:boundary, boundary_node_id, error_info,
  cancel_activity}` — parent catches the error and follows the boundary
  path
- **No match** → `{:error, error_info}` — parent PI fatals (uncaught
  BPMN error is a fatal condition in the parent)

### Standalone process behavior

In a top-level process (no parent), the PI transitions to `:error`
state. `notify_parent` is a no-op. The PI is observable via REST/GraphQL
in state `"error"`. This is the correct BPMN semantic: an uncaught
error in a top-level process is an error outcome, not a crash.

### Distinction from `{:error, reason}`

`{:bpmn_error, error_info, result}` represents a **modeled BPMN outcome**
(the diagram author intentionally placed an Error End Event).
`{:error, reason}` represents an **engine failure** (handler crash,
persistence failure, unsupported element). The two must not be confused:

| | `{:bpmn_error, ...}` | `{:error, ...}` |
|---|---|---|
| Triggering FNI state | `:error` | `:fatal` |
| Collateral FNI state | `:error` | `:fatal` |
| PI state | `:error` | `:fatal` |
| Parent notification | `{:child_pi_bpmn_error, ...}` | Child PI fatal |
| Boundary matching | Yes (error_code match) | Yes (CHILD_FATAL) |
| Retryable | Yes (all `:error` FNIs reset) | Yes (all `:fatal` FNIs reset) |
| Semantics | Modeled business error | Engine failure |

For architecture details see [`docs/architecture/execution.md`](docs/architecture/execution.md).

---

## Transaction Subprocess + Cancel Events

A `<bpmn:transaction>` is parsed and executed as a subprocess variant with
`is_transaction: true` on `FlowNodeData.SubProcess`. The `TransactionSubProcess`
handler (routed via `SubProcess.handle_enter`) extends the standard embedded
subprocess lifecycle with cancel-awareness.

### Three Transaction Outcomes

| Outcome | Trigger | Child PI state | Parent action |
|---------|---------|----------------|---------------|
| **Success** | All paths reach End Events normally | `:finished` | Token flows via outgoing sequence flow (same as embedded subprocess) |
| **Cancel** | Cancel End Event fires → LIFO compensation → Cancel Boundary fires | `:cancelled` | Parent continues via Cancel Boundary outgoing flow |
| **Hazard** | Uncaught error/fault propagates out | `:fatal` | Same as embedded subprocess fatal — error boundary or parent fatal |

**Compensation is NOT triggered on a Hazard.** Only a Cancel End Event triggers
automatic LIFO compensation. This is spec-correct (BPMN 2.0 §13.4.6). If
compensation is desired on error, model an Error Boundary inside the transaction
routing to a Compensate Throw, then a Cancel End.

### Cancel Sequence (handle_fni_cancel)

1. Cancel End FNI finishes normally
2. All remaining active/waiting FNIs in the child scope interrupted (`:cancelled_by_cancel_end`)
3. LIFO compensation runs for all completed compensable activities in the child PI's `compensation_registry`
4. Child PI transitions to `:cancelled` and notifies the parent Transaction handler
5. Transaction handler matches Cancel Boundary via `BoundaryResolver.find_matching_cancel_boundary/2`
6. If found: returns `{:boundary, cancel_boundary_node_id, token, true}` — parent continues
7. If not found: returns `{:error, :unhandled_cancel}` — parent fatals (hazard)

### Design Decisions (TX-D1 through TX-D9)

| ID | Decision |
|----|----------|
| TX-D1 | `bpmn:transaction` maps to `:sub_process` with `is_transaction: true`. Reuses 95% of embedded subprocess infrastructure. |
| TX-D2 | New PI terminal state `:cancelled`. Distinct from `:aborted` (API kill) and `:compensated` (explicit compensation). |
| TX-D3 | Cancel End fires automatic LIFO compensation within the child PI before transitioning to `:cancelled`. |
| TX-D4 | Cancel Boundary is reactive (Error-model), not subscription-based. Matched via `BoundaryResolver.find_matching_cancel_boundary/2`. |
| TX-D5 | No nested transactions in v1. Deploy-time validator rejects `bpmn:transaction` inside another `bpmn:transaction`. |
| TX-D6 | `method` attribute parsed and stored as `transaction_method` but not executed (no wire-level protocol integration). |
| TX-D7 | Hazard (uncaught error) does NOT trigger compensation. Error propagates to parent same as any subprocess fatal. |
| TX-D8 | Retry restrictions: (a) checkpoint must not point inside a transaction scope; (b) no PI below a transaction ancestor may be retried independently. Error codes: `retry_checkpoint_inside_transaction`, `retry_inside_transaction_scope`. |
| TX-D9 | `:cancelled` is NOT retryable — it is a handled business outcome, not a failure. |

### Events

| Event | Key fields | Notes |
|-------|-----------|-------|
| `TransactionCancelled` | `process_instance_id`, `root_process_instance_id`, `transaction_node_id`, `compensation_handler_count`, `occurred_at` | Emitted after all compensation completes and child PI is `:cancelled` |
| `ProcessInstanceStateChanged` (`:cancelled`) | Standard fields | Emitted when child PI transitions to `:cancelled` |

`TransactionCancelled` is broadcast to both `process_instance:<child_pi_id>` and
`process_instance:<root_pi_id>` channels via the standard root-PI fan-out (SP-13).

### Retry Restrictions

- Retrying a PI in `:cancelled` state → `process_instance_not_retriable`
- `resetToFlowNodeInstanceId` pointing inside a transaction's child scope → `retry_checkpoint_inside_transaction`
- Retrying any PI that has a transaction ancestor in the process tree (TX → SP → CA: any level) → `retry_inside_transaction_scope`. Walk is done via `parent_process_instance_id` chain.

For architecture details see [`docs/architecture/execution.md`](docs/architecture/execution.md) §Transaction Subprocess.

---

## Project Structure

ThomasTheDaemonEngine is an Elixir umbrella project following DDD domain
boundaries with a strict dependency direction.

### Dependency rule

```
Core  <--  Peripheral  <--  API
```

Core never imports from Peripheral or API. Peripheral never imports from
API. Violations of this rule break the architecture.

### Umbrella apps

| App | Domain | Purpose |
|-----|--------|---------|
| `core_types` | Core | Behaviour-free structs, shared types |
| `core_execution` | Core | PI/FNI runtime, resume, payload cap |
| `core_events` | Core | EngineEventBus, pending sweeper |
| `core_timers` | Core | Metadata-opaque timer service: Scheduler (ETS + tick + PID monitor), ISO 8601 parser, StartEventManager (cycle schedule lifecycle + persistence) |
| `core_expressions` | Core | FEEL evaluator (Rust NIF) |
| `core_bpmn` | Core | XML parser, ModelCache, validator, linter gate |
| `core_dmn` | Core | DMN parser, evaluator, DRG chaining, BKM invocation, boxed expressions, Decision Services, type system |
| `peripheral_persistence` | Peripheral | Ash + AshPostgres, dual-pool (Repo + ReadRepo). Mix `evil.retention.purge` for opt-in PI-tree hard-delete (RET-D1) |
| `peripheral_telemetry` | Peripheral | :telemetry counters, `/stats`, optional `GET /metrics` (Prometheus) |
| `peripheral_plugins` | Peripheral | Plugin registry, in-BEAM loader |
| `api_auth` | API | JWT validation (HS256 + RS256/ES256 + JWKS) |
| `api_facade` | API | `EvilEngine.Api` service-layer facade (no Phoenix dep) |
| `api_web` | API | REST + GraphQL + WebSocket + Admin (merged from api_http/api_graphql/api_websocket/api_admin) |

### TypeScript packages (`packages/js/`)

The engine ships two npm packages in a pnpm monorepo under `packages/js/`:

| Package | npm name | Purpose |
|---------|----------|---------|
| `packages/js/sdk/` | `@elraptorus/daemonengine_sdk` | Type definitions, error classes, event types, BPMN XML parser. Contract layer -- no network code. |
| `packages/js/client/` | `@elraptorus/daemonengine_client` | REST, GraphQL, and WebSocket client. Consumes types from the SDK. |

**Dependency direction:** `client` depends on `sdk` (`workspace:*`). The SDK never imports from the client.

**Key architectural boundaries:**
- All type contracts (resources, events, errors, plugin interfaces, GraphQL query options) live in the **SDK**
- The client contains only transport logic (HTTP, WS) and error mapping
- Error mapping in `client/src/errors/error-mapper.ts` translates engine JSON responses to typed SDK error subclasses
- The `phoenix` npm package is a runtime dependency of the client (for WebSocket channels)
- Test-only JWT minting (`jose` devDependency) lives in `client/test/support/` and is excluded from npm via `"files": ["dist"]` and `.npmignore`

**Integration tests** are in `client/test/integration/` and require a live engine with auth enabled. BPMN fixtures are in `client/test/integration/fixtures/`.

### Example directories

| Directory | Contents |
|-----------|----------|
| `examples/plugins/auth_providers/` | LDAP, CompanyGraph auth provider examples |
| `examples/plugins/service_task_handlers/` | Async service task handler examples (echo, HTTP, webhook, RabbitMQ stub, python_script, node_script) |
| `examples/plugins/event_sinks/` | DataDog, webhook, structured logger, SSE sink examples |
| `examples/plugins/named_scripts/` | Custom validators, local script runner |
| `examples/plugins/lifecycle_and_api/` | Lifecycle-aware, API consumer, GitHub BPMN auto-deployer, quarantine_demo |
| `examples/plugins/rest_api_extension/` | Echo RestApiExtension (`GET /echo-ext/ping`) |
| `examples/plugins/adhoc/` | AI toolbox EventSink for plugin-managed ad-hoc subprocesses |
| `examples/plugins/combined/` | RabbitMQ orchestrator, metrics pipeline, incident reporter |
| `examples/plugins/business_rules/` | DMN observation & analysis examples: explain decision, trace publisher, smoke tester, regression tester, DRD chain orchestrator, boxed expression showcase, decision analytics, decision audit reporter |
| `examples/client-js/` | TypeScript client examples (deploy, lifecycle, user tasks, GraphQL, errors, WebSocket, batch, DMN, BRT trace) |
| `examples/sdk-js/` | TypeScript SDK examples (parse BPMN/DMN, typed payloads, error hierarchy) |

For full project context including key invariants, documentation map, and
Ash conventions, see `.cursor/rules/project-context.mdc`.

---

## BPMN Diagram Interchange (DI) — Mandatory

Every `.bpmn` file in this repository **must** include a
`<bpmndi:BPMNDiagram>` section with coordinates for all shapes and edges.
A BPMN file without DI is invisible in the Studio and in any standards-
compliant modeler (bpmn.io, Camunda, etc.).

### Required namespace declarations

The `<bpmn:definitions>` root element must declare the DI, DC, and DI
namespaces in addition to the BPMN model namespace:

```xml
<bpmn:definitions
  xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL"
  xmlns:bpmndi="http://www.omg.org/spec/BPMN/20100524/DI"
  xmlns:dc="http://www.omg.org/spec/DD/20100524/DC"
  xmlns:di="http://www.omg.org/spec/DD/20100524/DI"
  xmlns:evil="https://evilengine.dev/schema/bpmn"
  targetNamespace="https://evilengine.dev/schema/bpmn"
  id="Definitions_1">
```

### Structure

After the `</bpmn:process>` closing tag(s) and before `</bpmn:definitions>`,
add one `<bpmndi:BPMNDiagram>` per process:

```xml
<bpmndi:BPMNDiagram id="BPMNDiagram_1">
  <bpmndi:BPMNPlane id="BPMNPlane_1" bpmnElement="process-id">
    <!-- One BPMNShape per flow node, data object reference, and lane -->
    <bpmndi:BPMNShape id="Shape_Start_1" bpmnElement="Start_1">
      <dc:Bounds x="162" y="182" width="36" height="36" />
    </bpmndi:BPMNShape>
    <!-- One BPMNEdge per sequence flow -->
    <bpmndi:BPMNEdge id="Edge_Flow_1" bpmnElement="Flow_1">
      <di:waypoint x="198" y="200" />
      <di:waypoint x="290" y="200" />
    </bpmndi:BPMNEdge>
  </bpmndi:BPMNPlane>
</bpmndi:BPMNDiagram>
```

### Standard element sizes (px)

| Element type | Width | Height |
|--------------|-------|--------|
| Start / End / Intermediate / Boundary events | 36 | 36 |
| Tasks (all types), Call Activities | 100 | 80 |
| Gateways (all types) | 50 | 50 |
| Data Object References | 36 | 50 |

### Layout conventions

- **Left-to-right flow.** Start events on the left, end events on the right.
- **Center-line baseline** at approximately `y = 200`.
- **Horizontal spacing** of ~160 px between layer centers.
- **Vertical spacing** of ~100 px between parallel branches.
- **Boundary events** positioned on the bottom border of their host activity.
- **Data object references** positioned below the main flow.
- **Lanes** wrap all contained elements with ~30 px padding.

### Auto-layout script

`scripts/bpmn_add_di.py` can retroactively add DI to files that lack it:

```bash
python3 scripts/bpmn_add_di.py path/to/file.bpmn   # single file
python3 scripts/bpmn_add_di.py .                     # entire repository
```

Files that already contain a `<bpmndi:BPMNDiagram>` element are skipped.

### Pool and Lane requirement

Every new BPMN diagram **must** contain at least one
`<bpmn:collaboration>` with a `<bpmn:participant>` (pool) and the process
must contain at least one `<bpmn:laneSet>` with a `<bpmn:lane>` named
`"default"`. This ensures interoperability with the Bifrost Forge World
Studio, which uses pools and lanes for layout, linting, and modeler
features. Pool-less diagrams are technically valid BPMN but cause
namespace-related serialization issues in the Studio's moddle layer.

Minimal pool + lane skeleton:

```xml
<bpmn:collaboration id="Collaboration_1">
  <bpmn:participant id="Participant_1" name="Default" processRef="your-process-id" />
</bpmn:collaboration>

<bpmn:process id="your-process-id" name="Your Process" isExecutable="true">
  <bpmn:laneSet id="LaneSet_1">
    <bpmn:lane id="Lane_default" name="default">
      <bpmn:flowNodeRef>Start_1</bpmn:flowNodeRef>
      <!-- ... all flow node refs ... -->
    </bpmn:lane>
  </bpmn:laneSet>
  <!-- flow nodes and sequence flows -->
</bpmn:process>
```

---

## Timer Event REST Endpoint

The `TimerEventController` (`apps/api_web/lib/evil_engine_web/http/controllers/timer_event_controller.ex`)
exposes manual timer trigger via REST. JWT authentication required.

| Method | Path | Purpose | Required Access |
|--------|------|---------|-----------------|
| `POST` | `/timer-events/{flow_node_instance_id}/trigger` | Manually fire a waiting timer FNI | `lane:<laneName>="write"` for the FNI's lane, or laneless FNI, or `zeeky_boogie_doog`. `"read"` / `observe_all` → 403; invisible → 404 |

Body: empty or `{}`. Response `200`: `TimerTriggerResult` — `{ "triggered": true }` (camelCase on wire). Errors: `404` (not found / lane-invisible), `403` (forbidden), `409` (FNI not active/waiting), `422` (`not_a_timer_event`).

TypeScript SDK type: `TimerTriggerResult` in `packages/js/sdk/src/types/trigger.ts` (union member of `TriggerResult` alongside `MessageTriggerResult` and `SignalTriggerResult`). Client method: `EventClient.triggerTimer(flowNodeInstanceId)` in `@elraptorus/daemonengine_client`.

Eligible FNIs: Intermediate Catch or Boundary events with `event_type: "timer"`. Delegates to `EvilEngine.Api.trigger_timer_event/3`.

---

## Escalation REST Endpoint

The `EscalationController` (`apps/api_web/lib/evil_engine_web/http/controllers/escalation_controller.ex`)
exposes engine-wide escalation inject via REST. JWT authentication required.

| Method | Path | Purpose | Required Access |
|--------|------|---------|-----------------|
| `POST` | `/escalations/{escalation_code}/trigger` | Inject a named escalation into waiting catchers | boolean `trigger_escalation`, or `zeeky_boogie_doog` |

Body: empty or `{}`. Response `200`: `EscalationTriggerResult` — `{ "escalationCode", "deliveries": [{ "processInstanceId", "flowNodeInstanceId" }], "pending": false }` (camelCase on wire). Empty `deliveries` is success. Errors: `403` (forbidden), `422` (`escalation_code_blank` / `escalation_code_too_long`). Not a modeled throw; no pending; unmatched PIs are not `:escalated`.

TypeScript SDK type: `EscalationTriggerResult` in `packages/js/sdk/src/types/trigger.ts` (union member of `TriggerResult`). Client method: `EventClient.triggerEscalation(escalationCode)` in `@elraptorus/daemonengine_client`.

Delegates to `EvilEngine.Api.trigger_escalation/3`.

---

## Ad-hoc Subprocess REST Endpoints

The `AdhocSubprocessController` (`apps/api_web/lib/evil_engine_web/http/controllers/adhoc_subprocess_controller.ex`)
exposes ad-hoc subprocess control via REST. JWT authentication required.

| Method | Path | Purpose | Required Claim |
|--------|------|---------|----------------|
| `GET` | `/adhoc-subprocesses/{id}/activities` | List enabled/performed inner activities | `manage_adhoc_subprocess` |
| `POST` | `/adhoc-subprocesses/{id}/activities/{activity_id}/activate` | Activate an inner activity | `manage_adhoc_subprocess` |
| `POST` | `/adhoc-subprocesses/{id}/complete` | Signal completion | `manage_adhoc_subprocess` |
| `GET` | `/adhoc-subprocesses/{id}/status` | Query runtime status | `manage_adhoc_subprocess` |

The `{id}` path parameter is the **child process instance ID** spawned by the ad-hoc subprocess handler — not the parent PI or the shell FNI ID.

**List activities** returns `{data: [{id, name, type, enabled, performedCount, activeCount}]}`.
**Activate** returns `{flowNodeInstanceId: "..."}`.
**Complete** returns `{completed: true}`.
**Status** returns `{activeCount, performedActivities, enabledActivities, completionSignaled}`.

Errors: `404` (PI not found or activity not found), `422` (`not_adhoc_subprocess`), `409` (`adhoc_already_completing`), `403` (forbidden), `500` (`dispatch_failed`).

The `zeeky_boogie_doog` admin override claim bypasses all ad-hoc authorization checks.

Plugin facade: `facade.adhoc_subprocesses.{get_enabled_activities, activate_activity, complete, get_status}` — same operations with `skip_claims: true`.

---

## DMN REST Endpoints

The `DecisionController` (`apps/api_web/lib/evil_engine_web/http/controllers/decision_controller.ex`)
exposes DMN operations via REST. All endpoints require JWT authentication.

| Method | Path | Purpose | Required Claim |
|--------|------|---------|----------------|
| `GET` | `/decisions` | List all deployed decisions | any authenticated |
| `GET` | `/decisions/{model_id}` | Show decision metadata (`?includeXml=true` optional) | any authenticated |
| `GET` | `/decisions/{model_id}/versions` | Version history (`?includeXml=true` optional) | any authenticated |
| `POST` | `/decisions` | Deploy DMN definitions (body: `{sources: ["<xml>"]}`) | `deploy_dmn` |
| `POST` | `/decisions/{model_id}/evaluate` | Ad-hoc evaluation (body: `{input, decisionModelId?, includeUnmatchedDetails?}`) | any authenticated |
| `POST` | `/decisions/{model_id}/versions/{version}/evaluate` | Evaluate a specific version (body: `{input, decisionModelId?, includeUnmatchedDetails?}`) | any authenticated |
| `POST` | `/decisions/{model_id}/services/{service_id}/evaluate` | Evaluate a Decision Service (body: `{input}`) | any authenticated |
| `PUT` | `/decisions/{model_id}/enable` | Enable definition (204) | `deploy_dmn` |
| `PUT` | `/decisions/{model_id}/disable` | Disable definition (204) | `deploy_dmn` |
| `DELETE` | `/decisions/{model_id}` | Undeploy all versions (204) | `delete_dmn` |
| `DELETE` | `/decisions/{model_id}/versions/{version}` | Soft-delete a version (204) | `delete_dmn` |

The `zeeky_boogie_doog` admin override claim bypasses all DMN authorization checks.

Plugins access the same operations through `facade.decisions.*`. The
namespace exposes: `list`, `get`, `get_latest_version`, `deploy`, `evaluate`,
`evaluate_by_version`, `evaluate_service`, `validate`, `get_versions`,
`get_xml`, `enable`, `disable`, `delete_version`, `undeploy`.

---

## Complete Example

A valid, minimal BPMN file exercising multiple `evil:*` extensions:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<bpmn:definitions
  xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL"
  xmlns:bpmndi="http://www.omg.org/spec/BPMN/20100524/DI"
  xmlns:dc="http://www.omg.org/spec/DD/20100524/DC"
  xmlns:di="http://www.omg.org/spec/DD/20100524/DI"
  xmlns:evil="https://evilengine.dev/schema/bpmn"
  targetNamespace="https://evilengine.dev/schema/bpmn"
  id="Definitions_1">

  <bpmn:message id="Message_payment" name="payment-received" />

  <bpmn:process id="order-process" name="Order Process" isExecutable="true">
    <bpmn:extensionElements>
      <evil:version>1.0.0</evil:version>
      <evil:correlationKey>token.orderId</evil:correlationKey>
    </bpmn:extensionElements>

    <bpmn:startEvent id="Start_1" name="Order received">
      <bpmn:outgoing>Flow_1</bpmn:outgoing>
    </bpmn:startEvent>

    <bpmn:userTask id="UserTask_1" name="Review Order">
      <bpmn:extensionElements>
        <evil:assignees>identity.groups</evil:assignees>
        <evil:formFields>{"fields":[{"name":"approved","type":"boolean"}]}</evil:formFields>
      </bpmn:extensionElements>
      <bpmn:incoming>Flow_1</bpmn:incoming>
      <bpmn:outgoing>Flow_2</bpmn:outgoing>
    </bpmn:userTask>

    <bpmn:exclusiveGateway id="Gateway_1" name="Approved?" default="Flow_rejected">
      <bpmn:incoming>Flow_2</bpmn:incoming>
      <bpmn:outgoing>Flow_approved</bpmn:outgoing>
      <bpmn:outgoing>Flow_rejected</bpmn:outgoing>
    </bpmn:exclusiveGateway>

    <bpmn:serviceTask id="ServiceTask_1" name="Charge Payment" implementation="http">
      <bpmn:extensionElements>
        <evil:resultContract>{"type":"object","required":["transactionId"]}</evil:resultContract>
      </bpmn:extensionElements>
      <bpmn:incoming>Flow_approved</bpmn:incoming>
      <bpmn:outgoing>Flow_3</bpmn:outgoing>
    </bpmn:serviceTask>

    <bpmn:intermediateCatchEvent id="Catch_payment" name="Wait for Payment">
      <bpmn:messageEventDefinition messageRef="Message_payment" />
      <bpmn:incoming>Flow_3</bpmn:incoming>
      <bpmn:outgoing>Flow_4</bpmn:outgoing>
    </bpmn:intermediateCatchEvent>

    <bpmn:endEvent id="End_success" name="Order Complete">
      <bpmn:messageEventDefinition messageRef="Message_payment">
        <bpmn:extensionElements>
          <evil:correlationRetrievalExpression>token.orderId</evil:correlationRetrievalExpression>
        </bpmn:extensionElements>
      </bpmn:messageEventDefinition>
      <bpmn:incoming>Flow_4</bpmn:incoming>
    </bpmn:endEvent>

    <bpmn:endEvent id="End_rejected" name="Order Rejected">
      <bpmn:incoming>Flow_rejected</bpmn:incoming>
    </bpmn:endEvent>

    <bpmn:sequenceFlow id="Flow_1" sourceRef="Start_1" targetRef="UserTask_1" />
    <bpmn:sequenceFlow id="Flow_2" sourceRef="UserTask_1" targetRef="Gateway_1" />
    <bpmn:sequenceFlow id="Flow_approved" sourceRef="Gateway_1" targetRef="ServiceTask_1">
      <bpmn:conditionExpression>token.approved = true</bpmn:conditionExpression>
    </bpmn:sequenceFlow>
    <bpmn:sequenceFlow id="Flow_rejected" sourceRef="Gateway_1" targetRef="End_rejected" />
    <bpmn:sequenceFlow id="Flow_3" sourceRef="ServiceTask_1" targetRef="Catch_payment" />
    <bpmn:sequenceFlow id="Flow_4" sourceRef="Catch_payment" targetRef="End_success" />

  </bpmn:process>

  <bpmndi:BPMNDiagram id="BPMNDiagram_1">
    <bpmndi:BPMNPlane id="BPMNPlane_1" bpmnElement="order-process">
      <bpmndi:BPMNShape id="Shape_Start_1" bpmnElement="Start_1">
        <dc:Bounds x="162" y="182" width="36" height="36" />
      </bpmndi:BPMNShape>
      <bpmndi:BPMNShape id="Shape_UserTask_1" bpmnElement="UserTask_1">
        <dc:Bounds x="290" y="160" width="100" height="80" />
      </bpmndi:BPMNShape>
      <bpmndi:BPMNShape id="Shape_Gateway_1" bpmnElement="Gateway_1">
        <dc:Bounds x="475" y="175" width="50" height="50" />
      </bpmndi:BPMNShape>
      <bpmndi:BPMNShape id="Shape_ServiceTask_1" bpmnElement="ServiceTask_1">
        <dc:Bounds x="610" y="110" width="100" height="80" />
      </bpmndi:BPMNShape>
      <bpmndi:BPMNShape id="Shape_Catch_payment" bpmnElement="Catch_payment">
        <dc:Bounds x="802" y="132" width="36" height="36" />
      </bpmndi:BPMNShape>
      <bpmndi:BPMNShape id="Shape_End_success" bpmnElement="End_success">
        <dc:Bounds x="962" y="132" width="36" height="36" />
      </bpmndi:BPMNShape>
      <bpmndi:BPMNShape id="Shape_End_rejected" bpmnElement="End_rejected">
        <dc:Bounds x="642" y="282" width="36" height="36" />
      </bpmndi:BPMNShape>
      <bpmndi:BPMNEdge id="Edge_Flow_1" bpmnElement="Flow_1">
        <di:waypoint x="198" y="200" />
        <di:waypoint x="290" y="200" />
      </bpmndi:BPMNEdge>
      <bpmndi:BPMNEdge id="Edge_Flow_2" bpmnElement="Flow_2">
        <di:waypoint x="390" y="200" />
        <di:waypoint x="475" y="200" />
      </bpmndi:BPMNEdge>
      <bpmndi:BPMNEdge id="Edge_Flow_approved" bpmnElement="Flow_approved">
        <di:waypoint x="525" y="200" />
        <di:waypoint x="567" y="200" />
        <di:waypoint x="567" y="150" />
        <di:waypoint x="610" y="150" />
      </bpmndi:BPMNEdge>
      <bpmndi:BPMNEdge id="Edge_Flow_rejected" bpmnElement="Flow_rejected">
        <di:waypoint x="525" y="200" />
        <di:waypoint x="583" y="200" />
        <di:waypoint x="583" y="300" />
        <di:waypoint x="642" y="300" />
      </bpmndi:BPMNEdge>
      <bpmndi:BPMNEdge id="Edge_Flow_3" bpmnElement="Flow_3">
        <di:waypoint x="710" y="150" />
        <di:waypoint x="802" y="150" />
      </bpmndi:BPMNEdge>
      <bpmndi:BPMNEdge id="Edge_Flow_4" bpmnElement="Flow_4">
        <di:waypoint x="838" y="150" />
        <di:waypoint x="962" y="150" />
      </bpmndi:BPMNEdge>
    </bpmndi:BPMNPlane>
  </bpmndi:BPMNDiagram>
</bpmn:definitions>
```

This example demonstrates:
- `evil:version` on the process (required)
- `evil:assignees` and `evil:formFields` on a UserTask
- `implementation` and `evil:resultContract` on a ServiceTask
- `evil:correlationKey` on the process (catch-side correlation)
- `evil:correlationRetrievalExpression` on a Message End Event (throw-side correlation stamp)
- Conditional expression on a SequenceFlow
- Default flow on an ExclusiveGateway
- Global message definition referenced by catch and end events
- Complete `<bpmndi:BPMNDiagram>` with shapes and edges (required)

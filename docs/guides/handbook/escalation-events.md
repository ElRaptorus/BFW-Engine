# Escalation Events

Escalation Events signal a business exception upward through the process hierarchy — from a child process to its parent, from the parent to its grandparent, and so on. Unlike Error Events (which represent technical or unrecoverable failures), escalation represents an expected business condition that a higher-level process is designed to handle.

> **Direction rule:** Escalation always travels **upward** through the process hierarchy. A parent can never push an escalation into a child, and a child cannot escalate to a sibling.

## Element Types

| Element | Position | Semantics |
|---|---|---|
| **Escalation End Event** | End | Ends the current process scope and signals escalation to the parent |
| **Escalation Intermediate Throw Event** | Intermediate | Signals escalation to the parent; the current process continues normally |
| **Escalation Boundary Event (interrupting)** | Boundary | Catches escalation from a child activity; interrupts the host when fired |
| **Escalation Boundary Event (non-interrupting)** | Boundary | Catches escalation from a child activity; spawns a parallel branch when fired, host continues |

## Global Escalation Definition

Every escalation event references a global `<bpmn:escalation>` definition that carries the escalation code. The code is used for targeted boundary matching:

```xml
<bpmn:escalation id="Esc_InvalidData" escalationCode="INVALID_DATA"
                 name="Invalid Data Escalation" />

<bpmn:escalation id="Esc_CreditLimit" escalationCode="CREDIT_LIMIT_EXCEEDED"
                 name="Credit Limit Escalation" />
```

An escalation without a code (or with `escalationCode=""`) acts as a **catch-all** and matches any incoming escalation regardless of its code.

## Escalation End Event

An Escalation End Event terminates the current process scope with escalation semantics. It behaves like a [Terminate End Event](error-handling.md) within its scope (interrupting remaining sibling FNIs), then signals the parent.

### Lifecycle

1. The Escalation End Event FNI fires
2. Remaining active/waiting sibling FNIs in the same scope are interrupted (state `:interrupted`)
3. The current child PI transitions to state `:escalated`
4. The escalation (with its code and message) is propagated to the parent process via the handler Task that is waiting on the child

### BPMN XML

```xml
<bpmn:escalation id="Esc_OOB" escalationCode="OUT_OF_BOUNDS" name="Out of Bounds" />

<bpmn:process id="child-process" isExecutable="true">
  <bpmn:extensionElements>
    <bfw:version>1.0.0</bfw:version>
  </bpmn:extensionElements>

  <bpmn:startEvent id="Start" />
  <bpmn:serviceTask id="Task_validate" name="Validate" implementation="validator" />
  <bpmn:endEvent id="End_escalate" name="Validation Failed">
    <bpmn:escalationEventDefinition escalationRef="Esc_OOB" />
  </bpmn:endEvent>

  <bpmn:sequenceFlow id="F1" sourceRef="Start" targetRef="Task_validate" />
  <bpmn:sequenceFlow id="F2" sourceRef="Task_validate" targetRef="End_escalate" />
</bpmn:process>
```

### Inline Extension Elements

The escalation code comes from the global `<bpmn:escalation escalationCode="…">` referenced by `escalationRef`. A missing or blank code is catch-all compatible. Do **not** put `bfw:errorCode` or `bfw:errorMessage` on an escalation event definition — those extensions exist only on `<errorEventDefinition>`.

## Escalation Intermediate Throw Event

An Escalation Intermediate Throw Event propagates an escalation to the parent without terminating the current process. Execution continues along the throw event's outgoing sequence flow as normal.

### Lifecycle

1. The Intermediate Throw FNI fires
2. The escalation is propagated to the parent (via Call Activity or Embedded Subprocess handler Task)
3. The current PI continues — the throw FNI finishes with state `:finished`, and the next flow node is dispatched normally
4. The parent processes the escalation (matching boundary or propagating further upward)

This is the key difference from the Escalation End Event: the current process **does not stop**. Both the parent's boundary handling and the child's continued execution proceed concurrently.

### BPMN XML

```xml
<bpmn:intermediateThrowEvent id="Throw_notify" name="Notify Parent">
  <bpmn:escalationEventDefinition escalationRef="Esc_OOB" />
  <bpmn:incoming>Flow_before_notify</bpmn:incoming>
  <bpmn:outgoing>Flow_after_notify</bpmn:outgoing>
</bpmn:intermediateThrowEvent>
```

## Escalation Boundary Events

Escalation Boundary Events are attached to a Call Activity or Embedded Subprocess shell. They wait for the child PI to signal an escalation, then react.

### Interrupting Boundary (`cancelActivity="true"`)

When the child signals escalation:

1. The matching interrupting boundary FNI fires
2. The host activity (Call Activity or Embedded Subprocess) is interrupted
3. Other sibling boundary FNIs on the same host are cancelled
4. Execution follows the boundary event's outgoing sequence flow
5. The child PI is left in `:escalated` state (if from an Escalation End Event) or `:finished` (if from an Intermediate Throw that has already continued)

### Non-Interrupting Boundary (`cancelActivity="false"`)

When the child signals escalation:

1. The matching non-interrupting boundary FNI fires
2. A parallel branch is spawned from the boundary's outgoing sequence flow
3. The host activity (Call Activity or Embedded Subprocess) **continues running**
4. The child PI continues (if the escalation came from an Intermediate Throw) or is already in `:escalated` state (if from an Escalation End Event)

> **Key distinction:** A non-interrupting escalation boundary fires and continues. If the child throws another escalation (e.g. via a second Intermediate Throw Event), the boundary fires again and spawns another parallel branch.

### BPMN XML

```xml
<!-- Interrupting escalation boundary on a Call Activity -->
<bpmn:callActivity id="Call_child" name="Run Child Process"
                   calledElement="child-process">
  <bpmn:incoming>Flow_In</bpmn:incoming>
  <bpmn:outgoing>Flow_normal</bpmn:outgoing>
</bpmn:callActivity>

<bpmn:boundaryEvent id="Boundary_esc" attachedToRef="Call_child"
                    cancelActivity="true">
  <bpmn:escalationEventDefinition escalationRef="Esc_OOB" />
  <bpmn:outgoing>Flow_esc_caught</bpmn:outgoing>
</bpmn:boundaryEvent>

<bpmn:sequenceFlow id="Flow_esc_caught" sourceRef="Boundary_esc"
                   targetRef="Task_handle_escalation" />
```

### Catch-All Boundary

An Escalation Boundary without a code (omitting `escalationRef`, or referencing an escalation with a blank `escalationCode`) catches **any** escalation regardless of its code:

```xml
<bpmn:boundaryEvent id="Boundary_catchall" attachedToRef="Call_child"
                    cancelActivity="false">
  <bpmn:escalationEventDefinition />  <!-- no escalationRef = catch-all -->
  <bpmn:outgoing>Flow_any_esc</bpmn:outgoing>
</bpmn:boundaryEvent>
```

## Escalation Code Matching

When a child signals an escalation with a specific code, the engine searches the parent's boundary events using the following precedence rules:

| Priority | Rule |
|---|---|
| **Highest** | Specific code match — boundary's `escalationCode` equals the incoming code |
| **Lowest** | Catch-all — boundary has no `escalationCode` (or blank) |

Specific-code boundaries beat catch-all boundaries regardless of the order they are declared in the BPMN XML. This means you can safely add a catch-all boundary alongside specific ones without worrying about declaration order.

Multiple **non-interrupting** boundaries can all fire for a single escalation if they all have codes that match (or are catch-alls). Multiple **interrupting** boundaries cannot — only one interrupting boundary fires (the first match wins and cancels the host, preventing further fires).

## Propagation Chain

If the parent has no matching escalation boundary, the escalation propagates further upward:

```
Child PI → Parent PI (no matching boundary) → Grandparent PI → ...
```

The propagation stops when:

1. **A matching boundary is found**: the boundary fires and the escalation is considered caught
2. **The top-level PI is reached**: the PI transitions to `:escalated` state (uncaught — see below)

### Uncaught Escalation End Event

If an Escalation End Event propagates all the way to a top-level process with no matching boundary:

- The top-level PI transitions to state **`:escalated`** (a terminal, non-retryable state)
- All sibling FNIs in the top-level PI are interrupted
- The engine emits an `EscalationRaised` event on the EngineEventBus

### Uncaught Escalation Intermediate Throw Event

If an Escalation Intermediate Throw Event propagates to a top-level process with no matching boundary:

- The current PI **continues normally** — no PI state transition occurs
- The escalation is silently absorbed at the root level
- The engine emits an `EscalationRaised` event
- The PI that threw the escalation continues along its outgoing sequence flow

## Engine Events

| Event | Published When |
|---|---|
| `EscalationRaised` | Every modeled throw (caught or uncaught) and REST/plugin inject (`throwType: "api_trigger"`) |

`EscalationRaised` fields: `escalationCode`, `escalationName`, `processInstanceId`, `rootProcessInstanceId`, `flowNodeInstanceId`, `flowNodeId`, `throwType` (`end_event` / `intermediate_throw` / `api_trigger`), `laneName`, `occurredAt`. Broadcast to `process_instance:<piId>` and the root PI channel.

Telemetry events:
- `[:bfw_engine, :escalation, :raised]` — fired on every escalation
- `[:bfw_engine, :escalation, :uncaught]` — fired when no boundary matched at the root

## Process Instance States

| State | Meaning |
|---|---|
| `:escalated` | A top-level PI reached by an uncaught Escalation End Event. Terminal, not retryable. |
| `:finished` | A PI that ran an Escalation Intermediate Throw but then completed normally. |

`:escalated` is distinct from `:error` (BPMN Error End Event) and `:fatal` (engine/technical failure). Escalation is a modeled business condition; error is an unrecoverable condition; fatal is an engine-level failure.

## Common Patterns

### Parent catches child escalation and retries with different parameters

```xml
<!-- Non-interrupting boundary: handle escalation without stopping the child -->
<bpmn:boundaryEvent id="Boundary_retry" attachedToRef="Call_child"
                    cancelActivity="false">
  <bpmn:escalationEventDefinition escalationRef="Esc_RetryNeeded" />
  <bpmn:outgoing>Flow_to_retry_handler</bpmn:outgoing>
</bpmn:boundaryEvent>
```

### Subprocess signals progress to parent and continues

Use an Escalation Intermediate Throw inside an Embedded Subprocess or Call Activity to notify the parent of intermediate progress without terminating the child process:

```xml
<!-- Inside the child process -->
<bpmn:intermediateThrowEvent id="Throw_progress" name="Progress notification">
  <bpmn:escalationEventDefinition escalationRef="Esc_Progress" />
  <bpmn:incoming>Flow_before</bpmn:incoming>
  <bpmn:outgoing>Flow_after</bpmn:outgoing>
</bpmn:intermediateThrowEvent>
```

The parent's non-interrupting boundary fires each time this throw is reached, accumulating progress notifications while the child continues.

### Multiple escalation codes with a fallback

```xml
<!-- Specific handler for CREDIT_LIMIT_EXCEEDED -->
<bpmn:boundaryEvent id="Boundary_credit" attachedToRef="Call_child">
  <bpmn:escalationEventDefinition escalationRef="Esc_CreditLimit" />
  ...
</bpmn:boundaryEvent>

<!-- Catch-all for any other escalation -->
<bpmn:boundaryEvent id="Boundary_any" attachedToRef="Call_child">
  <bpmn:escalationEventDefinition />
  ...
</bpmn:boundaryEvent>
```

The engine always evaluates specific-code matches before catch-all, so `CREDIT_LIMIT_EXCEEDED` is routed to `Boundary_credit` and everything else goes to `Boundary_any`.

## Triggering from the API / debugger

`POST /escalations/{escalation_code}/trigger` (claim `trigger_escalation`) injects a named escalation into **waiting catchers** on every running process instance: Event Subprocess starts and waiting Escalation Boundary FNIs. The plugin facade equivalent is `facade.escalations.publish.(escalation_code)`.

This is a debugger/operator inject, the same class as message and signal triggers. It is **not** a modeled BPMN throw:

- It does **not** walk the parent chain. Each running PI is scanned on its own.
- It does **not** insert pending rows. Unmatched codes return `{deliveries: [], pending: false}`.
- It does **not** transition unmatched PIs to `:escalated`.
- It carries **no payload**. Catch-all boundaries (blank code) still match a named trigger when no more-specific waiter exists in that candidate set.

The Studio debugger overlay on an active Escalation Boundary calls this route. Catch-all overlays send a non-blank sentinel such as `__catchall__` so the path parameter is valid.

## Scope Rules

| Source of escalation | Valid target boundaries |
|---|---|
| Escalation End Event inside a Call Activity child | Boundaries on the Call Activity shell in the parent process |
| Escalation End Event inside an Embedded Subprocess | Boundaries on the SubProcess shell in the parent process |
| Escalation Intermediate Throw inside a Call Activity child | Same — boundaries on the CA shell |
| Escalation from a nested child (A → B → C) | Escalation propagates upward through each layer: C → B → A |

Escalation **cannot** target a sibling scope, a cousin scope, or a child scope.

## Resume Behaviour

Escalation Boundary Events resume correctly after an engine restart. The boundary FNI re-enters its `:waiting` state during the resume phase, and the parent re-monitors the running child PI. If the child has already escalated (and the engine restarted before the boundary could fire), the resume path re-delivers the escalation message and the boundary fires as normal.

## Limitations

- **No top-level Escalation Start Event**: a process cannot be started by an incoming escalation. Escalation Start Events **are** supported on Event Subprocesses (interrupting and non-interrupting).
- **No Escalation in parallel join context**: If an escalation comes from one branch of a parallel split, it propagates upward without affecting the other parallel branches.

## Related

- [Error End Events](error-end-events.md) — similar propagation for technical/unrecoverable errors
- [Error Boundary Events](error-boundary-events.md) — boundary events for catching errors
- [Call Activities](call-activities.md) — escalation propagates across Call Activity boundaries
- [Embedded Subprocesses](embedded-subprocesses.md) — escalation propagates across Subprocess boundaries
- [Monitoring](monitoring.md) — `EscalationRaised` event and telemetry

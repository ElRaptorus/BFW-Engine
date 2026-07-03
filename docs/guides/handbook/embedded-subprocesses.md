# Embedded Subprocesses

Embedded subprocesses (`<bpmn:subProcess>`) define a nested scope of flow nodes inside a parent process. Unlike [Call Activities](call-activities.md), the subprocess's model is not a separately deployed process — it is defined inline within the parent BPMN XML. This guide covers configuration, data mapping, error handling, scoping rules, and the key boundaries that distinguish embedded subprocesses from Call Activities.

## How It Works

1. The parent PI encounters the SubProcess activity
2. The engine extracts a synthetic `%Process{}` from the subprocess's inner nodes (Start Event, Tasks, End Events, etc.)
3. Input mappings (if configured) transform the parent's token payload into the child's start payload
4. A child PI is spawned for the subprocess scope, linked to the parent
5. The parent's SubProcess FNI enters `waiting` state while the child runs
6. When the child finishes, output mappings (if configured) transform the child's result before returning it to the parent
7. The parent PI continues along the SubProcess's outgoing sequence flow

## BPMN Configuration

```xml
<bpmn:subProcess id="SubProcess_1" name="Validation">
  <bpmn:startEvent id="Sub_Start" name="Start" />
  <bpmn:serviceTask id="Sub_Validate" name="Validate Input" implementation="validator" />
  <bpmn:endEvent id="Sub_End" name="End" />
  <bpmn:sequenceFlow id="Sub_F1" sourceRef="Sub_Start" targetRef="Sub_Validate" />
  <bpmn:sequenceFlow id="Sub_F2" sourceRef="Sub_Validate" targetRef="Sub_End" />
</bpmn:subProcess>
```

Supported extension elements on the `<bpmn:subProcess>`:

| Extension Element | Purpose |
|-------------------|---------|
| `evil:inputMapping` | FEEL expression mapping parent token fields to child start payload |
| `evil:outputMapping` | FEEL expression mapping child result fields back to parent token |
| `evil:payloadContract` | JSON Schema validated against the input payload before entering the subprocess |
| `evil:resultContract` | JSON Schema validated against the output before returning to the parent |

## Subprocess Contents Rules

The engine validates subprocess contents at **runtime** (not deploy time), which allows work-in-progress diagrams to be deployed:

| Rule | Requirement |
|------|-------------|
| Exactly one None Start Event | The subprocess must have exactly one untyped Start Event |
| No typed Start Events | Timer, Message, Signal Start Events are only allowed in [Event Subprocesses](event-subprocesses.md) |
| At least one End Event | The subprocess must contain at least one End Event |

If the subprocess is on a branch that is never reached at runtime, validation never fires and the process runs normally.

## Input and Output Mappings

Input and output mappings work identically to [Call Activity mappings](call-activities.md#input-mappings):

```xml
<bpmn:subProcess id="SP_1" name="Process Order">
  <bpmn:extensionElements>
    <evil:inputMapping source="token.orderId" target="order_id" />
    <evil:outputMapping source="token.result" target="validation_result" />
  </bpmn:extensionElements>
  <!-- inner flow nodes -->
</bpmn:subProcess>
```

When no mappings are configured, the parent's full token payload is passed to the child unchanged, and the child's aggregated End Event result flows back to the parent unchanged.

## Payload and Result Contracts

Contracts validate data at the subprocess boundary:

```xml
<evil:payloadContract>{"type":"object","required":["orderId"]}</evil:payloadContract>
<evil:resultContract>{"type":"object","required":["status"]}</evil:resultContract>
```

A payload contract violation prevents the child from starting. A result contract violation causes the parent PI to go `fatal` after the child has already completed.

## Child PI Lifecycle

The subprocess child PI is a fully independent Process Instance with its own ID, state machine, and persistence:

| Property | Description |
|----------|-------------|
| `parent_process_instance_id` | Set on the child PI, pointing back to the parent |
| `root_process_instance_id` | **Inherited from the parent** — this is what enables WS event fan-out |
| `triggerer_flow_node_instance_id` | Set on the child PI, pointing to the parent's SubProcess FNI |
| `child_process_instance_id` | Stored in the SubProcess FNI's `type_properties`, pointing to the child |
| `process_version_id` | **Same as the parent's** — the child's model is extracted from the parent's BPMN |

### Events

When a subprocess child PI is spawned, the engine emits:

| Event | Channel | Content |
|-------|---------|---------|
| `SubProcessChildStarted` | `EngineEventBus` | `subprocess_flow_node_instance_id`, `parent_process_instance_id`, `child_process_instance_id`, `subprocess_model_id`, `subprocess_version`, `occurred_at` |
| Telemetry `[:evil_engine, :subprocess, :child_started]` | `:telemetry` | Same fields as the struct |

## Error Handling

Errors inside embedded subprocesses follow the same boundary resolution pattern as Call Activities:

| Scenario | Behavior |
|----------|----------|
| Child fatals, matching error boundary on SubProcess | Parent routes through the boundary's outgoing flows (parent finishes normally) |
| Child fatals, no matching boundary | Parent PI transitions to `fatal` |
| Child hits Error End Event, matching error boundary on SubProcess | Parent routes through boundary (child ends in `error` state) |
| Child hits Error End Event, no matching boundary | Error propagates up: child ends in `error` state, parent PI transitions to `error` |
| Child crashes (OTP process death) | Treated as `CHILD_CRASH` error, checked against boundaries |
| Subprocess contents invalid (no Start Event, etc.) | Parent PI transitions to `fatal` (no child spawned) |

### Terminate End Event Scoping

A Terminate End Event inside a subprocess kills all remaining active FNIs **within the subprocess's child PI only**. The parent PI is not affected — it receives the subprocess result normally and continues.

## WebSocket Event Fan-Out

Events from the subprocess child PI are fanned out to the **root process instance's channel**. This means subscribers watching the root PI's WebSocket channel see events from all nested embedded subprocesses.

| Nesting Level | `root_process_instance_id` | Events Visible On Root Channel |
|---------------|---------------------------|-------------------------------|
| Embedded Subprocess (level 1) | Inherited from parent (= root PI) | Yes |
| Embedded Subprocess (level 2) | Inherited from parent (= root PI) | Yes |
| Call Activity child | **Reset to self** | No — fan-out stops at the CA boundary |

This is the critical difference: embedded subprocess events bubble up to the root, but Call Activity events do **not** cross the Call Activity boundary.

## Cascade Behavior

| Trigger | Behavior |
|---------|----------|
| Parent PI is aborted | Abort cascades to the running subprocess child |
| Parent PI goes fatal | Fatal cascades to the running subprocess child |
| SubProcess FNI is interrupted (by a boundary event) | Child PI is aborted, subprocess child FNI processes are killed |

## Nesting

Embedded subprocesses can be nested arbitrarily:

- SubProcess inside SubProcess (any depth)
- Call Activity inside SubProcess (the CA starts a separately deployed child)
- SubProcess inside a Call Activity's child (the subprocess runs within the CA child's scope)

Each level creates its own child PI. Events fan out through the chain until a Call Activity boundary is reached.

## Resume on Restart

Embedded subprocesses support full resume-on-restart, identical to Call Activities:

| Child State | Resume Behavior |
|-------------|----------------|
| Still running (in Registry) | Parent re-monitors the running child and waits for completion |
| No longer running | Parent spawns a new child PI and runs the full lifecycle from scratch |

## Embedded Subprocess vs Call Activity

| Dimension | Embedded Subprocess | Call Activity |
|-----------|-------------------|---------------|
| **Model location** | Inline in the parent BPMN XML | Separately deployed BPMN process |
| **Deployment** | Deployed with the parent — no separate deploy needed | Must be deployed independently before the parent can invoke it |
| **Version resolution** | Always uses the parent's model (same `process_version_id`) | Resolves the latest version of the called process at runtime |
| **`root_process_instance_id`** | **Inherited** — events fan out to root channel | **Reset to self** — events stay within the CA child's channel |
| **Reusability** | Not reusable — scoped to a single parent process | Reusable — any process can invoke the same Call Activity target |
| **Data scoping** | Shares the parent's `process_version_id`; Data Objects are scoped to the subprocess | Fully independent data scope (own `process_version_id`, own Data Objects) |
| **Diagram visibility** | Inner nodes visible in the parent diagram (expanded subprocess) | Inner nodes visible only in the child's own diagram |
| **Event telemetry** | `SubProcessChildStarted` | `CallActivityChildStarted` |

### When to Use Each

Use an **Embedded Subprocess** when:

- The inner flow is tightly coupled to the parent and only makes sense in that context
- You want events from the subprocess to appear on the parent PI's WebSocket channel automatically
- You want a visual grouping of related activities in the BPMN diagram
- The subprocess does not need to be invoked from multiple places

Use a **Call Activity** when:

- The child process is a reusable unit invoked from multiple parent processes
- You want independent deployment and versioning of the child process
- You want strict isolation: the child PI's events should not leak to the parent's channel
- The child process represents a distinct business capability managed by a different team

## Related

- [Call Activities](call-activities.md) — invoking a separately deployed child process
- [Error Boundary Events](error-boundary-events.md) — catching subprocess errors
- [Error End Events](error-end-events.md) — BPMN error propagation through subprocess boundaries
- [FEEL Expressions](expressions.md) — input/output mapping expressions
- [Data Objects](data-objects.md) — scoped data within subprocesses
- [Monitoring](monitoring.md) — observing subprocess lifecycle events

# Conditional Events

Conditional Events evaluate a FEEL expression against the current process instance state and fire when the condition becomes true. Unlike timer, message, and signal events that wait for an external trigger, conditional events are re-evaluated by the engine itself whenever the PI's state changes.

## Overview

A conditional event carries a `<bpmn:condition>` child element inside a `<bpmn:conditionalEventDefinition>`. The condition is a FEEL expression that can reference `token`, `context`, `dataObjects`, `process`, `processInstance`, and `identity` — the standard FEEL bindings.

When a conditional event is reached:

1. The engine evaluates the condition against the current PI state
2. If the condition is already **true**, the event fires immediately — no waiting
3. If the condition is **false**, the event parks as "waiting" and the engine re-evaluates the condition after every subsequent state change (FNI completion, Data Object write, etc.)
4. When the condition becomes true, the event fires and execution continues

## Conditional Event Types

| BPMN Element | Position | Role |
|---|---|---|
| Intermediate Conditional Catch Event | Intermediate | Waits until the condition becomes true, then continues |
| Conditional Boundary Event (interrupting) | Boundary | Monitors the condition while a host activity is active; fires once to interrupt the host |
| Conditional Boundary Event (non-interrupting) | Boundary | Monitors the condition while a host activity is active; fires at most once to spawn a parallel branch |
| Conditional Start Event (Event Subprocess) | ESP start | **Live.** An Event Subprocess may start on a `false → true` FEEL transition |
| Conditional Start Event (top-level) | Top-level start | **Not supported.** A top-level Conditional Start does not create a new PI |

## BPMN XML

Conditional events use the standard `<bpmn:conditionalEventDefinition>` element with a `<bpmn:condition>` child:

```xml
<bpmn:intermediateCatchEvent id="Catch_condition" name="Wait for Approval">
  <bpmn:conditionalEventDefinition>
    <bpmn:condition>token.approved = true</bpmn:condition>
  </bpmn:conditionalEventDefinition>
  <bpmn:incoming>Flow_1</bpmn:incoming>
  <bpmn:outgoing>Flow_2</bpmn:outgoing>
</bpmn:intermediateCatchEvent>
```

For boundary events, the `cancelActivity` attribute controls interrupting vs non-interrupting:

```xml
<bpmn:boundaryEvent id="Boundary_cond" attachedToRef="UserTask_1" cancelActivity="true">
  <bpmn:conditionalEventDefinition>
    <bpmn:condition>dataObjects.Order.status = "cancelled"</bpmn:condition>
  </bpmn:conditionalEventDefinition>
  <bpmn:outgoing>Flow_cancel_path</bpmn:outgoing>
</bpmn:boundaryEvent>
```

## Condition Expression

The condition expression is a FEEL expression evaluated against the standard bindings:

| Binding | Description |
|---|---|
| `token` | Current flow node's input token (the runtime payload) |
| `context` | Immutable process-level variables from the start payload |
| `dataObjects` | Data Objects attached to the process (by ID) |
| `process` | Process metadata (`id`, `name`, `version`) |
| `processInstance` | Instance metadata (`id`, `startedAt`, `startedBy`) |
| `identity` | Caller identity (`id`, `roles`, `groups`, `claims`) |

Common condition patterns:

```
token.approved = true
dataObjects.Order.status = "shipped"
context.threshold <= token.amount
token.retryCount > 3
```

The condition must evaluate to a boolean. Non-boolean results (strings, numbers, null) are treated as `false` — the event remains waiting. FEEL evaluation errors (unknown variables, syntax errors) are also treated as `false` with a warning log.

## Re-evaluation Mechanism

The engine re-evaluates all waiting conditional events after **every state change** in the process instance. This includes:

- Any FNI transitioning to a terminal state (finished, fatal, aborted, interrupted)
- Data Object writes (via Data Output Associations)
- Async service task completions

This ensures that conditional events respond promptly to any state change that might satisfy their condition, without requiring explicit "notify" calls from handlers.

## Interrupting vs Non-Interrupting Boundary

**Interrupting** (`cancelActivity="true"`): When the condition fires, the host activity is interrupted, sibling boundary FNIs are cancelled, and execution follows the boundary event's outgoing path. The host activity's handler receives `handle_aborted/1` for cleanup.

**Non-interrupting** (`cancelActivity="false"`): When the condition fires, a parallel branch is spawned along the boundary event's outgoing path. The host activity continues running. Unlike timer, message, and signal non-interrupting boundaries that can fire repeatedly, a **conditional boundary fires at most once** — it does not re-register after firing.

## Event-Based Gateway Integration

Conditional catch events can follow an Event-Based Gateway, participating in the first-wins race alongside timer, message, and signal catch events. The first event to fire wins; all siblings are cancelled.

```xml
<bpmn:eventBasedGateway id="EBG_1">
  <bpmn:outgoing>Flow_to_timer</bpmn:outgoing>
  <bpmn:outgoing>Flow_to_condition</bpmn:outgoing>
</bpmn:eventBasedGateway>

<bpmn:intermediateCatchEvent id="Catch_timer">
  <bpmn:timerEventDefinition>
    <bpmn:timeDuration>PT30S</bpmn:timeDuration>
  </bpmn:timerEventDefinition>
  <bpmn:incoming>Flow_to_timer</bpmn:incoming>
  <bpmn:outgoing>Flow_timeout</bpmn:outgoing>
</bpmn:intermediateCatchEvent>

<bpmn:intermediateCatchEvent id="Catch_cond">
  <bpmn:conditionalEventDefinition>
    <bpmn:condition>context.ready = true</bpmn:condition>
  </bpmn:conditionalEventDefinition>
  <bpmn:incoming>Flow_to_condition</bpmn:incoming>
  <bpmn:outgoing>Flow_ready</bpmn:outgoing>
</bpmn:intermediateCatchEvent>
```

## Scope Rules

Conditional events evaluate against **their own Process Instance's state only**. BPMN scopes are opaque boundaries:

| Scope boundary | Condition sees changes? | Rationale |
|---|---|---|
| Same PI (top-level or subprocess) | **Yes** | Conditional events and the state mutation share the same GenServer |
| Embedded Subprocess → parent | **No** | The subprocess is a separate child PI with its own `conditional_waiters` and `data_object_cache` |
| Parent → Embedded Subprocess | **No** | The parent PI does not observe internal state transitions of the child |
| Call Activity child ↔ parent | **No** | Call Activity children are separate PIs; the parent sees only the terminal outcome |

In practice, this means a conditional boundary event on a User Task monitors the **same PI's** Data Objects and FNI completions. If the condition depends on data written inside an Embedded Subprocess, it will not fire — the subprocess is a separate scope. Design your conditions to reference data visible within the conditional event's own process scope.

## Resume Behaviour

After an engine restart, conditional events are properly resumed:

1. The PI's `Resumption` module identifies waiting conditional FNIs by `event_type: "conditional"`
2. The handler's `handle_resume/3` is called, which re-evaluates the condition
3. If the condition is now true (state changed while the engine was down), the event completes immediately
4. If still false, the handler re-parks and registers a new waiter for ongoing re-evaluation

## Limitations

- **Top-level Conditional Start Events** are not supported (no new PI from a condition). **Event Subprocess Conditional Start is live** — see [Event Subprocesses](event-subprocesses.md).
- **No looping non-interrupting**: Conditional non-interrupting boundaries fire at most once per host activity lifecycle
- **No external trigger**: Conditional events cannot be triggered via REST API — they fire exclusively based on PI-internal state changes

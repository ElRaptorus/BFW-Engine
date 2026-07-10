# Event Subprocesses

An **Event Subprocess (ESP)** is a `<bpmn:subProcess>` with `triggeredByEvent="true"` placed inside a process (or inside an embedded subprocess). Unlike an [Embedded Subprocess](embedded-subprocesses.md), it is **not** wired into the sequence flow — it has no incoming and no outgoing sequence flows. It lies dormant until its single **typed start event** is triggered by an event that occurs within its enclosing scope, at which point it runs as a child process instance. Use an ESP to handle a cross-cutting condition — a cancellation message, a deadline timer, an error, an escalation — that can arise anywhere inside a scope, without threading a boundary event onto every activity.

> **Direction rule:** an ESP is *triggered*, never *entered*. It reacts to something that happens inside its scope. It cannot be started from outside (REST, plugin, or Call Activity) — see [Starting Instances](starting-instances.md).

## When to Use an Event Subprocess

Use an Event Subprocess when:

- A condition (message, timer, error, escalation, signal, or FEEL condition) can occur at **any point** inside a scope and you want a single handler rather than a boundary event on every activity.
- You want to **cancel** the scope's remaining work and run cleanup/compensating logic (interrupting ESP).
- You want to run a **parallel** reaction while the main flow continues (non-interrupting ESP).

Prefer a **boundary event** when the reaction is tied to one specific activity. Prefer an ESP when the reaction belongs to the whole scope.

## How It Works

1. On process start (and on resume), the scope PI scans its flow nodes for Event Subprocesses and **registers each one's trigger** (message/signal subscription, timer arm, or conditional waiter). Error and escalation triggers are resolved reactively at raise time — nothing is pre-registered for them.
2. The trigger lies **dormant** — the ESP does nothing until its start event fires.
3. When the trigger fires, the scope PI creates the ESP **shell FNI** and spawns a **child PI** for the ESP's inner flow, passing the trigger payload straight through (no data mappings).
4. **Interrupting** ESP: the scope PI cancels every other active/waiting flow node in the scope, then runs the ESP child. **Non-interrupting** ESP: the ESP child runs in parallel and the trigger re-arms so it can fire again.
5. When the ESP child finishes, its shell FNI completes. The scope PI finishes once its main flow **and** all ESP children have completed.

## BPMN Configuration

An Event Subprocess is a `<bpmn:subProcess triggeredByEvent="true">` with **exactly one** start event that carries a typed event definition. There are **no ESP-specific `evil:` extensions** — you use standard BPMN `triggeredByEvent` and `isInterrupting` only.

```xml
<bpmn:definitions
  xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL"
  xmlns:evil="https://evilengine.dev/schema/bpmn"
  targetNamespace="https://evilengine.dev/schema/bpmn"
  id="Definitions_1">

  <bpmn:message id="Msg_Cancel" name="order-cancelled" />

  <bpmn:process id="order-process" name="Order Process" isExecutable="true">
    <bpmn:extensionElements>
      <evil:version>1.0.0</evil:version>
    </bpmn:extensionElements>

    <bpmn:startEvent id="Start_Main">
      <bpmn:outgoing>F_Main_1</bpmn:outgoing>
    </bpmn:startEvent>
    <bpmn:userTask id="Task_Fulfil" name="Fulfil Order">
      <bpmn:incoming>F_Main_1</bpmn:incoming>
      <bpmn:outgoing>F_Main_2</bpmn:outgoing>
    </bpmn:userTask>
    <bpmn:endEvent id="End_Main">
      <bpmn:incoming>F_Main_2</bpmn:incoming>
    </bpmn:endEvent>
    <bpmn:sequenceFlow id="F_Main_1" sourceRef="Start_Main" targetRef="Task_Fulfil" />
    <bpmn:sequenceFlow id="F_Main_2" sourceRef="Task_Fulfil" targetRef="End_Main" />

    <!-- Event Subprocess: no incoming/outgoing sequence flows on the shell -->
    <bpmn:subProcess id="ESP_Cancel" triggeredByEvent="true">
      <bpmn:startEvent id="ESP_Cancel_Start" isInterrupting="true">
        <bpmn:messageEventDefinition messageRef="Msg_Cancel" />
        <bpmn:outgoing>F_ESP_1</bpmn:outgoing>
      </bpmn:startEvent>
      <bpmn:serviceTask id="ESP_Cancel_Refund" name="Refund Customer" implementation="http">
        <bpmn:incoming>F_ESP_1</bpmn:incoming>
        <bpmn:outgoing>F_ESP_2</bpmn:outgoing>
      </bpmn:serviceTask>
      <bpmn:endEvent id="ESP_Cancel_End">
        <bpmn:incoming>F_ESP_2</bpmn:incoming>
      </bpmn:endEvent>
      <bpmn:sequenceFlow id="F_ESP_1" sourceRef="ESP_Cancel_Start" targetRef="ESP_Cancel_Refund" />
      <bpmn:sequenceFlow id="F_ESP_2" sourceRef="ESP_Cancel_Refund" targetRef="ESP_Cancel_End" />
    </bpmn:subProcess>
  </bpmn:process>
</bpmn:definitions>
```

> Add `<bpmndi:BPMNDiagram>` DI to every file (see the repository conventions). It is omitted here for brevity.

## Trigger Types

The ESP's start event carries one typed event definition. Each is registered against the scope.

### Message

Fires when a correlated message reaches the scope. The correlation is evaluated at scope activation from `<evil:correlationKey>` (see [Message Events](message-events.md)).

```xml
<bpmn:subProcess id="ESP_Msg" triggeredByEvent="true">
  <bpmn:startEvent id="ESP_Msg_Start" isInterrupting="true">
    <bpmn:messageEventDefinition messageRef="Msg_Cancel" />
    <bpmn:outgoing>F_ESP_Msg_1</bpmn:outgoing>
  </bpmn:startEvent>
  <!-- inner flow ... -->
</bpmn:subProcess>
```

### Signal

Fires on a broadcast signal matching the signal name (see [Signal Events](signal-events.md)). Signals carry no payload and no correlation.

```xml
<bpmn:signal id="Sig_Recall" name="product-recall" />
...
<bpmn:subProcess id="ESP_Sig" triggeredByEvent="true">
  <bpmn:startEvent id="ESP_Sig_Start" isInterrupting="false">
    <bpmn:signalEventDefinition signalRef="Sig_Recall" />
    <bpmn:outgoing>F_ESP_Sig_1</bpmn:outgoing>
  </bpmn:startEvent>
  <!-- inner flow ... -->
</bpmn:subProcess>
```

### Timer

Fires relative to **scope activation** (not deploy). `timeDate` / `timeDuration` fire once; `timeCycle` (e.g. `R/PT1H`) re-arms per tick and is only valid on a **non-interrupting** timer ESP start (see [Timer Events](timer-events.md)).

```xml
<bpmn:subProcess id="ESP_Deadline" triggeredByEvent="true">
  <bpmn:startEvent id="ESP_Deadline_Start" isInterrupting="true">
    <bpmn:timerEventDefinition>
      <bpmn:timeDuration>PT24H</bpmn:timeDuration>
    </bpmn:timerEventDefinition>
    <bpmn:outgoing>F_ESP_Deadline_1</bpmn:outgoing>
  </bpmn:startEvent>
  <!-- inner flow ... -->
</bpmn:subProcess>
```

### Conditional

**Edge-triggered** — fires on a `false → true` transition of the FEEL condition, re-evaluated on every scope state change (see [Conditional Events](conditional-events.md)). It does **not** fire while the condition merely stays true.

```xml
<bpmn:subProcess id="ESP_Cond" triggeredByEvent="true">
  <bpmn:startEvent id="ESP_Cond_Start" isInterrupting="false">
    <bpmn:conditionalEventDefinition>
      <bpmn:condition>token.stockLevel &lt; 10</bpmn:condition>
    </bpmn:conditionalEventDefinition>
    <bpmn:outgoing>F_ESP_Cond_1</bpmn:outgoing>
  </bpmn:startEvent>
  <!-- inner flow ... -->
</bpmn:subProcess>
```

### Error

Catches a BPMN error raised within the scope (see [Error End Events](error-end-events.md) and [Error Boundary Events](error-boundary-events.md)). An Error ESP start **must be interrupting** — a faulted scope cannot be resumed.

```xml
<bpmn:error id="Err_Payment" errorCode="PAYMENT_FAILED" name="Payment Failed" />
...
<bpmn:subProcess id="ESP_Err" triggeredByEvent="true">
  <bpmn:startEvent id="ESP_Err_Start" isInterrupting="true">
    <bpmn:errorEventDefinition errorRef="Err_Payment" />
    <bpmn:outgoing>F_ESP_Err_1</bpmn:outgoing>
  </bpmn:startEvent>
  <!-- inner flow ... -->
</bpmn:subProcess>
```

### Escalation

Catches an escalation raised within the scope (see [Escalation Events](escalation-events.md)). May be interrupting or non-interrupting.

```xml
<bpmn:escalation id="Esc_Manual" escalationCode="MANUAL_REVIEW" name="Manual Review" />
...
<bpmn:subProcess id="ESP_Esc" triggeredByEvent="true">
  <bpmn:startEvent id="ESP_Esc_Start" isInterrupting="false">
    <bpmn:escalationEventDefinition escalationRef="Esc_Manual" />
    <bpmn:outgoing>F_ESP_Esc_1</bpmn:outgoing>
  </bpmn:startEvent>
  <!-- inner flow ... -->
</bpmn:subProcess>
```

## Interrupting vs Non-Interrupting

`isInterrupting` is a standard BPMN attribute on the ESP start event (default `true`). It is modeler-controlled — there is no `evil:*` override and no property-pane toggle.

| | Interrupting (`isInterrupting="true"`) | Non-interrupting (`isInterrupting="false"`) |
|---|---|---|
| Effect on scope | Cancels every other active/waiting flow node in the scope (state `:interrupted`) | Main flow continues in parallel |
| Multiplicity | Fires once — the trigger is torn down | May fire repeatedly — each fire spawns an independent child PI |
| Scope completion | Scope finishes when the ESP child completes | Scope finishes when the main flow **and** every ESP child complete |
| Scope terminal state | `:finished` — the interrupting fire does **not** kill the scope PI | `:finished` |

> **The interrupting fire never aborts or fatals the scope PI merely because the ESP fired.** It cancels the *other* work and then runs the ESP body; the scope completes normally as `:finished`.

## Start-Event Scope Matrix

Which trigger types are valid in each variant:

| Trigger | Interrupting | Non-interrupting |
|---------|:---:|:---:|
| Message | ✓ | ✓ |
| Signal | ✓ | ✓ |
| Timer | ✓ | ✓ |
| Conditional | ✓ | ✓ |
| Escalation | ✓ | ✓ |
| Error | ✓ | — (Error must interrupt) |

A None (untyped) start is **not** allowed on an ESP — the start must be typed.

## Cyclic Timer Note

A `timeCycle` (e.g. `R/PT1H`) on a **non-interrupting** timer ESP start recurs: the **scope** re-arms the cycle after each tick, and each tick spawns a fresh, independent ESP child PI. Date/duration timers are one-shot.

## Conflict and Precedence Rules

### Messages (catch beats start)

An ESP Message Start is a **gated Start Event**, not a fan-out delivery. Precedence ladder for a message `(name, correlation)`:

1. **Inline Message Catch / Message Boundary** — always consumes the message.
2. **ESP Message Start** of a running scope — fires only if no catch/boundary consumed it.
3. **Standalone Message Start** — creates a new PI, only if tiers 1 and 2 are empty.

So a Catch/Boundary always beats an ESP Message Start, and an ESP Message Start beats a standalone Message Start (a running instance consumes the message before a new PI is created). **Signals are different** — an ESP Signal Start fires *alongside* catches, boundaries, and standalone signal starts (broadcast-all, no catch-wins gate).

### Errors and escalations (proximity, then specificity)

- **Proximity first:** a boundary event on the throwing activity is tested before the scope's ESP start; the scope ESP is tested before the error/escalation propagates to the parent. A scope-level escalation/error ESP therefore catches a throw raised in its scope **before** the parent sees it.
- **Specificity second:** only among peer ESP starts in the *same* scope — a specific `errorCode`/`escalationCode` match beats a catch-all (no-code) ESP start.
- A boundary-vs-ESP contest is never decided by specificity (they occupy different proximity levels).

## Gotchas

- **No sequence flows on the shell.** An ESP shell must have no incoming or outgoing sequence flows — deploy fails with `event_subprocess_has_sequence_flow` otherwise.
- **Globally-unique flow-node IDs.** IDs must be unique across the *entire* process tree, including every ESP inner scope and nested ESPs. Reusing `Start_1`/`End_1` inside an ESP fails deploy with `duplicate_flow_node_id`. Suffix per scope (e.g. `ESP_Cancel_Start`).
- **Exactly one typed start event.** Zero or multiple start events, or an untyped (None) start, fail deploy (`event_subprocess_no_start_event`, `event_subprocess_multiple_start_events`, `event_subprocess_untyped_start`).
- **Error must interrupt.** An Error ESP start with `isInterrupting="false"` fails deploy (`event_subprocess_error_start_must_interrupt`).
- **Conditional is edge-triggered.** A conditional ESP fires on `false → true`, not continuously while true. It re-arms after each fire (non-interrupting) only once the condition returns to false.
- **The ESP's own escape bubbles outward.** An uncaught error/escalation raised by the ESP child itself is offered to the ESP shell's own boundary events, then bubbles to the scope PI's parent — never back into the same scope.
- **Compensation start events on ESPs** are supported — see [Compensation](compensation.md). When compensation is triggered for a scope, an ESP with a compensation start event acts as the scope-level compensation handler.
- **Not yet supported:** Multiple / Parallel-Multiple start events.

## Related

- [Embedded Subprocesses](embedded-subprocesses.md) — the token-entered subprocess variant
- [Message Events](message-events.md) — message correlation and catch-wins-over-start
- [Signal Events](signal-events.md) — broadcast signals
- [Timer Events](timer-events.md) — timer definitions and cyclic timers
- [Conditional Events](conditional-events.md) — edge-triggered FEEL conditions
- [Escalation Events](escalation-events.md) — escalation propagation and proximity
- [Error End Events](error-end-events.md) / [Error Boundary Events](error-boundary-events.md) — BPMN error handling
- [Monitoring](monitoring.md) — observing `SubProcessChildStarted` / `EventSubprocessTriggered` events

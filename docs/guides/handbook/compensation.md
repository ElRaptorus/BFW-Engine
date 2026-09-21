# Compensation

Compensation is BPMN 2.0's built-in mechanism for **undoing work that already
completed successfully**. When a process reaches a point where earlier steps
need to be reversed — a flight was booked but the hotel is full, a payment was
charged but the order cannot be fulfilled — compensation lets you define how to
undo each step, and trigger that undo logic on demand.

> **Compensation vs Error Handling.** Error handling catches *failures* —
> something that went wrong while it was happening (a service call crashed, a
> validation failed). Compensation undoes *successes* — something that completed
> fine but whose result is no longer wanted. Both are about recovery, but they
> operate at different points in the timeline.

The most common real-world application of compensation is the **Saga Pattern**:
a long-running process where each step has an explicit "undo" counterpart, and
a failure at any point triggers the undo of all previously completed steps in
reverse order.

> **Key principle: Compensation is a mechanism, not a trigger.** The engine
> never automatically triggers compensation in response to failures, errors,
> escalations, or aborts. Compensation only runs when the diagram author
> explicitly places a Compensate Throw or Compensate End Event in the flow.
> If you want errors to cause compensation, you must model that path yourself
> — typically by catching the error with a boundary event and routing to a
> compensate throw. This is deliberate: the engine separates *what went wrong*
> (error handling) from *what to undo* (compensation), giving you full control
> over when and how rollback occurs.

## Compensation Building Blocks

Compensation requires four collaborating elements in your BPMN model:

```
  ┌───────────────┐
  │   Task A      │──── Sequence Flow ────▶ ...
  │  (the work)   │
  └───────┬───────┘
          │ attached
  ┌───────┴───────┐        Association
  │  Compensation │─────────────────────▶ ┌─────────────────────┐
  │   Boundary    │                       │  Undo Task A        │
  │    Event      │                       │  (handler activity)  │
  └───────────────┘                       │  isForCompensation   │
                                          └─────────────────────┘
```

### Compensation Boundary Event

A boundary event with a `<bpmn:compensateEventDefinition>` attached to a task.
It marks the host task as **compensable** — meaning the engine should track its
completion and allow its work to be undone later.

Unlike timer or message boundaries, a compensation boundary is never
"triggered" directly. It is a passive marker. The engine uses it to build its
internal compensation registry when the host activity completes.

```xml
<bpmn:boundaryEvent id="BE_Comp_A" attachedToRef="Task_A" cancelActivity="false">
  <bpmn:compensateEventDefinition />
</bpmn:boundaryEvent>
```

The `cancelActivity="false"` attribute is always set on compensation boundaries
because they do not interrupt their host task — they are declarative markers,
not runtime triggers.

### Compensation Handler Activity

A task (or subprocess) marked with `isForCompensation="true"`. This activity
contains the logic to undo the work of its associated task. It is never part
of the normal sequence flow — it has no incoming or outgoing sequence flows.

```xml
<bpmn:task id="Task_CompHandler_A" name="Cancel Reservation" isForCompensation="true" />
```

When compensation fires, the handler receives the **token snapshot** from the
moment its associated task completed. This gives the handler access to the
exact data the original task produced, which it typically needs to reverse the
operation (for example, the reservation ID to cancel).

### Association

A `<bpmn:association>` links the compensation boundary event to its handler
activity. This is how the engine knows which handler to invoke for which
compensable task.

```xml
<bpmn:association id="Assoc_Comp_A"
  sourceRef="BE_Comp_A"
  targetRef="Task_CompHandler_A"
  associationDirection="One" />
```

### Compensate Intermediate Throw Event

Triggers compensation and **continues the flow**. After all handlers have
executed, the token proceeds along the throw event's outgoing sequence flow.

The throw FNI stays on the normal activity path: it emits
`FlowNodeInstanceFinished` (not a waiting→finished `FlowNodeInstanceStateChanged`).
`waitForCompletion` on `<bpmn:compensateEventDefinition>` defaults to `true`
and is always treated as synchronous — `waitForCompletion="false"` is parsed
but still waits for every handler to finish before the token proceeds.

```xml
<bpmn:intermediateThrowEvent id="Throw_Comp" name="Undo Everything">
  <bpmn:incoming>Flow_In</bpmn:incoming>
  <bpmn:outgoing>Flow_Out</bpmn:outgoing>
  <bpmn:compensateEventDefinition />
</bpmn:intermediateThrowEvent>
```

Two modes:

- **Broadcast** (no `activityRef`): compensates all completed tasks with
  handlers, in LIFO order.
- **Targeted** (`activityRef="Task_A"`): compensates only the specified task.

```xml
<!-- Targeted: only undo Task_A -->
<bpmn:compensateEventDefinition activityRef="Task_A" />
```

### Compensate End Event

Triggers compensation and **ends the current path of execution**. There is no
outgoing sequence flow. When the process instance naturally quiesces (all paths
complete), the terminal state is `:compensated` instead of `:finished`.

```xml
<bpmn:endEvent id="End_Compensate" name="Compensate and End">
  <bpmn:incoming>Flow_In</bpmn:incoming>
  <bpmn:compensateEventDefinition />
</bpmn:endEvent>
```

## How Compensation Executes

When the engine reaches a Compensate Throw or Compensate End Event, it follows
this sequence:

1. **Collect targets.** The engine consults its compensation registry — the
   list of activities that (a) have already completed in this scope and (b)
   have a compensation boundary with an associated handler.

2. **Order targets.** For broadcast compensation (no `activityRef`), targets
   are ordered in **LIFO** (last-completed-first) sequence. For targeted
   compensation, only the single specified activity is included.

3. **Execute handlers sequentially.** Handlers run one at a time, in order.
   Each handler receives the token snapshot from the moment its associated
   task originally completed.

4. **After all handlers finish:**
   - **Throw Event:** the throw FNI finishes and the token continues on its
     outgoing sequence flow. The process continues normally.
   - **End Event:** the token is consumed (like a normal End Event). When the
     entire process instance quiesces — all active paths have ended — the PI
     terminal state becomes `:compensated`.

### Worked Example — LIFO broadcast

Consider a process: `Start → Task A → Task B → Throw Compensation → End`

Both Task A and Task B have compensation boundaries with handlers.

1. Task A completes → registered as compensable (order 1)
2. Task B completes → registered as compensable (order 2)
3. Throw Compensation is reached → broadcast mode (no `activityRef`)
4. Engine resolves targets in LIFO order: `[Task_B, Task_A]`
5. Handler B executes (receives Task B's completion token)
6. Handler A executes (receives Task A's completion token)
7. All handlers done → Throw FNI finishes → token flows to End

The complete BPMN for this pattern:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<bpmn:definitions
  xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL"
  xmlns:bpmndi="http://www.omg.org/spec/BPMN/20100524/DI"
  xmlns:dc="http://www.omg.org/spec/DD/20100524/DC"
  xmlns:di="http://www.omg.org/spec/DD/20100524/DI"
  xmlns:bfw="https://bifrostforge.world/schema/bpmn"
  targetNamespace="https://bifrostforge.world/schema/bpmn"
  id="Definitions_1">

  <bpmn:collaboration id="Collaboration_1">
    <bpmn:participant id="Participant_1" name="Default" processRef="CompensationLifo" />
  </bpmn:collaboration>

  <bpmn:process id="CompensationLifo" name="Compensation LIFO" isExecutable="true">
    <bpmn:extensionElements>
      <bfw:version>1.0.0</bfw:version>
    </bpmn:extensionElements>

    <bpmn:laneSet id="LaneSet_1">
      <bpmn:lane id="Lane_default" name="default">
        <bpmn:flowNodeRef>Start_1</bpmn:flowNodeRef>
        <bpmn:flowNodeRef>Task_A</bpmn:flowNodeRef>
        <bpmn:flowNodeRef>BE_Comp_A</bpmn:flowNodeRef>
        <bpmn:flowNodeRef>Task_CompHandler_A</bpmn:flowNodeRef>
        <bpmn:flowNodeRef>Task_B</bpmn:flowNodeRef>
        <bpmn:flowNodeRef>BE_Comp_B</bpmn:flowNodeRef>
        <bpmn:flowNodeRef>Task_CompHandler_B</bpmn:flowNodeRef>
        <bpmn:flowNodeRef>Throw_Compensation</bpmn:flowNodeRef>
        <bpmn:flowNodeRef>End_1</bpmn:flowNodeRef>
      </bpmn:lane>
    </bpmn:laneSet>

    <bpmn:startEvent id="Start_1" name="Start">
      <bpmn:outgoing>Flow_1</bpmn:outgoing>
    </bpmn:startEvent>

    <bpmn:task id="Task_A" name="Book Flight">
      <bpmn:incoming>Flow_1</bpmn:incoming>
      <bpmn:outgoing>Flow_2</bpmn:outgoing>
    </bpmn:task>

    <bpmn:boundaryEvent id="BE_Comp_A" attachedToRef="Task_A" cancelActivity="false">
      <bpmn:compensateEventDefinition />
    </bpmn:boundaryEvent>

    <bpmn:task id="Task_CompHandler_A" name="Cancel Flight" isForCompensation="true" />

    <bpmn:task id="Task_B" name="Book Hotel">
      <bpmn:incoming>Flow_2</bpmn:incoming>
      <bpmn:outgoing>Flow_3</bpmn:outgoing>
    </bpmn:task>

    <bpmn:boundaryEvent id="BE_Comp_B" attachedToRef="Task_B" cancelActivity="false">
      <bpmn:compensateEventDefinition />
    </bpmn:boundaryEvent>

    <bpmn:task id="Task_CompHandler_B" name="Cancel Hotel" isForCompensation="true" />

    <bpmn:intermediateThrowEvent id="Throw_Compensation" name="Undo All Bookings">
      <bpmn:incoming>Flow_3</bpmn:incoming>
      <bpmn:outgoing>Flow_4</bpmn:outgoing>
      <bpmn:compensateEventDefinition />
    </bpmn:intermediateThrowEvent>

    <bpmn:endEvent id="End_1" name="End">
      <bpmn:incoming>Flow_4</bpmn:incoming>
    </bpmn:endEvent>

    <bpmn:sequenceFlow id="Flow_1" sourceRef="Start_1" targetRef="Task_A" />
    <bpmn:sequenceFlow id="Flow_2" sourceRef="Task_A" targetRef="Task_B" />
    <bpmn:sequenceFlow id="Flow_3" sourceRef="Task_B" targetRef="Throw_Compensation" />
    <bpmn:sequenceFlow id="Flow_4" sourceRef="Throw_Compensation" targetRef="End_1" />

    <bpmn:association id="Assoc_A" sourceRef="BE_Comp_A" targetRef="Task_CompHandler_A"
      associationDirection="One" />
    <bpmn:association id="Assoc_B" sourceRef="BE_Comp_B" targetRef="Task_CompHandler_B"
      associationDirection="One" />
  </bpmn:process>
</bpmn:definitions>
```

### Targeted compensation

When you only want to undo a specific task, set `activityRef` on the
`compensateEventDefinition`:

```xml
<bpmn:intermediateThrowEvent id="Throw_Comp" name="Undo Flight Only">
  <bpmn:incoming>Flow_In</bpmn:incoming>
  <bpmn:outgoing>Flow_Out</bpmn:outgoing>
  <bpmn:compensateEventDefinition activityRef="Task_A" />
</bpmn:intermediateThrowEvent>
```

Only Task A's handler fires. Task B's handler is skipped even if Task B has
already completed. If Task A never completed (or has no compensation boundary),
the throw event is a no-op and the flow continues immediately.

## Compensation with Error/Escalation Boundaries (Saga Pattern)

The most powerful compensation pattern combines an embedded subprocess with
error boundaries and compensation handlers. This is the **Saga Pattern** —
each step in a multi-step transaction has an explicit compensating action, and
when something goes wrong, all completed steps are rolled back.

```
  ┌─────────────────────── Embedded SubProcess ───────────────────────┐
  │                                                                    │
  │  [Start] ──▶ [Book Flight] ──▶ [Book Hotel] ──▶ [Error End]       │
  │                  │ comp              │ comp                         │
  │                  ▼                   ▼                              │
  │            [Cancel Flight]    [Cancel Hotel]                        │
  │                                                                    │
  └────────────────────────────────────┬───────────────────────────────┘
                                       │ Error Boundary
                                       ▼
                        [Throw Compensation] ──▶ [End Compensated]
```

The pattern works as follows:

1. The subprocess runs Task A and Task B normally. Each has compensation
   handlers registered.
2. The subprocess throws an error (via an Error End Event, or a handler
   failure that triggers an error boundary).
3. The error boundary on the subprocess catches the error and activates the
   compensation path.
4. The Compensate Throw Event triggers broadcast compensation for all
   completed activities in the subprocess scope.
5. Handlers execute in LIFO order (Cancel Hotel first, then Cancel Flight).
6. After compensation completes, the process ends.

Here is the BPMN for this pattern:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<bpmn:definitions
  xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL"
  xmlns:bpmndi="http://www.omg.org/spec/BPMN/20100524/DI"
  xmlns:dc="http://www.omg.org/spec/DD/20100524/DC"
  xmlns:di="http://www.omg.org/spec/DD/20100524/DI"
  xmlns:bfw="https://bifrostforge.world/schema/bpmn"
  targetNamespace="https://bifrostforge.world/schema/bpmn"
  id="Definitions_1">

  <bpmn:collaboration id="Collaboration_1">
    <bpmn:participant id="Participant_1" name="Default" processRef="SagaPattern" />
  </bpmn:collaboration>

  <bpmn:process id="SagaPattern" name="Saga Pattern" isExecutable="true">
    <bpmn:extensionElements>
      <bfw:version>1.0.0</bfw:version>
    </bpmn:extensionElements>

    <bpmn:laneSet id="LaneSet_1">
      <bpmn:lane id="Lane_default" name="default">
        <bpmn:flowNodeRef>Start_1</bpmn:flowNodeRef>
        <bpmn:flowNodeRef>SubProcess_1</bpmn:flowNodeRef>
        <bpmn:flowNodeRef>BE_Error</bpmn:flowNodeRef>
        <bpmn:flowNodeRef>Throw_Comp</bpmn:flowNodeRef>
        <bpmn:flowNodeRef>End_Compensated</bpmn:flowNodeRef>
      </bpmn:lane>
    </bpmn:laneSet>

    <bpmn:startEvent id="Start_1" name="Start">
      <bpmn:outgoing>Flow_1</bpmn:outgoing>
    </bpmn:startEvent>

    <bpmn:subProcess id="SubProcess_1" name="Booking Saga">
      <bpmn:startEvent id="SP_Start">
        <bpmn:outgoing>SF_1</bpmn:outgoing>
      </bpmn:startEvent>

      <bpmn:task id="Task_Flight" name="Book Flight">
        <bpmn:incoming>SF_1</bpmn:incoming>
        <bpmn:outgoing>SF_2</bpmn:outgoing>
      </bpmn:task>

      <bpmn:boundaryEvent id="BE_Comp_Flight" attachedToRef="Task_Flight" cancelActivity="false">
        <bpmn:compensateEventDefinition />
      </bpmn:boundaryEvent>

      <bpmn:task id="Handler_CancelFlight" name="Cancel Flight" isForCompensation="true" />

      <bpmn:task id="Task_Hotel" name="Book Hotel">
        <bpmn:incoming>SF_2</bpmn:incoming>
        <bpmn:outgoing>SF_3</bpmn:outgoing>
      </bpmn:task>

      <bpmn:boundaryEvent id="BE_Comp_Hotel" attachedToRef="Task_Hotel" cancelActivity="false">
        <bpmn:compensateEventDefinition />
      </bpmn:boundaryEvent>

      <bpmn:task id="Handler_CancelHotel" name="Cancel Hotel" isForCompensation="true" />

      <bpmn:endEvent id="SP_Error_End" name="Booking Failed">
        <bpmn:incoming>SF_3</bpmn:incoming>
        <bpmn:errorEventDefinition />
      </bpmn:endEvent>

      <bpmn:sequenceFlow id="SF_1" sourceRef="SP_Start" targetRef="Task_Flight" />
      <bpmn:sequenceFlow id="SF_2" sourceRef="Task_Flight" targetRef="Task_Hotel" />
      <bpmn:sequenceFlow id="SF_3" sourceRef="Task_Hotel" targetRef="SP_Error_End" />

      <bpmn:association id="Assoc_Flight" sourceRef="BE_Comp_Flight"
        targetRef="Handler_CancelFlight" associationDirection="One" />
      <bpmn:association id="Assoc_Hotel" sourceRef="BE_Comp_Hotel"
        targetRef="Handler_CancelHotel" associationDirection="One" />
    </bpmn:subProcess>

    <!-- Error boundary catches the subprocess error -->
    <bpmn:boundaryEvent id="BE_Error" attachedToRef="SubProcess_1" cancelActivity="true">
      <bpmn:outgoing>Flow_Error</bpmn:outgoing>
      <bpmn:errorEventDefinition />
    </bpmn:boundaryEvent>

    <!-- Trigger compensation for all completed tasks in the subprocess -->
    <bpmn:intermediateThrowEvent id="Throw_Comp" name="Compensate Bookings">
      <bpmn:incoming>Flow_Error</bpmn:incoming>
      <bpmn:outgoing>Flow_2</bpmn:outgoing>
      <bpmn:compensateEventDefinition />
    </bpmn:intermediateThrowEvent>

    <bpmn:endEvent id="End_Compensated" name="Saga Rolled Back">
      <bpmn:incoming>Flow_2</bpmn:incoming>
    </bpmn:endEvent>

    <bpmn:sequenceFlow id="Flow_1" sourceRef="Start_1" targetRef="SubProcess_1" />
    <bpmn:sequenceFlow id="Flow_Error" sourceRef="BE_Error" targetRef="Throw_Comp" />
    <bpmn:sequenceFlow id="Flow_2" sourceRef="Throw_Comp" targetRef="End_Compensated" />
  </bpmn:process>
</bpmn:definitions>
```

The same pattern works with **escalation boundaries** — replace the Error End
Event inside the subprocess with an Escalation Throw, and replace the error
boundary on the subprocess with an escalation boundary.

## Compensation End Events Do Not Interrupt Parallel Branches

A common misconception is that a Compensation End Event should stop the entire
process — like a Terminate End Event kills everything. **This is not the case.**

> A Compensation End Event ends **only its own path** of execution. If
> parallel branches are running, they continue normally. The process instance
> reaches its terminal state only when all active paths have naturally
> completed.

This follows the BPMN 2.0 specification (§10.6) and matches the behavior of
Camunda and Flowable: *"A compensation end event triggers compensation and the
current path of execution is ended."*

### Why this design is correct

Compensation is about **undoing completed work**, not about **stopping the
process**. Consider a process with two parallel branches: one that handles
payment and another that sends confirmation notifications. If the payment
branch encounters a problem and needs to compensate, the notification branch
might still need to complete (perhaps to send a cancellation notification). The
two concerns are independent.

If you need to stop the entire process when compensation fires, use a Terminate
End Event on a separate path — but that is a distinct modeling decision from
compensation.

### Concrete example

```
                       ┌──▶ [Task X] ──▶ [End Compensate] (compensation fires here)
  [Start] ──▶ [Fork] ─┤
                       └──▶ [Task Y] ──▶ [End Normal]     (continues to completion)
```

When the Compensation End Event on the upper branch fires:

1. Compensation handlers execute for completed tasks on that branch
2. The upper branch's token is consumed (path ends)
3. The lower branch continues running Task Y unaffected
4. Task Y completes and reaches its normal End Event
5. Now all paths have ended → PI terminal state: `:compensated`

The `:compensated` terminal state is applied because at least one path used a
Compensation End Event. If no compensation end was reached, the PI would be
`:finished`.

### When to use a Compensation End Event vs a Throw Event

| Scenario | Use |
|----------|-----|
| Compensate and **continue** doing more work on this path | Compensate Intermediate Throw |
| Compensate and **end this path** — nothing more to do here | Compensate End Event |
| Compensate and **stop the entire process** | Compensate Throw → Terminate End Event (two steps) |

## Scope of Compensation in v1

The current implementation operates within a well-defined scope:

- **Single-process scope.** Compensation targets are resolved within the
  process instance where the compensate event is thrown. A Compensate Throw at
  the top level compensates top-level tasks. A Compensate Throw inside a
  subprocess compensates activities within that subprocess.

- **Embedded subprocesses and call activities are atomic.** When compensating a
  parent scope, completed embedded subprocesses and call activities are treated
  as single units — compensation does not cascade inside them to compensate
  their internal activities.

- **Compensation Event Subprocesses are supported.** You can define an Event
  Subprocess with a Compensation start event that activates when compensation
  is triggered for a specific activity.

- **Transaction Subprocesses and Cancel Events are implemented.** See [Transactions](transactions.md). A Cancel End Event inside a `<bpmn:transaction>` runs automatic LIFO compensation, then the Cancel Boundary on the transaction shell continues the parent. Compensation still does **not** auto-trigger on a Hazard (uncaught error).

## What Does NOT Trigger Compensation

Compensation is **never automatically triggered** by the engine. It requires
explicit placement of a Compensate Throw or End Event in the diagram. In
particular:

| Scenario | Does compensation auto-trigger? | What happens instead |
|----------|:---:|---|
| FNI fatal (handler crash) | No | PI goes `:fatal` — retry the PI to recover |
| PI abort (user/API kill switch) | No | Entire tree aborted — no undo |
| Error End Event | No | PI goes `:error` — catch with an error boundary and route to a compensate event if you want rollback |
| Escalation (uncaught) | No | PI goes `:escalated` — catch with an escalation boundary and route to a compensate event if you want rollback |
| Terminate End Event | No | Remaining FNIs interrupted — no undo |

If you want any of these failure modes to cause compensation, you must model
the path explicitly. The most common pattern:

```
  [Error/Escalation Boundary] ──▶ [Compensate Throw Event] ──▶ [End]
```

## Escalation-Driven Compensation (Worked Example)

Escalation is a non-fatal signal propagated upward through the scope chain.
When caught by a boundary event, it can route to a compensation throw,
creating an "escalation drives rollback" pattern.

```
  ┌─────────────────────────────────────────────────────────────────────┐
  │ Parent Process                                                      │
  │                                                                     │
  │ [Start] ──▶ [Task A] ──▶ [SubProcess] ──────────▶ [End Normal]     │
  │              (compensable)    │                                      │
  │              │                │ escalation boundary                  │
  │              ▼                ▼                                      │
  │         [Handler A]     [Throw Compensation] ──▶ [End Compensated]  │
  └─────────────────────────────────────────────────────────────────────┘
```

1. Task A completes → registered as compensable
2. SubProcess executes → inner flow raises an Escalation Throw Event
3. Escalation boundary on SubProcess catches it
4. Token flows to Compensate Throw Event → compensation fires
5. Handler A runs (undoes Task A's work)
6. Token continues to End Compensated

The BPMN for this pattern:

```xml
<bpmn:boundaryEvent id="BE_Escalation" attachedToRef="SubProcess_1" cancelActivity="true">
  <bpmn:outgoing>Flow_ToCompensate</bpmn:outgoing>
  <bpmn:escalationEventDefinition escalationRef="Escalation_1" />
</bpmn:boundaryEvent>

<bpmn:intermediateThrowEvent id="Throw_Compensation" name="Compensate">
  <bpmn:incoming>Flow_ToCompensate</bpmn:incoming>
  <bpmn:outgoing>Flow_ToEnd</bpmn:outgoing>
  <bpmn:compensateEventDefinition />
</bpmn:intermediateThrowEvent>
```

This is identical to the error-driven Saga pattern but uses escalation
boundaries instead of error boundaries. Choose escalation when the signal
is non-fatal and informational; choose error when it represents a failure.

## Compensation-Start Event Subprocess

An Event Subprocess (ESP) with a Compensation start event acts as a
**scope-level compensation handler**. Instead of defining individual
compensation boundaries and handler activities for each task, you define a
single ESP that handles compensation for the entire scope.

```xml
<bpmn:subProcess id="ESP_Compensation" triggeredByEvent="true">
  <bpmn:startEvent id="ESP_Comp_Start" isInterrupting="true">
    <bpmn:compensateEventDefinition />
  </bpmn:startEvent>
  <!-- inner flow: undo logic for the scope -->
  <bpmn:task id="Task_UndoAll" name="Undo All Work" />
  <bpmn:endEvent id="ESP_Comp_End" />
  <bpmn:sequenceFlow id="SF_1" sourceRef="ESP_Comp_Start" targetRef="Task_UndoAll" />
  <bpmn:sequenceFlow id="SF_2" sourceRef="Task_UndoAll" targetRef="ESP_Comp_End" />
</bpmn:subProcess>
```

When a Compensate Throw or End Event fires in the scope containing this
ESP, the engine triggers the ESP as the scope's compensation handler. The
ESP start is always interrupting — compensation consumes the scope.

**When to use an ESP vs individual handlers:**

| Pattern | Use when |
|---------|----------|
| Individual handlers (`isForCompensation` tasks + associations) | Each task has a distinct undo action; LIFO ordering matters |
| Compensation ESP | Undo logic is complex, shared across tasks, or requires its own subprocess flow |

### ESP Precedence over Boundary Handlers

When a scope contains **both** a Compensation ESP and individual compensation
boundary handlers, the ESP takes precedence for **broadcast** compensation
(no `activityRef`). The engine checks for a compensation ESP first; if one
exists and is armed, it fires the ESP and the individual boundary handlers
are **not** executed.

```
  ┌──────────────────────────────────────────────────────────────────────┐
  │ Process                                                              │
  │                                                                      │
  │ [Start] ──▶ [Task A] ──▶ [Throw Compensation] ──▶ [End]             │
  │              │ comp boundary                                         │
  │              ▼                                                       │
  │         [Handler A]  ◀── NOT executed (ESP wins)                     │
  │                                                                      │
  │ ┌─ ESP (compensation start) ─────────────────────────────────────┐   │
  │ │ [Comp Start] ──▶ [Undo All] ──▶ [ESP End]  ◀── this fires     │   │
  │ └────────────────────────────────────────────────────────────────┘   │
  └──────────────────────────────────────────────────────────────────────┘
```

This is the correct BPMN semantics: the ESP acts as a **scope-level override**
for the compensation mechanism. When you define both patterns in the same
scope, you are saying "use the ESP's centralized logic instead of the
individual handlers."

### Targeted Compensation Skips the ESP

**Targeted** compensation (`activityRef` set) always goes directly to the
boundary handler for the specified activity. The compensation ESP is **not
consulted** — it only responds to broadcast (scope-level) compensation.

```
  ┌──────────────────────────────────────────────────────────────────────┐
  │ [Throw Comp activityRef="Task_A"] ──▶ boundary handler fires        │
  │                                                                      │
  │ ┌─ ESP (compensation start) ─────────────────┐                       │
  │ │ NOT triggered (compensation is targeted)    │                       │
  │ └────────────────────────────────────────────┘                       │
  └──────────────────────────────────────────────────────────────────────┘
```

This ensures that targeted compensation remains surgical: when you specify
exactly which activity to compensate, you get exactly that activity's handler.

### Only Completed Activities Are Compensated

A compensation boundary event is a **passive marker** — it only becomes
relevant after the host activity has successfully completed. The engine
registers an activity in the compensation registry at the moment it finishes
(state `:finished`), not when it starts or while it is waiting.

This means:

- **Running activities** (state `:active`) are not compensated.
- **Waiting activities** (state `:waiting`, e.g., a User Task waiting for
  input) are not compensated.
- **Activities that never executed** (a branch that was never taken) are not
  compensated.

If a compensation throw fires while an activity is still in progress, that
activity's handler is simply not in the compensation registry and is skipped.

```
  ┌──── Parallel Gateway ────┐
  │                          │
  │ [Task A] ──▶ [Comp Throw] ──▶ [End]     (Task A completed → compensable)
  │                                           (but Task A has no handler, so 0 targets)
  │ [User Task B] ──▶ ...                    (still :waiting → NOT compensated)
  │  │ comp boundary + handler               (handler will NOT fire)
  └──────────────────────────┘
```

In this example, the compensation throw fires after Task A completes but
while User Task B is still waiting. Because User Task B has not finished,
it is not in the compensation registry, and its handler does not fire. The
compensation throw resolves 0 targets and passes through as a no-op.

## Best Practices

### Name handlers clearly

Use verb-first names that make the undo action obvious:

- "Cancel Reservation" (not "Reservation Handler")
- "Refund Payment" (not "Payment Compensation")
- "Revert Inventory" (not "Inventory Task")

### Keep handlers idempotent

A compensation handler might be retried if the process instance is retried
after a failure. Design handlers so that running them twice produces the same
result as running them once. For example, use a "cancel if not already
cancelled" pattern rather than assuming the reservation is still active.

### Use targeted compensation for surgical rollback

When only one specific action needs undoing, use `activityRef` to target it
directly. This avoids running handlers for activities that do not need reversal
and makes the process model's intent explicit.

```xml
<bpmn:compensateEventDefinition activityRef="Task_BookFlight" />
```

### Use broadcast compensation for full rollback

When everything that completed so far needs to be undone — the typical Saga
rollback scenario — omit `activityRef` and let the engine compensate all
completed activities in LIFO order.

```xml
<bpmn:compensateEventDefinition />
```

### Place compensation logic on error-handling branches

The most natural home for compensation triggers is after an error boundary:

```
  [SubProcess] ───error boundary───▶ [Throw Compensation] ──▶ [End]
```

This clearly separates the "happy path" from the "rollback path" in your model.

### What if compensation fails?

If a compensation handler itself fails (a handler crashes, a service is
unreachable), the process instance transitions to `:fatal` — not `:compensated`.
You can then retry the process from `:fatal` — the retry mechanism resets the
failed handler and re-runs compensation from where it left off.

The `:compensated` state is **not retryable**. It represents a successful business
outcome: compensation was triggered and all handlers completed successfully. It is
on par with `:finished` and `:escalated` — normal terminal states that do not
indicate a failure.

## Extension Elements Reference

Quick-reference table of all compensation-related BPMN attributes and elements
used by Bifrost Forge World Engine:

| Element | Attribute / Child | Description |
|---------|-------------------|-------------|
| Any activity | `isForCompensation="true"` | Marks the activity as a compensation handler (no sequence flows) |
| `<bpmn:boundaryEvent>` | `<bpmn:compensateEventDefinition>` + `cancelActivity="false"` | Declares the host activity as compensable |
| `<bpmn:association>` | `sourceRef` (boundary event), `targetRef` (handler activity) | Links the compensation boundary to its handler |
| `<bpmn:intermediateThrowEvent>` | `<bpmn:compensateEventDefinition>` | Triggers compensation; flow continues after handlers finish |
| `<bpmn:endEvent>` | `<bpmn:compensateEventDefinition>` | Triggers compensation; current path ends; PI state becomes `:compensated` |
| `<bpmn:compensateEventDefinition>` | `activityRef` (optional) | Targets a specific activity; omit for broadcast (LIFO all) |
| `<bpmn:association>` | `associationDirection="One"` | Standard direction marker (source → target) |

## Related

- [Error End Events](error-end-events.md) — error propagation and PI `:error` state
- [Error Boundary Events](error-boundary-events.md) — catching errors on activities
- [Escalation Events](escalation-events.md) — non-fatal signal propagation
- [Embedded Subprocesses](embedded-subprocesses.md) — subprocess scoping for compensation
- [Event Subprocesses](event-subprocesses.md) — includes Compensation start events
- [Retry](retry.md) — retrying failed compensation runs

# Parallel Gateways

Parallel Gateways (AND-gateways) fork a process into multiple simultaneous paths and later join them back together. The fork activates **all** outgoing paths unconditionally; the join waits for **all** incoming tokens before continuing.

## OR-Fork (Diverging)

A fork gateway has one incoming and multiple outgoing sequence flows. When the token arrives, the engine activates every outgoing path simultaneously — no conditions are evaluated:

```xml
<bpmn:parallelGateway id="Fork_1" name="Start parallel tasks">
  <bpmn:incoming>Flow_In</bpmn:incoming>
  <bpmn:outgoing>Flow_to_task_a</bpmn:outgoing>
  <bpmn:outgoing>Flow_to_task_b</bpmn:outgoing>
  <bpmn:outgoing>Flow_to_task_c</bpmn:outgoing>
</bpmn:parallelGateway>
```

After the fork, three independent flow node instances execute concurrently within the same PI.

## AND-Join (Converging)

A join gateway has multiple incoming and one outgoing sequence flow. It counts the tokens arriving from each incoming flow and fires the outgoing flow only when **all** incoming flows have delivered exactly one token each:

```xml
<bpmn:parallelGateway id="Join_1" name="All tasks done">
  <bpmn:incoming>Flow_from_a</bpmn:incoming>
  <bpmn:incoming>Flow_from_b</bpmn:incoming>
  <bpmn:incoming>Flow_from_c</bpmn:incoming>
  <bpmn:outgoing>Flow_Out</bpmn:outgoing>
</bpmn:parallelGateway>
```

The join is stored in the `gateway_pending_arrivals` table. Each arriving token is recorded, and when the count reaches the required total (one per incoming flow), the join fires.

## Token Merge

When the join fires, it merges all arrived branch payloads using **last-wins per key** (`Map.merge/2`). The order of arrival determines which value wins when two branches set the same key:

```
Branch A token: { "orderId": "123", "processed": true }
Branch B token: { "orderId": "123", "shipped": true }
→ Merged:       { "orderId": "123", "processed": true, "shipped": true }
```

If both branches set the same key to different values, the branch that arrived **last** wins. Design your BPMN so that parallel branches produce non-overlapping keys, or use [Output Mappings](call-activities.md#input-mappings) to rename keys before the join.

## Full BPMN Example

```xml
<!-- Process with parallel task execution and synchronization -->
<bpmn:parallelGateway id="Fork" name="Split">
  <bpmn:incoming>Flow_Start</bpmn:incoming>
  <bpmn:outgoing>Flow_A</bpmn:outgoing>
  <bpmn:outgoing>Flow_B</bpmn:outgoing>
</bpmn:parallelGateway>

<bpmn:serviceTask id="Task_A" name="Charge Payment" implementation="payment">
  <bpmn:incoming>Flow_A</bpmn:incoming>
  <bpmn:outgoing>Flow_A_Done</bpmn:outgoing>
</bpmn:serviceTask>

<bpmn:serviceTask id="Task_B" name="Reserve Stock" implementation="inventory">
  <bpmn:incoming>Flow_B</bpmn:incoming>
  <bpmn:outgoing>Flow_B_Done</bpmn:outgoing>
</bpmn:serviceTask>

<bpmn:parallelGateway id="Join" name="Synchronize">
  <bpmn:incoming>Flow_A_Done</bpmn:incoming>
  <bpmn:incoming>Flow_B_Done</bpmn:incoming>
  <bpmn:outgoing>Flow_Continue</bpmn:outgoing>
</bpmn:parallelGateway>
```

## Mixed Gateways

Gateways with both multiple incoming **and** multiple outgoing flows are **rejected at runtime** with a `mixed_gateway` error. Use separate fork and join nodes for each role:

```xml
<!-- Bad: single gateway acting as both fork and join -->
<bpmn:parallelGateway id="Bad">
  <bpmn:incoming>Flow_1</bpmn:incoming>
  <bpmn:incoming>Flow_2</bpmn:incoming>
  <bpmn:outgoing>Flow_3</bpmn:outgoing>
  <bpmn:outgoing>Flow_4</bpmn:outgoing>
</bpmn:parallelGateway>

<!-- Good: separate fork and join -->
<bpmn:parallelGateway id="Join"> <!-- 2 incoming, 1 outgoing -->
  ...
</bpmn:parallelGateway>
<bpmn:parallelGateway id="Fork"> <!-- 1 incoming, 2 outgoing -->
  ...
</bpmn:parallelGateway>
```

## Parallel vs Inclusive

| Aspect | Parallel Gateway | Inclusive Gateway |
|---|---|---|
| Fork conditions | None — always all paths | FEEL conditions per path |
| Join wait set | Static — all incoming paths | Dynamic — only live upstream paths |
| Branch reaches End Event | Join waits forever (structural error) | Dead-path elimination fires the join |
| Dead path handling | Not applicable | Automatic |

Use a **Parallel Gateway** when you always need all branches to run. Use an **Inclusive Gateway** when conditions determine which branches run, and the join should fire as soon as the live branches complete.

## Interaction with Terminate End Event

A [Terminate End Event](error-handling.md) inside a parallel scope interrupts all remaining FNIs in the same process scope — including branches that have not yet reached the Parallel Join. This is the standard way to abort a parallel execution if one branch determines that the work is no longer needed.

## Interaction with Escalation Boundary Events

A non-interrupting [Escalation Boundary Event](escalation-events.md) can fire on an activity that is running in a parallel branch. The boundary spawns an additional path while the parallel branch continues running. All branches must still deliver tokens to the join before it fires.

## Resume on Restart

Parallel gateways resume correctly after an engine restart:

1. `gateway_pending_arrivals` rows are reloaded from the database and restored to the PI's in-memory state
2. Branches that were still running restart via the standard FNI resume path
3. When all pending arrivals are satisfied (by new arrivals or by already-persisted ones), the join fires normally

## Retry and Checkpoints

| Checkpoint Target | Behavior |
|---|---|
| Parallel Fork FNI | Valid — retrying resets to before the fork |
| Parallel Join FNI | **Invalid** — returns HTTP 422 (`retry_checkpoint_is_join_gateway`); retry from an upstream task instead |

## Error States

| Error | Cause | PI State |
|---|---|---|
| `mixed_gateway` | Gateway has both >1 incoming and >1 outgoing flows | `fatal` |
| `duplicate_join_arrival` | A token arrives at the join from an incoming flow that already delivered one | `fatal` |

## Related

- [Inclusive Gateways](inclusive-gateways.md) — conditional fork + smart join with dead-path elimination
- [Exclusive Gateways](exclusive-gateways.md) — single-path condition routing
- [Event-Based Gateways](event-based-gateways.md) — event-driven first-wins race
- [Embedded Subprocesses](embedded-subprocesses.md) — parallel execution within a subprocess scope
- [Error Handling](error-handling.md) — fatal states and encounter-time validation

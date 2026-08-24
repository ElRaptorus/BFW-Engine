# Transaction Subprocess

A **Transaction Subprocess** (`bpmn:transaction`) is a special form of
[Embedded Subprocess](embedded-subprocesses.md) that adds **atomic
rollback-on-cancel semantics**. When a Cancel End Event fires inside the
transaction, the engine automatically reverses all completed compensable
activities before the parent process continues via the Cancel Boundary.

> **Prerequisite reading.** Transactions depend on Compensation. Before
> modelling a transaction you should understand
> [Compensation](compensation.md), specifically Compensation Boundary Events
> and Compensation Handlers. Cancel-triggered rollback is compensation under
> the hood.

---

## Three Outcomes

Every transaction has exactly three possible outcomes.

### 1. Success

All paths inside the transaction reach End Events normally. The transaction
completes like a regular embedded subprocess. The Cancel Boundary (if present)
is **not** fired — it is only ever triggered by a Cancel End, not by normal
completion.

### 2. Cancel

A Cancel End Event fires inside the transaction. The engine:

1. Finishes the Cancel End FNI.
2. Interrupts every other active/waiting FNI in the transaction scope
   (reason: `cancelled_by_cancel_end`). Running child processes (nested
   subprocesses, call activities) receive a cascade abort.
3. Runs automatic **LIFO compensation** for all completed compensable activities
   in the transaction scope — the last activity to complete is compensated first.
   This uses the same [Compensation](compensation.md) infrastructure.
4. Transitions the transaction's child process instance to **`:cancelled`**.
5. Fires the Cancel Boundary on the transaction shell. The parent process
   continues via the Cancel Boundary's outgoing flow.

If there are no completed compensable activities, steps 3 and 4 are skipped
and the child PI transitions to `:cancelled` immediately.

### 3. Hazard

An error propagates out of the transaction without being caught by an Error
Boundary inside the transaction. The child process instance transitions to
`:fatal`. Compensation does **not** run automatically — this is intentional
per BPMN 2.0 §13.4.6. The parent process instance also fatals (unless it has
its own error boundary on the transaction shell).

> **Important:** If you want errors to trigger compensation, model it yourself.
> Place an Error Boundary *inside* the transaction that catches the error and
> routes to a Cancel End Event. That Cancel End then triggers the automatic
> rollback. Do not rely on the hazard path for compensation.

---

## Key Rules

### Cancel Boundary is Required (in Practice)

A Cancel Boundary Event is the only thing that can catch a `:cancelled`
transaction. If there is no Cancel Boundary on the transaction shell, a
Cancel End inside the transaction causes the parent process to fatal
(unhandled cancel = hazard outcome).

The engine does not enforce this at deploy time, but the linter will warn
you about a transaction without a Cancel Boundary.

### Cancel Boundary is Always Interrupting

You cannot make a Cancel Boundary non-interrupting. It is always interrupting.
This is a BPMN 2.0 spec constraint.

### One Cancel Boundary Per Transaction

At most one Cancel Boundary may be attached to a transaction shell. Duplicate
Cancel Boundaries are rejected at deploy time.

### No Nested Transactions

A `bpmn:transaction` may contain embedded subprocesses and call activities,
but not another `bpmn:transaction`. Nested transactions are rejected at deploy
time (`nested_transaction` validation error). This is a v1 restriction.

### Hazard Does Not Trigger Compensation

Only Cancel End triggers automatic compensation. A fatal error inside a
transaction is a hazard — no compensation runs. See §3 above.

---

## Modelling Example

Below is the pattern for a transaction with two compensable activities and a
Cancel End:

```
Transaction Shell (double border)
├── Start
├── Task_A  ──── Compensation Boundary ──► Comp_A (compensation handler)
├── Task_B  ──── Compensation Boundary ──► Comp_B (compensation handler)
├── [normal path] → End_Success
└── [cancel path] → Cancel End
    │
    └── Cancel Boundary on Transaction Shell ──► End_Cancelled
```

When the cancel path fires:
1. Cancel End interrupts Task_A and Task_B if still running.
2. If both completed, Comp_B runs first (LIFO), then Comp_A.
3. Cancel Boundary fires, parent continues at End_Cancelled.

For error recovery within the transaction that leads to cancel:

```
Transaction Shell (double border)
├── Start
├── Task_A  ──── Compensation Boundary ──► Comp_A
├── Service_X
│   └── Error Boundary ──────────────────► [recovery path] ──► Cancel End
└── [happy path] → End_Success
    │
    └── Cancel Boundary on Transaction Shell ──► End_Cancelled
```

Here a service failure is caught inside the transaction and deliberately
converted into a cancel (with compensation).

---

## Process Instance State

A successfully cancelled transaction produces a child process instance in
state **`:cancelled`**. This state:

- Appears in `ProcessInstanceStateChanged` events with `newState: "cancelled"`.
- Is visible in the Studio Debugger with a distinct colour.
- Is **not retryable** (see [Retry](retry.md)).
  A cancel is an intentional business outcome, not a failure.

---

## Retry Restrictions

Transactions impose strict retry rules to preserve atomicity:

| Scenario | Retry result |
|----------|--------------|
| Retry a `:cancelled` child PI directly | 422 `process_instance_not_retriable` |
| Retry a child PI nested below a transaction (direct or transitively) | 422 `retry_inside_transaction_scope` |
| Use a checkpoint (`resetToFlowNodeInstanceId`) that points inside the transaction | 422 `retry_checkpoint_inside_transaction` |
| Retry the parent process from upstream of the transaction | Allowed |

The reasoning: once a transaction is part of the process tree, all nested
process instances are part of the atomic scope. Retrying one piece would
violate transactional atomicity. Always retry from the transaction shell
itself or further upstream.

---

## Observability

The engine emits a `TransactionCancelled` event after all automatic
compensation handlers complete and the child PI is about to transition to
`:cancelled`:

```json
{
  "type": "TransactionCancelled",
  "data": {
    "processInstanceId": "...",
    "rootProcessInstanceId": "...",
    "transactionNodeId": "Transaction_1",
    "compensationHandlerCount": 2,
    "occurredAt": "2026-07-12T10:00:00Z"
  }
}
```

`compensationHandlerCount` is the number of compensation handlers that ran
(0 if no completed compensable activities were present when the cancel fired).

---

## Relation to Compensation

Cancel-triggered compensation is the same mechanism as explicit compensation
([Compensation Handlers](compensation.md#compensation-handlers)). The only
difference is the trigger:

| Trigger | How compensation runs |
|---------|----------------------|
| Compensate Throw Event | Explicit, modeller-driven, targets a specific activity or broadcasts |
| Cancel End Event | Automatic, always broadcasts all completed compensable activities in the transaction scope (LIFO) |

Both use the same `CompensationOrchestrator` and the same
[Compensation Boundary Events](compensation.md#compensation-boundary-event).

---

## Common Mistakes

**1. Expecting compensation on hazard.**
An uncaught error inside a transaction is a hazard — compensation does not
run. Wire an Error Boundary inside the transaction and route to a Cancel End
if you want automatic rollback on error.

**2. Forgetting the Cancel Boundary.**
Without a Cancel Boundary on the transaction shell, a Cancel End causes the
parent process to fatal. The linter will warn; the engine will fatal at runtime.

**3. Retrying a nested PI.**
Retrying a process instance that lives below a transaction is rejected.
Always retry from the transaction shell or upstream.

**4. Placing compensation handlers outside the transaction.**
Compensation during cancel only considers activities completed within the
transaction scope. Compensation Boundaries on activities in the parent scope
are not triggered by the transaction cancel.

---

## Related Topics

- [Compensation](compensation.md) — prerequisite; cancel-triggered compensation
  uses the same mechanism
- [Embedded Subprocesses](embedded-subprocesses.md) — transaction is a
  subprocess variant
- [Error Boundary Events](error-boundary-events.md) — for catching errors
  inside a transaction before they become hazards
- [Retry](retry.md) — retry restrictions for transactions

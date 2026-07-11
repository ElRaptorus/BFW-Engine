---
title: Transaction Subprocess + Cancel Events — Implementation Plan
date: 2026-07-10
status: PENDING APPROVAL
---

# Transaction Subprocess + Cancel Events

**Goal:** Implement `bpmn:transaction`, Cancel End Event, and Cancel Boundary Event — turning the existing embedded-subprocess + compensation infrastructure into a transactional scope with automatic rollback-on-cancel semantics.

---

## 0. User Assessment Verification

The user's initial assessment is largely correct, with a few important nuances from the BPMN 2.0 spec (OMG §10.4.3, §10.5.4, §13.4.6):

### Correct

- **Transaction ≈ Embedded Subprocess + "All-Or-Nothing"** — Transactions extend `SubProcess` (double-border visual) and add rollback-on-cancel semantics. Successful completion works exactly like a normal embedded subprocess.
- **Cancel End Event ≈ Terminate End Event within the transaction** — Cancel End interrupts all running activities in the transaction scope, then triggers compensation for all completed activities (LIFO), then fires the Cancel Boundary on the transaction shell.
- **Cancel Boundary only on Transaction; Cancel End only inside Transaction** — Strict positional rules per spec. Cancel Boundary is always interrupting and singular (at most one per Transaction).
- **Retry from outside, never within** — Once a transaction is cancelled and compensation runs, the internal state is "rolled back." Retry must target the Transaction shell or a node upstream of it.

### Nuances

1. **Three outcomes, not two.** BPMN 2.0 defines three distinct outcomes for a Transaction:
   - **Success**: All paths reach end events normally → Transaction completes like a normal subprocess. Cancel Boundary is NOT fired.
   - **Cancel**: A Cancel End Event fires → automatic LIFO compensation of completed activities → Cancel Boundary fires → parent process continues via boundary outgoing flow.
   - **Hazard**: An uncaught error/fault propagates out of the transaction → Transaction goes fatal. **Compensation does NOT auto-run.** The error propagates to the parent's error boundary (if any) or fatals the parent. This is counter-intuitive but spec-correct: "hazard" means something went so wrong that even compensation cannot be trusted.

2. **`method` attribute.** BPMN 2.0 defines a `method` attribute on Transaction for protocol URIs (WS-AT, WS-BA). No mainstream engine implements wire-level protocol integration — Camunda, Flowable, and jBPM all treat it as saga-pattern compensation. We parse but ignore it.

3. **Nested transactions.** The spec allows transactions within transactions. For v1, we defer this — a Transaction may contain embedded subprocesses and call activities, but not nested transactions. Deploy-time validator rejects nested `bpmn:transaction`.

---

## 1. Identified Pitfalls

| # | Pitfall | Mitigation |
|---|---------|------------|
| P1 | **Hazard ≠ Cancel.** Uncaught error inside a transaction does NOT trigger compensation — only Cancel End does. Users will expect automatic compensation on error. | Clear documentation, linter hints. Error boundaries inside transactions catch errors without cancelling. An error End Event inside a transaction is a hazard, not a cancel. |
| P2 | **Compensation scope isolation.** When Cancel fires, compensation must run ONLY for activities completed within the transaction scope, not parent-scope activities. The compensation registry must be scoped to the child PI. | The child PI already maintains its own `compensation_registry`. This is naturally scoped. No parent-scope contamination. |
| P3 | **Cancel vs Abort confusion.** Cancel is a BPMN-modeled business event. Abort is an API-level kill switch. They must not be confused in state names, events, or diagnostics. | Cancel End → child PI state `:cancelled` (new terminal state). API abort → `:aborted` (existing). Distinct state atoms, distinct event bus events. |
| P4 | **Cancel Boundary is reactive, not pre-spawned.** Unlike timer/message boundaries, the Cancel Boundary fires only when the Transaction's child PI reports cancellation. It should NOT be pre-spawned as a subscription. | Model it like Error Boundary: the handler awaits child completion, matches the cancel result against the Cancel Boundary, and returns `{:boundary, ...}`. |
| P5 | **Compensation failure during cancel.** If a compensation handler fatals during the automatic compensation triggered by Cancel End, the transaction hazards (goes fatal) instead of completing the cancel path. | Document this. The compensation orchestrator already handles handler fatals by transitioning to fatal. |
| P6 | **Cancel propagation to nested scopes.** If the transaction contains running embedded subprocesses or call activities when Cancel End fires, those must be interrupted first (like Terminate End Event), then compensation runs for completed activities. | Reuse `interrupt_remaining_fnis` (already handles child PI cascade via `handle_aborted/1` callbacks). |
| P7 | **Retry checkpoint restriction.** `resetToFlowNodeInstanceId` must never point to an FNI inside a transaction scope. Retry from within a transaction breaks atomicity. | Add validation in `execute_retry_reset` (or `validate_checkpoint`) that rejects checkpoints inside a transaction. |
| P8 | **Cancel Boundary Event definition has no fields.** Unlike Error Boundary (which matches by error code), Cancel Boundary has no discriminator — there's only ever one, and it catches any cancel from the transaction. | Simple: if the transaction shell has a Cancel Boundary, the cancel is caught. If not, the cancel propagates as a hazard (fatal). Decision needed: is a Cancel Boundary required on a Transaction? Spec says no, but without one, a Cancel End is pointless. Linter should warn. |
| P9 | **Multiple Cancel End Events.** A transaction can have Cancel End Events on different branches. Only one can fire (since cancel interrupts all siblings). Second-fire must be a no-op. | Same idempotency pattern as Terminate End Event: the first cancel wins, subsequent cancel attempts on an already-cancelling transaction are absorbed. |
| P10 | **Resume of mid-cancel transaction.** If the engine restarts while compensation is running during a cancel, the transaction's child PI must resume the compensation run from its persisted cursor. | Already handled by existing compensation resume infrastructure (cursor in `type_properties`). |

---

## 2. Design Decisions

| ID | Decision | Rationale |
|----|----------|-----------|
| TX-D1 | **Transaction is a SubProcess variant, not a separate type.** Parser maps `bpmn:transaction` to `:sub_process` with `is_transaction: true` on `FlowNodeData.SubProcess`. Handler routing in `SubProcess.handle_enter` branches on this flag to use `TransactionSubProcess` handler. | Reuses 95% of the embedded subprocess infrastructure. ModelCache synthetic-model, boundary orchestration, resume, and retry all work out of the box. Mirrors how ESP was added (`triggered_by_event: true`). |
| TX-D2 | **New PI terminal state: `:cancelled`.** When a child PI is cancelled (via Cancel End Event), it transitions to `:cancelled`. The Transaction handler maps this to a Cancel Boundary catch. This is distinct from `:aborted` (API kill switch) and `:compensated` (explicit compensation throw/end). | Clean state semantics. `:cancelled` = modeled business cancellation within a transaction. `:aborted` = external kill. `:compensated` = explicit compensation outside a transaction. |
| TX-D3 | **Cancel End fires compensation automatically within the child PI.** The sequence is: (1) Cancel End handler returns `{:cancel, result}` to the child PI, (2) child PI interrupts all remaining FNIs, (3) child PI runs LIFO compensation for all completed activities using the existing orchestrator, (4) child PI transitions to `:cancelled` and notifies parent, (5) Transaction handler matches Cancel Boundary and returns `{:boundary, ...}`. | Compensation runs inside the child PI's scope (correct scoping). The parent only sees the final `:cancelled` state. |
| TX-D4 | **Cancel Boundary is reactive (Error-model), not subscription-based (Timer/Message-model).** The Transaction handler Task awaits `{:child_pi_cancelled, ...}` and routes through `BoundaryResolver.find_matching_cancel_boundary`. | Cancel is deterministic and internal — there's no external event source to subscribe to. Same pattern as Error Boundary on Call Activity / Embedded Subprocess. |
| TX-D5 | **No nested transactions in v1.** Deploy-time validator rejects `bpmn:transaction` inside another `bpmn:transaction`. Embedded subprocesses and call activities inside a transaction are fine — they are compensated as atomic units (COMP-D8). | Nested transactions add complexity with little practical value. The spec allows them but no mainstream engine supports them well. |
| TX-D6 | **`method` attribute parsed and stored but not executed.** No wire-level transaction protocol integration. | Matches Camunda, Flowable, jBPM. The attribute is preserved in the model for BPMN fidelity. |
| TX-D7 | **Hazard (uncaught error) does NOT trigger compensation.** An error that propagates out of the transaction without being caught by an error boundary fatals the child PI. No compensation runs. The parent sees `{:child_pi_fatal, ...}`, same as any other subprocess fatal. | Spec-correct (BPMN 2.0 §13.4.6). If compensation is desired on error, the modeler should wire an Error Boundary inside the transaction that routes to a Compensate Throw before the Cancel End. |
| TX-D8 | **Retry restrictions: no checkpoint inside a transaction scope.** `resetToFlowNodeInstanceId` pointing to an FNI inside a `:cancelled` transaction is rejected with `retry_checkpoint_inside_transaction`. | Atomicity: once cancelled and compensated, the transaction's inner state is logically rolled back. Retrying from within would violate that invariant. |
| TX-D9 | **`:cancelled` is NOT retryable.** Like `:compensated` and `:escalated`, a `:cancelled` PI represents a handled business outcome, not a failure. The parent process continues via the Cancel Boundary. | Consistent with the "terminal-but-handled" family of states. The parent can still be retried if IT fails. |

---

## 3. Engine Implementation

### Phase E1 — Parser + Types

- [ ] **E1.1** Add `"transaction"` to `@flow_node_elements` in `sax_handler.ex`, mapping to `{:sub_process, FlowNodeData.SubProcess}` (same struct as embedded subprocess)
- [ ] **E1.2** Add `is_transaction: false` field to `FlowNodeData.SubProcess` defstruct (default `false`, set to `true` when element is `"transaction"`)
- [ ] **E1.3** Parse the `method` attribute from `<bpmn:transaction method="...">` and store it on `FlowNodeData.SubProcess` as `transaction_method: nil | String.t()`
- [ ] **E1.4** Add `"transaction"` to the TypeScript SDK parser (`packages/js/sdk/src/bpmn/parser.ts`) in `FLOW_NODE_TAGS`, mapping to `sub_process` with `isTransaction: true`
- [ ] **E1.5** Add parser unit tests: `bpmn:transaction` parsed as `:sub_process` with `is_transaction: true`; `method` attribute captured; inner flow nodes accessible; existing `bpmn:subProcess` still has `is_transaction: false`

### Phase E2 — Validator

- [ ] **E2.1** Add `check_cancel_transaction_scope/1` validator rule: Cancel End Event must be inside a Transaction subprocess scope; Cancel Boundary Event's `attachedToRef` must point to a Transaction subprocess. Violation atoms: `:cancel_end_outside_transaction`, `:cancel_boundary_not_on_transaction`
- [ ] **E2.2** Add `check_nested_transactions/1` validator rule: Reject `bpmn:transaction` inside another `bpmn:transaction` (recursively). Violation atom: `:nested_transaction`
- [ ] **E2.3** Add transaction-specific structural validation inside `validate_subprocess_structure` (recursive): Transaction subprocess follows the same inner-scope rules as embedded subprocess (one None Start, no typed starts, at least one End Event), plus optionally may contain Cancel End Events
- [ ] **E2.4** Validator unit tests: Cancel End outside transaction → violation; Cancel Boundary on non-transaction → violation; Cancel End inside transaction → valid; nested transaction → violation; Transaction with Cancel End + Cancel Boundary → valid

### Phase E3 — New PI State `:cancelled`

- [ ] **E3.1** Add `:cancelled` to the PI state enum in the persistence schema (migration + Ash resource)
- [ ] **E3.2** Add `notify_parent(data, :cancelled)` in `process_instance.ex` → sends `{:child_pi_cancelled, pid, final_tokens}` to parent handler Task
- [ ] **E3.3** Add `:cancelled` to terminal-state checks in `maybe_finish/1` and `maybe_finish_or_continue/1`
- [ ] **E3.4** Ensure `:cancelled` is NOT in `@retriable_pi_states` (like `:compensated` and `:escalated`)
- [ ] **E3.5** Add `"cancelled"` to the `ProcessInstanceState` enum in the TypeScript SDK
- [ ] **E3.6** Add `ProcessInstanceStateChanged` event handling for `cancelled` state
- [ ] **E3.7** Wire `"cancelled"` through the JSON wire contract (camelCase) and WebSocket events
- [ ] **E3.8** Unit tests: PI transitions to `:cancelled`; `:cancelled` is not retriable

### Phase E4 — Cancel End Event Handler

- [ ] **E4.1** Create `FlowNodes.CancelEndEvent` handler module
  - `handle_enter/3`: Validates it is inside a transaction scope (runtime guard). Returns `{:cancel, %FlowNodeResult{}}` — a new tuple tag recognized by the PI state machine
  - `handle_fatal/1`, `handle_aborted/1`: No-ops (same as other end events)
- [ ] **E4.2** Update `HandlerDispatch.resolve_handler/1`: Route `%EventDefinition.Cancel{}` on `:end_event` to `FlowNodes.CancelEndEvent` (replace the `:unsupported_event_definition` catch-all)
- [ ] **E4.3** Add `handle_fni_cancel/3` to the PI state machine:
  1. Finish the Cancel End FNI via `do_handle_fni_ok`
  2. Call `interrupt_remaining_fnis(data, fni_id, :cancelled_by_cancel_end)`
  3. Run LIFO compensation for all entries in `compensation_registry` using existing `CompensationOrchestrator.build_run/4` (broadcast mode, no `activityRef`)
  4. After compensation completes: transition PI to `:cancelled`, persist, emit events, notify parent
- [ ] **E4.4** Handle the case where compensation_registry is empty (no completed compensable activities): skip compensation, go directly to `:cancelled`
- [ ] **E4.5** Handle compensation failure during cancel: if a compensation handler fatals, the child PI transitions to `:fatal` instead of `:cancelled` (hazard outcome)
- [ ] **E4.6** Handle idempotency: if Cancel End fires on an already-cancelling PI (e.g. parallel branches both reaching Cancel End), the second fire is a no-op
- [ ] **E4.7** Remove or update the existing `handler_dispatch_test.exs` test that expects Cancel End to return `:unsupported_event_definition`
- [ ] **E4.8** Unit tests for `CancelEndEvent` handler: returns `{:cancel, ...}`; runtime guard rejects Cancel End outside transaction

### Phase E5 — Transaction SubProcess Handler

- [ ] **E5.1** Create `FlowNodes.TransactionSubProcess` handler module, or extend `SubProcess` with a `handle_enter` branch for `is_transaction: true`

  **Decision needed from user:** Should Transaction be a separate handler module (`FlowNodes.TransactionSubProcess`) or a branch inside the existing `FlowNodes.SubProcess`?

  *Recommendation:* Separate module. The `SubProcess` module is already complex (1000+ lines) with ESP logic. Adding cancel-compensation orchestration would push it further. A separate module can delegate shared lifecycle functions to a `SubProcess.Shared` helper module (extracted from the current `SubProcess`).

- [ ] **E5.2** `handle_enter/3`: Same as `SubProcess.handle_enter` but with Transaction-aware child lifecycle:
  - Runtime validation: same as embedded subprocess (one None Start, at least one End)
  - Input mappings, payload contract, child PI start: identical
  - Child completion await: extended with `{:child_pi_cancelled, ...}` handling

- [ ] **E5.3** `await_child_completion/6` extension — add clause for `{:child_pi_cancelled, ^child_pid, final_tokens}`:
  - Find Cancel Boundary on the transaction shell via `BoundaryResolver`
  - If found: return `{:boundary, cancel_boundary_node_id, cancel_token, true}` (always interrupting)
  - If not found: return `{:error, %{reason: :unhandled_cancel, ...}}` → parent PI fatals (hazard)

- [ ] **E5.4** `handle_fatal/1`, `handle_aborted/1`: Same cascade as `SubProcess` (kill child)

- [ ] **E5.5** `handle_resume/3`: Branch on `is_transaction` to use Transaction-specific lifecycle (same child PI resume logic, but with cancel-aware await)

- [ ] **E5.6** `ModelCache` update: `find_subprocess_node` must also match `is_transaction: true` subprocess nodes for synthetic-model generation (verify current code handles this — it matches on `type: :sub_process` which should already work)

- [ ] **E5.7** Unit tests: Transaction handler spawns child PI; Cancel Boundary catches child cancellation; no Cancel Boundary → parent fatal; resume mid-transaction

### Phase E6 — Cancel Boundary Event Handler

- [ ] **E6.1** Create `FlowNodes.CancelBoundaryEvent` handler module (thin pass-through, like `CompensationBoundaryEvent`)
  - This handler should never be directly dispatched — Cancel Boundary is reactive, resolved by the Transaction handler
  - `handle_enter/3`: returns `{:error, :cancel_boundary_not_dispatched}` (safety guard)
- [ ] **E6.2** Update `HandlerDispatch.resolve_handler/1`: Route `%EventDefinition.Cancel{}` on `:boundary_event` to `FlowNodes.CancelBoundaryEvent` (replace the `:unsupported_event_definition` catch-all)
- [ ] **E6.3** Update `BoundaryOrchestrator.resolve_subscription_boundaries/3`: Filter out `:cancel` event definitions alongside `:compensation` (cancel boundaries are reactive, not subscription-based)
- [ ] **E6.4** Add `find_matching_cancel_boundary/2` to `BoundaryResolver` (or use existing generic boundary matching — Cancel has no discriminator field, just check for `%EventDefinition.Cancel{}` on the host's boundary events)
- [ ] **E6.5** Unit tests: Cancel boundary not pre-spawned; boundary resolver finds Cancel Boundary on transaction shell

### Phase E7 — Retry Restrictions

- [ ] **E7.1** Add `:cancelled` to the non-retriable state list in `api.ex` and `execution.ex` (alongside `:compensated`, `:escalated`, `:finished`)
- [ ] **E7.2** Add transaction-scope checkpoint validation: `resetToFlowNodeInstanceId` must not point to an FNI whose scope is inside a `:cancelled` Transaction. Error code: `retry_checkpoint_inside_transaction`
- [ ] **E7.3** Integration test: Attempt to retry a `:cancelled` PI → 422 `process_instance_not_retriable`
- [ ] **E7.4** Integration test: Attempt to checkpoint-retry inside a transaction → 422 `retry_checkpoint_inside_transaction`

### Phase E8 — Events + Observability

- [ ] **E8.1** Add `Event.TransactionCancelled` event struct to `core_types`: `{process_instance_id, root_process_instance_id, transaction_node_id, compensation_handler_count, occurred_at}`
- [ ] **E8.2** Emit `TransactionCancelled` when a child PI transitions to `:cancelled` (from `handle_fni_cancel` after compensation completes)
- [ ] **E8.3** Add `ProcessInstanceStateChanged` emission for `:cancelled` state transitions (already handled generically by `persist_pi_*` if wired correctly)
- [ ] **E8.4** Add `[:evil_engine, :transaction, :cancelled]` telemetry event
- [ ] **E8.5** Update the TypeScript SDK event types to include `TransactionCancelled`
- [ ] **E8.6** Wire `TransactionCancelled` through WebSocket sink and root-PI fan-out

### Phase E9 — BPMN Test Fixtures

- [ ] **E9.1** `transaction_happy_path.bpmn` — Transaction with Task_A (compensable) → Task_B → End. No cancel. Succeeds normally
- [ ] **E9.2** `transaction_cancel_basic.bpmn` — Transaction with Task_A (compensable) → Cancel End. Cancel Boundary on shell → End_Cancelled
- [ ] **E9.3** `transaction_cancel_with_compensation.bpmn` — Transaction with Task_A (compensable, handler Task_Comp_A) → Task_B (compensable, handler Task_Comp_B) → Cancel End. Verify LIFO: Comp_B runs first, then Comp_A. Cancel Boundary → End
- [ ] **E9.4** `transaction_hazard_error.bpmn` — Transaction with a ScriptTask that fatals. No error boundary inside. Transaction hazards → parent fatals (no compensation)
- [ ] **E9.5** `transaction_error_boundary_inside.bpmn` — Transaction with Task → Error End. Error boundary INSIDE the transaction catches it, routes to Cancel End. Cancel Boundary on shell → End
- [ ] **E9.6** `transaction_no_cancel_boundary.bpmn` — Transaction with Cancel End, but no Cancel Boundary on the shell. Cancel → parent hazards (fatal)
- [ ] **E9.7** `transaction_with_call_activity.bpmn` + child BPMN — Transaction containing a Call Activity. Cancel interrupts the CA and its child PI
- [ ] **E9.8** `transaction_with_embedded_subprocess.bpmn` — Transaction containing an embedded subprocess. Cancel interrupts the subprocess
- [ ] **E9.9** `transaction_parallel_cancel.bpmn` — Transaction with parallel branches, one reaching Cancel End. Other branch interrupted, compensation runs
- [ ] **E9.10** `transaction_cancel_compensation_fails.bpmn` — Transaction where a compensation handler fatals. Transaction hazards instead of cancelling

### Phase E10 — Integration Tests

- [ ] **E10.1** `TX-1`: Happy path — Transaction succeeds, Cancel Boundary NOT fired, PI finishes normally
- [ ] **E10.2** `TX-2`: Basic cancel — Cancel End fires, compensation runs (LIFO), Cancel Boundary fires, parent continues
- [ ] **E10.3** `TX-3`: Cancel with multiple compensable activities — verify LIFO ordering
- [ ] **E10.4** `TX-4`: Hazard — uncaught error inside transaction, NO compensation, parent fatals
- [ ] **E10.5** `TX-5`: Error boundary inside transaction routes to Cancel End
- [ ] **E10.6** `TX-6`: No Cancel Boundary on shell → parent hazards (fatal)
- [ ] **E10.7** `TX-7`: Transaction with Call Activity — cancel interrupts child PI
- [ ] **E10.8** `TX-8`: Transaction with embedded subprocess — cancel interrupts child PI
- [ ] **E10.9** `TX-9`: Parallel branches — one cancels, other interrupted
- [ ] **E10.10** `TX-10`: Compensation handler fatals during cancel → hazard
- [ ] **E10.11** `TX-11`: `:cancelled` PI is not retryable
- [ ] **E10.12** `TX-12`: Retry checkpoint inside transaction → rejected

### Phase E11 — Conformance Specs (YAML)

- [ ] **E11.1** C230–C241: One YAML spec per fixture (tier: auto for simple, tier: interactive for multi-step)

### Phase E12 — Documentation

- [ ] **E12.1** Update `AGENTS.md`:
  - Add `bpmn:transaction` to Supported BPMN Element Types (Activities table) with `is_transaction` flag
  - Add Cancel End Event and Cancel Boundary Event to the position rules table
  - Add TX-D1 through TX-D9 decisions
  - Document `:cancelled` PI state
  - Update "PI Terminal State" section
- [ ] **E12.2** Update `docs/architecture/execution.md`:
  - New section: "Transaction Subprocess"
  - Document the three outcomes (success, cancel, hazard)
  - Document `:cancelled` state and compensation-during-cancel flow
  - Update PI terminal state table
  - Update retry restrictions
- [ ] **E12.3** Update `docs/ImplementationPlan.md`:
  - Add TX-D1 through TX-D9 to decision table
  - Update §7 Cancel Events section with implementation notes
- [ ] **E12.4** Update `docs/ImplementationPhases.md`:
  - Mark Phase 5.4 as DONE
- [ ] **E12.5** Create user handbook: `docs/guides/handbook/transactions.md`
  - Three outcomes with examples
  - Cancel + Compensation flow
  - Hazard behavior (why errors don't auto-compensate)
  - Combined patterns (Error → Cancel, Escalation → Cancel)
  - Retry restrictions
  - Limitations (no nested transactions)
- [ ] **E12.6** Update `docs/guides/handbook/compensation.md`:
  - Add section on "Compensation within Transactions" explaining that Cancel End auto-triggers compensation
  - Reference the transaction handbook

---

## 4. Studio Implementation

### Phase S1 — SDK Types

- [ ] **S1.1** Add `BpmnElement_Transaction` type to `studio-sdk/types/bpmn/BpmnElementTypes.ts` (extends SubProcess properties + `transactionMethod?: string`)
- [ ] **S1.2** Add `BpmnElement_CancelEndEvent` and `BpmnElement_CancelBoundaryEvent` types (minimal — no custom properties beyond generic)
- [ ] **S1.3** Add `ProcessInstanceState.Cancelled` to the SDK state enum (if not already present)
- [ ] **S1.4** Add `TransactionCancelled` event type to the SDK event types
- [ ] **S1.5** Rebuild SDK, verify type-check passes

### Phase S2 — Debugger Updates

- [ ] **S2.1** Add `:cancelled` state color to `EngineDebugger.scss` — use a distinct color (e.g. a muted red-orange or similar to distinguish from `:aborted`)
- [ ] **S2.2** Add `cancelled` case to `OverlayFactory.ts` state-to-overlay mapping
- [ ] **S2.3** Ensure `cancelled` appears correctly in `InstanceSearchRenderer.tsx` state filters
- [ ] **S2.4** Ensure `TransactionCancelled` event is handled in `EngineAdapter.ts` / `SubscribeThenSnapshot.ts`
- [ ] **S2.5** Ensure `:cancelled` PIs are NOT shown with retry overlay (`shouldDisplayRetryOverlay`)

### Phase S3 — Editor Panes

- [ ] **S3.1** Create `PropertiesTransaction.tsx` pane — display `method` attribute (read-only info), inner scope summary
- [ ] **S3.2** Create `PropertiesCancelEndEvent.tsx` pane — minimal, info text explaining behavior
- [ ] **S3.3** Create `PropertiesCancelBoundaryEvent.tsx` pane — minimal, info text
- [ ] **S3.4** Register all three panes in `initializeBpmnPanes.ts`
- [ ] **S3.5** Update help markdown files to remove "Not executed by the current Engine" warnings
- [ ] **S3.6** Add missing SVG assets for help files (Transaction.svg, CancelEndEvent.svg)

### Phase S4 — Popup/Palette Adjustments

- [ ] **S4.1** Update `CustomPopupProvider.ts` to NOT filter out `replace-with-transaction` entry (currently the test expects it to be dropped — fix the test)
- [ ] **S4.2** Ensure `bpmn:Transaction` is handled in `CustomPaletteProvider.ts` canvas root check (alongside `bpmn:SubProcess`)

### Phase S5 — Linter Rule Updates

- [ ] **S5.1** Verify `cancel-event-transaction-scope` rule still works correctly (it should — it's forward-compatible)
- [ ] **S5.2** Add linter rule: warn when a Transaction has Cancel End but no Cancel Boundary (useless cancel)
- [ ] **S5.3** Add linter rule: warn when a Transaction has no compensable activities (cancel will have no effect)

### Phase S6 — Engine Model Viewer

- [ ] **S6.1** Add Transaction-specific display in model viewer panes (show `is_transaction` flag, `method`)
- [ ] **S6.2** Ensure Cancel End / Cancel Boundary display correctly

### Phase S7 — Build & Verify

- [ ] **S7.1** `npm run build` — TypeScript compilation
- [ ] **S7.2** `npm run lint:fix` — ESLint
- [ ] **S7.3** `npm run format` — Prettier
- [ ] **S7.4** Fix the `CustomPopupProvider.test.ts` test that expects `replace-with-transaction` to be dropped

---

## 5. Architecture: Responsibility Boundaries

### What the Cancel End Event handler does
- Validates it is inside a transaction scope (runtime guard)
- Returns `{:cancel, %FlowNodeResult{}}` to the PI

### What the PI state machine does on `{:cancel, ...}`
1. Finishes the Cancel End FNI (via `do_handle_fni_ok`)
2. Interrupts all remaining active/waiting FNIs (via `interrupt_remaining_fnis`)
3. Triggers automatic LIFO compensation using existing `CompensationOrchestrator`
4. After compensation completes: sets `cancel_reached` flag
5. In `maybe_finish/1`: if `cancel_reached`, transitions to `:cancelled`
6. `notify_parent` sends `{:child_pi_cancelled, ...}`

### What the Transaction handler does
- Runs the SubProcess child lifecycle
- Awaits `{:child_pi_cancelled, ...}` (in addition to existing finish/fatal/error/abort/escalation messages)
- On cancel: resolves Cancel Boundary via `BoundaryResolver`, returns `{:boundary, ...}` to parent PI
- On no Cancel Boundary: returns `{:error, :unhandled_cancel}` → parent PI fatals

### What the Cancel Boundary handler does
- Nothing at runtime (reactive — resolved by Transaction handler)
- Safety guard: `handle_enter` returns error if somehow directly dispatched

### What `BoundaryOrchestrator` does
- Filters out Cancel Boundaries from subscription pre-spawn (alongside Compensation Boundaries)

### What `CompensationResolver` / `CompensationOrchestrator` do
- Unchanged — reused as-is for automatic compensation during cancel

---

## 6. State Flow Diagrams

### Cancel Path (happy)
```
Cancel End fires
  → PI: handle_fni_cancel
    → interrupt remaining FNIs (`:cancelled_by_cancel_end`)
    → build compensation run (LIFO, all completed activities)
    → dispatch compensation handlers sequentially
    → all handlers finish
    → PI state → :cancelled
    → notify_parent({:child_pi_cancelled, final_tokens})
  → Transaction handler: await_child_completion
    → receive {:child_pi_cancelled, ...}
    → find Cancel Boundary on shell
    → return {:boundary, cancel_boundary_id, cancel_token, true}
  → Parent PI: dispatch boundary outgoing flow
    → process continues normally
```

### Hazard Path (error propagates out)
```
Uncaught error inside transaction
  → child PI: :fatal (no compensation)
  → notify_parent({:child_pi_fatal, reason})
  → Transaction handler: await_child_completion
    → receive {:child_pi_fatal, ...}
    → check Error Boundary on shell (existing logic)
    → if match: {:boundary, error_boundary_id, ...}
    → if no match: {:error, error_info} → parent fatals
```

### Success Path
```
All activities in transaction complete normally
  → child PI: :finished
  → notify_parent({:child_pi_finished, final_tokens})
  → Transaction handler: await_child_completion
    → receive {:child_pi_finished, ...}
    → apply out mappings
    → return {:ok, %FlowNodeResult{next_flow_node_ids: outgoing_ids}}
  → Parent PI: dispatch outgoing sequence flows
```

---

## 7. Follow-Up (out of scope for this plan)

- Nested transactions (TX-D5)
- `method` attribute wire-protocol integration (TX-D6)
- `compensating` PI state (deferred from compensation plan)
- Parallel compensation during cancel (sequential LIFO only in v1)

---

## Assumptions

1. The existing compensation infrastructure is stable and passing all tests
2. The `FlowNodeData.SubProcess` struct can be extended with `is_transaction` without breaking existing code (default `false`)
3. The TypeScript SDK and Client have been updated with compensation types and are installed in the Studio
4. The `BoundaryResolver` generic matching can handle Cancel Boundaries without modification (just needs the event definition type check)

---

## Pre-Conditions

1. Phase 5.3 (Compensation) is complete and tested — **verified DONE**
2. **SubProcess + CallActivity Handler Refactoring** (`subprocess_handler_refactor_028433ff.plan.md`) is complete — extract shared child-PI lifecycle to `ChildLifecycle` module. This is a prerequisite because Transaction introduces a third consumer of the same lifecycle code. Without extraction, the code would be triplicated.
3. `mix quality` passes on the Engine — **must be verified before starting**
4. Studio builds cleanly — **must be verified before starting**

---

Plan-Gate: bestanden (11/11).

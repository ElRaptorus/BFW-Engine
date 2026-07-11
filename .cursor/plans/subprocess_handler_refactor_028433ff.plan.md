---
title: SubProcess + CallActivity Handler Refactoring — Extract Shared Child Lifecycle
date: 2026-07-10
status: PENDING APPROVAL
prerequisite_for: transaction_cancel_events_5a92f199
---

# SubProcess + CallActivity Handler Refactoring

**Goal:** Extract the duplicated child-PI lifecycle infrastructure shared between `FlowNodes.SubProcess` (1055 lines) and `FlowNodes.CallActivity` (892 lines) into a `SubProcess.ChildLifecycle` helper module, reducing duplication and making both handlers focused on their type-specific concerns. This is a prerequisite for the Transaction Subprocess implementation, which needs to add a third consumer of the same lifecycle infrastructure.

---

## 1. Problem Statement

`SubProcess` and `CallActivity` both manage the same fundamental lifecycle:
1. Start a child PI (with `notify_pid`)
2. Monitor it
3. Await completion via a `receive` loop matching 7+ message types
4. Process the result (output mapping, contract validation, token aggregation)
5. Handle errors (error boundary matching, BPMN error propagation)
6. Handle escalation (interrupting/non-interrupting boundary, passthrough, propagation)
7. Resume after engine restart (query child state, re-monitor or re-start from persistence)
8. Cascade fatal/abort to child

This is duplicated almost verbatim between the two modules, with minor differences:
- **CallActivity** resolves a called element version externally; **SubProcess** uses a synthetic inner-scope model
- **CallActivity** passes `calledElement` and optionally `start_event_id`; **SubProcess** always passes `subprocess_node_id`
- **SubProcess** has a `guard_event_subprocess` check and `validate_subprocess_contents` validation

Everything else — `await_child_completion`, `aggregate_tokens`, `apply_out_mappings_to_result`, `handle_child_error`, `handle_child_bpmn_error`, escalation resolution, resume helpers, cascade helpers, UUID generation — is structurally identical.

Adding `TransactionSubProcess` as a third consumer without extraction would mean tripling this code.

---

## 2. Design

### New module: `EvilEngine.Execution.FlowNodes.ChildLifecycle`

A pure helper module (no behaviour, no state) containing all shared functions. Both `SubProcess` and `CallActivity` call into it, passing type-specific parameters where behavior diverges.

### What moves to `ChildLifecycle`

| Function cluster | LoC (approx) | Notes |
|---|---|---|
| `await_child_completion/6` | ~53 | Identical receive loop |
| `aggregate_tokens/1` | ~12 | Identical |
| `apply_out_mappings_to_result/5` | ~30 | Identical (takes flow_node, context, final_tokens, next_ids, child_pi_id) |
| `apply_result/5` | ~25 | Resume-path variant of the above. Identical. |
| `handle_child_error/3` | ~15 | Error boundary resolution via `BoundaryResolver` |
| `handle_child_bpmn_error/4` | ~15 | BPMN error propagation |
| `propagate_bpmn_error/4` | ~17 | FNI finish-as-error + propagation tuple |
| `normalize_error/1` | ~6 | Error normalization |
| `apply_out_mappings/3`, `validate_payload_contract/2`, `validate_result_contract/2` | ~15 | Thin wrappers over `MappingHelper` |
| `resolve_outgoing/2` | ~8 | Thin wrapper over `SequenceFlowResolver` |
| `query_child_state/1` | ~8 | Lookup child in Registry |
| `monitor_and_wait/6` | ~55 | Re-monitor + await + result dispatch (parameterized for CA vs SP via callback) |
| `start_child_from_persistence/6` | ~70 | Resume child from DB (identical structure) |
| `aggregate_from_persistence/1` | ~18 | Read finished End Event FNIs from DB |
| `resume_existing_child/4` | ~40 | State-based resume dispatch. Needs parameterization for the `"cancelled"` state (Transaction-specific) |
| `set_child_notify_pid/2` | ~5 | |
| `cascade_to_child/2` | ~14 | Fatal/abort cascade |
| `get_child_process_instance_id/1` | ~5 | |
| `generate_uuid_v7/0` | ~10 | Should move to a shared utility, not ChildLifecycle |
| **Escalation cluster** | | |
| `handle_child_escalation_end/7` | ~25 | |
| `apply_non_interrupting_escalation_end/7` | ~40 | |
| `propagate_escalation_end/4` | ~22 | |
| `handle_escalation_passthrough_in_await/4` | ~30 | |
| `fire_non_interrupting_or_passthrough/4` | ~28 | |
| `resume_from_escalated_child/5` | ~30 | |
| `resume_from_bpmn_error_child/4` | ~8 | |
| **Total** | **~600** | |

### What stays in each handler

**`SubProcess` (~250 lines after extraction):**
- `handle_enter/3` — ESP guard, validate contents, build start_opts with `subprocess_node_id`
- `handle_resume/3` — route to `ChildLifecycle` with SP-specific resume options
- `handle_fatal/1`, `handle_aborted/1` — delegate to `ChildLifecycle.cascade_to_child`
- `guard_event_subprocess/1` — SP-specific
- `validate_subprocess_contents/2` — SP-specific
- `run_child_lifecycle/7` — SP-specific orchestration (input mapping → contract → start child)
- `start_and_monitor_child/6` — SP-specific start_opts construction (subprocess_node_id, synthetic model ID)
- `run_fresh_lifecycle/4` — SP-specific resume-from-scratch path

**`CallActivity` (~300 lines after extraction):**
- `handle_enter/3` — resolve called element, build start_opts with `calledElement`
- `handle_resume/3` — route to `ChildLifecycle` with CA-specific resume options
- `handle_fatal/1`, `handle_aborted/1` — delegate to `ChildLifecycle.cascade_to_child`
- `resolve_called_version/1` — CA-specific
- `run_child_lifecycle/7` — CA-specific orchestration
- `start_and_monitor_child/7` — CA-specific start_opts construction
- `run_fresh_lifecycle/4` — CA-specific resume-from-scratch path
- `maybe_put_start_event_id/2` — CA-specific

**`ChildLifecycle` (~600 lines):**
- All shared functions listed above
- Well-documented public API with `@spec` annotations

### `generate_uuid_v7` relocation

This function is duplicated in at least SubProcess and CallActivity. It should move to `EvilEngine.Execution.ProcessInstance.Helpers` (which already has ID-generation utilities) or a dedicated `EvilEngine.Execution.IdGenerator` module.

---

## 3. Checklist

### Phase R1 — Create `ChildLifecycle` and extract shared functions

- [ ] **R1.1** Create `apps/core_execution/lib/evil_engine/execution/flow_nodes/child_lifecycle.ex`
- [ ] **R1.2** Move `await_child_completion/6` — make public, parameterize if needed (currently identical between CA and SP)
- [ ] **R1.3** Move `aggregate_tokens/1` — public
- [ ] **R1.4** Move `apply_out_mappings_to_result/5` — public, takes `flow_node`, `context`, `final_tokens`, `next_ids`, `child_process_instance_id`
- [ ] **R1.5** Move `apply_result/5` — public (resume path variant)
- [ ] **R1.6** Move mapping/contract wrappers: `resolve_input_payload/3`, `apply_out_mappings/3`, `validate_payload_contract/2`, `validate_result_contract/2`, `resolve_outgoing/2`
- [ ] **R1.7** Move error handling cluster: `handle_child_error/3`, `handle_child_bpmn_error/4`, `propagate_bpmn_error/4`, `normalize_error/1`
- [ ] **R1.8** Move escalation handling cluster: all 6 escalation functions
- [ ] **R1.9** Move resume helpers: `query_child_state/1`, `monitor_and_wait/6`, `start_child_from_persistence/6`, `aggregate_from_persistence/1`, `resume_existing_child/4`, `resume_from_bpmn_error_child/4`, `set_child_notify_pid/2`
- [ ] **R1.10** Move cascade helpers: `cascade_to_child/2`, `get_child_process_instance_id/1`
- [ ] **R1.11** Move `generate_uuid_v7/0` to `ProcessInstance.Helpers` (or `IdGenerator`)

### Phase R2 — Update `SubProcess` to use `ChildLifecycle`

- [ ] **R2.1** Replace all extracted private functions with calls to `ChildLifecycle.*`
- [ ] **R2.2** Keep SP-specific functions: `guard_event_subprocess`, `validate_subprocess_contents`, SP-specific `start_and_monitor_child` (constructs `subprocess_node_id` start_opts), SP-specific `run_child_lifecycle`, `run_fresh_lifecycle`
- [ ] **R2.3** Verify `handle_enter`, `handle_resume`, `handle_fatal`, `handle_aborted` still work correctly
- [ ] **R2.4** Run `mix compile --warnings-as-errors` — no regressions

### Phase R3 — Update `CallActivity` to use `ChildLifecycle`

- [ ] **R3.1** Replace all extracted private functions with calls to `ChildLifecycle.*`
- [ ] **R3.2** Keep CA-specific functions: `resolve_called_version`, CA-specific `start_and_monitor_child`, CA-specific `run_child_lifecycle`, `run_fresh_lifecycle`, `maybe_put_start_event_id`
- [ ] **R3.3** Verify `handle_enter`, `handle_resume`, `handle_fatal`, `handle_aborted` still work correctly
- [ ] **R3.4** Run `mix compile --warnings-as-errors` — no regressions

### Phase R4 — Parameterize `resume_existing_child` for Transaction

- [ ] **R4.1** Add an optional `extra_terminal_states` parameter (or callback) to `resume_existing_child` so that `TransactionSubProcess` can add `"cancelled"` handling without modifying `ChildLifecycle` later
- [ ] **R4.2** Default: empty (no extra states). SubProcess and CallActivity pass nothing; Transaction will pass `%{"cancelled" => &handle_cancelled_child/3}`

### Phase R5 — Parameterize `await_child_completion` for Transaction

- [ ] **R5.1** Add an optional `extra_messages` parameter (or callback) so that `TransactionSubProcess` can handle `{:child_pi_cancelled, ...}` without modifying `ChildLifecycle`
- [ ] **R5.2** Default: no extra messages. SubProcess and CallActivity pass nothing; Transaction will pass a handler for `{:child_pi_cancelled, ...}`

### Phase R6 — Verify

- [ ] **R6.1** `mix compile --warnings-as-errors`
- [ ] **R6.2** `mix credo --strict`
- [ ] **R6.3** `mix dialyzer`
- [ ] **R6.4** `mix test` — all existing tests must pass without modification (pure refactoring, no behavior change)
- [ ] **R6.5** `mix test.integration` — all integration tests pass
- [ ] **R6.6** `mix test.conformance` — all conformance specs pass
- [ ] **R6.7** Verify SubProcess handler is under ~300 lines
- [ ] **R6.8** Verify CallActivity handler is under ~350 lines
- [ ] **R6.9** Verify ChildLifecycle has proper `@moduledoc`, `@doc`, and `@spec` on all public functions

### Phase R7 — Documentation

- [ ] **R7.1** Update `docs/architecture/execution.md` — add a section on `ChildLifecycle` explaining the shared infrastructure and how handlers compose on top of it
- [ ] **R7.2** Update `docs/architecture/common-pitfalls.md` — add a pitfall entry about not duplicating child-PI lifecycle code when adding new subprocess-like handlers (reference `ChildLifecycle`)

---

## 4. Risk Assessment

**Risk: behavioral regression.** This is a pure extract-and-delegate refactoring. No logic changes, no new behavior. The risk is low because:
- Every existing test (unit, integration, conformance) exercises the same code paths
- The refactoring is mechanical: move function, make public, update caller
- `mix quality` catches any breakage

**Risk: escalation handling divergence.** The escalation functions in SubProcess and CallActivity look similar but may have subtle differences. During extraction, each function pair must be carefully diffed to confirm they are truly identical before merging into one shared implementation.

**Risk: `monitor_and_wait` result dispatch.** SubProcess and CallActivity handle the `await_child_completion` result slightly differently in `monitor_and_wait` (SubProcess passes `process_instance_pid` differently in some code paths). This needs careful parameterization.

---

## Pre-Conditions

1. `mix quality` passes before starting — **must be verified**
2. No other in-flight changes to `sub_process.ex` or `call_activity.ex`

## Assumptions

1. The escalation handling functions in SubProcess and CallActivity are structurally identical (to be verified during R1.8 by diffing them side-by-side)
2. The `compensated` child state handling in `resume_existing_child` (if present in SubProcess) can be parameterized alongside `cancelled` for Transaction

---

Plan-Gate: bestanden (11/11).

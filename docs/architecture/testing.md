---
title: "Daemon Engine — Testing Strategy"
parent_document: "../ImplementationPlan.md"
---

<!--
  Extracted from ImplementationPlan.md §12 (Testing strategy).
  For numbering and plan-wide context, see the parent document.
-->

## 12. Testing strategy

### 12.1 Unit tests

- Per BPMN element handler: state transitions, valid/invalid payloads, contract violations, error codes.
- Per FEEL expression pattern: precompile + bind + evaluate.
- Per Ash action: permitted/denied identity scenarios.

### 12.2 Property-based tests

**Specified, not implemented in the quality gate.** `mix.exs` does not depend on PropCheck or Concuerror. `stream_data` appears only as a transitive Ash/crux optional. There are no `property` / `ExUnitProperties` tests in the tree.

When they land:

- `stream_data` / `PropCheck`: generate random valid BPMN subsets; assert round-trip parse, validate, execute semantics.
- `Concuerror`: prove race-freedom for PI ↔ FNI message passing, timer scheduler, event bus fan-out.

### 12.3 Conformance tests

- Import the **DMN FEEL TCK** for expression coverage (Phase 2+).
- Build our own **Evil BPMN conformance corpus**: `.bpmn` fixtures + YAML test spec describing start inputs, expected event ordering, expected final state/token. Cases derived from the BPMN 2.0 spec's normative examples.

#### 12.3.1 YAML-driven conformance framework (Phase 1)

The Phase 1 conformance corpus lives in `test/conformance/` and is executed via
`mix test.conformance` (or as part of `mix test.full` / `mix quality`). YAML specs
are loaded with `YamlElixir` from `api_web`'s `yaml_elixir` dependency (also used
for OpenAPI at runtime). The umbrella root does not declare `yaml_elixir`: Mix
rejects a root `only: :test` restriction when a child app needs the package in
every environment.

**Framework modules:**

| Module | File | Purpose |
|--------|------|---------|
| `EvilEngine.Test.ConformanceRunner` | `test/support/conformance_runner.ex` | Loads YAML specs, deploys BPMNs, starts PIs, waits for completion, asserts expectations |
| `EvilEngine.Test.ProcessInteractions` | `test/support/process_interactions.ex` | Reusable functions for interacting with running PIs (finish/cancel user tasks, complete/fail async FNIs, poll PI/FNI state, wait for finished timeout End Events, retrying user-task finish). `find_waiting_fni/2` skips MI/loop shells (`type_properties.mi_shell`). `finish_waiting_user_task_by_node_id/3` is required when more than one user task may be waiting (cancel-arm gate plus nested wait). `finish_transaction_cancel_gate_after_nested_idle/2` finishes `Tx_CancelGate` only after nested work is idle-waiting (C236–C238 / TX-7–TX-9). Interrupting-boundary proximity fixtures (ESC-1, ESC-3) use Escalation End after the arm user task so the child PI does not dispatch a None End writer that the boundary would kill mid-persist (P45). |

**Test tiers:**

| Tier | Description | YAML `tier` value | Test generation |
|------|-------------|-------------------|-----------------|
| Auto | Deploy → start → wait → assert. No mid-execution interaction required. A spec whose fixture parks on a user task that **must be finished** (for example `Tx_CancelGate`) cannot be auto. | `auto` | Dynamically generated from `for` loop over YAML files |
| Interactive | Requires mid-execution steps (user task finish, async completion, engine restart). | `interactive` | Hand-written `test` blocks using `ProcessInteractions` |
| Error | Tests start-time rejections (ambiguous start event, oversize payload). | `error` | Hand-written `test` blocks asserting HTTP error status codes |

Non-interrupting timer boundaries (C83, C84, C91) and non-interrupting timer Event Subprocesses (C175) must wait for the timeout path to persist **before** finishing the host user task. Finishing the host cancels the boundary. See `common-pitfalls.md` P81. Timer unit tests poll `Scheduler.armed_count/0` or drain the listener with `:sys.get_state/1` instead of `Process.sleep`. Event-Based Gateway races wait until the message/signal subscription exists before publishing. When an EBG catch sibling **wins** (C8), wait until every sibling is `:waiting` before completing the work that satisfies the winner — cancelling a sibling mid-persist tears the shared sandbox connection (P45/P82). C8 uses `conditional_catch_ebg_conditional_wins.bpmn` (a parallel user task writes the Data Object after both catches are parked); C9 keeps `conditional_catch_ebg.bpmn` with a timer-first start context.

**YAML spec format:**

```yaml
name: "C01: Minimal Start-End"
fixture: "linear_start_end.bpmn"
process_model_id: "LinearStartEnd"
tier: auto
start:
  payload: null
  start_event_id: null
expected:
  final_state: "finished"
  final_tokens:
    - end_event_id: "End_1"
  fni_count: 2
```

**Phase 1 fixtures (C01–C20 + C04a):** 21 specs covering linear flows, user tasks
(finish/cancel/contract violation), manual tasks (passthrough/confirmation),
service tasks (sync/async/fail/unknown type), multi-start events, implicit
split fatal, dead-end fatal, oversize payload rejection, intermediate catch events,
and resume-after-restart.

**Phase 2 fixtures (C21–C30):** 10 specs covering exclusive gateway routing
(condition A/B, default fallback, ambiguous fatal, no-match fatal), call activity
(basic lifecycle, error boundary catch, no-boundary fatal, result mapping via
out_mappings), and combined XOR-to-Call-Activity flows.

### 12.4 Integration tests

Integration tests are distinct from the conformance corpus (§12.3) — they exercise
real BPMNs end-to-end across every layer (HTTP → engine → persistence → GraphQL
subscriptions) and verify state at the database level, not just observable behavior
at the edge.

#### 12.4.1 Infrastructure

- Ecto sandbox against real Postgres (docker-compose service). No mocks below the
  Ash action layer; every test commits/rolls back against the real schema.
- Full HTTP + GraphQL + WebSocket smoke suite running the full Phoenix endpoint.
- Fixtures reuse the `.bpmn` + YAML test-spec format from §12.3, extended with a
  `processChain` section that declares the expected fan-out of child PIs and
  nested scopes (see §12.4.3).
- Every test runs under its own PI nonce so suites can run in parallel.

#### 12.4.1a Execution Integration Tests (Level 1 — Phase 1)

The first tier of execution integration tests verifies the core PI/FNI runtime
against real `.bpmn` fixture files, a live PostgreSQL database (Ecto Sandbox),
and the EngineEventBus — without HTTP/WS/GraphQL round-trips. These land with
Phase 1 items 1–6 and complement the unit tests in `core_execution/` which use
programmatic `BpmnFactory` structs and the `NoOp` persistence adapter.

**Location**: `test/integration/execution/` (umbrella root)

**Support modules** (`test/support/`):

| Module | Purpose |
|---|---|
| `ExecutionCase` | Case template: persist adapter + event collector; sandbox checkout (or pool truncate) **before** `Scheduler.reset_state` (P90); PI cleanup |
| `EventCollector` + `EventCollector.Sink` | EventSink-based event accumulator for ordered sequence assertions |
| `BpmnLoader` | Parse `.bpmn` fixture → `ModelCache.put_new/2` in one call |
| `DbAssertions` | Ash-backed query helpers: `fetch_process_instance!/1`, `list_child_process_instance_ids/1`, `await_child_process_instance_ids/2`, `fetch_flow_node_instances/1`, `assert_pi_state!/2` (always runs `assert_execution_chain!/2` unless `verify_execution_chain: false`: non-boundary `input_token` map before input mapping, finished non-boundary `output_token` map after output mapping, timestamps, all FNIs terminal on a terminal PI, Started → optional `active→waiting` StateChanged → Finished with matching `terminal_state`; parked types plus MI/loop shells with iterations must have StateChanged — P87), `assert_fni_count!/2`, `assert_all_fnis_state!/2`. Sandbox retries cover `OwnershipError` and `ConnectionError` after interrupted FNI writes (P45/P82). `fetch_process_instance/1` returns `nil` only for a genuine not-found. |
| `ProcessInteractions` | `find_waiting_fni/2` / `await_waiting_flow_node_instance/3` skip MI/loop **shell** FNIs (`type_properties.mi_shell`). Finish-user-task / finish-async helpers must target iteration FNIs, not the shell. |

**BPMN fixtures** (`test/fixtures/bpmns/`):

| Fixture | Scenario |
|---|---|
| `linear_start_end.bpmn` | Start → End |
| `linear_three_node.bpmn` | Start → Task → End |
| `user_task_simple.bpmn` | Start → UserTask → End (with assignees + formFields) |
| `user_task_with_contract.bpmn` | Same with `evil:resultContract` |
| `manual_task_confirm.bpmn` | Start → ManualTask (requireConfirmation) → End |
| `multi_start_events.bpmn` | Two untyped Start Events, each leading to a separate End Event |
| `implicit_split.bpmn` | Task with 2 outgoing flows (implicit split anti-pattern) |
| `dead_end.bpmn` | Task with 0 outgoing flows (dead-end) |

**Test modules** (13 tests total):

| Module | Tests | Verifies |
|---|---|---|
| `linear_execution_test.exs` | 2 | DB state (PI+FNI), payload threading, event sequence |
| `user_task_execution_test.exs` | 3 | Waiting state, finish call, contract violation → fatal |
| `manual_task_execution_test.exs` | 1 | requireConfirmation waiting + finish |
| `runtime_validation_test.exs` | 2 | implicit split fatal, dead-end fatal |
| `start_event_resolution_test.exs` | 4 | start-event disambiguation: path A, path B, ambiguous error, nonexistent error |
| `event_ordering_test.exs` | 1 | Strict 8-event sequence for Start→Task→End |

**Running**: `MIX_ENV=test mix run test/integration_runner.exs` (or `mix test.integration`). Pass one or more relative directories or `*_test.exs` paths after `--` to narrow the tree (for example `mix test.cookbook` → `test/integration_runner.exs -- integration/plugins`).

#### Mix test aliases (umbrella root)

| Alias | What it runs |
|-------|----------------|
| `mix test.unit` | Per-app unit tests (`--exclude integration`) |
| `mix test.examples` | Cookbook unit wrappers in `apps/peripheral_plugins/test/examples/` (acceptance i). Does not boot the engine. |
| `mix test.integration` | Full `test/integration/**` suite against the started umbrella, including cookbook boot + README link-check |
| `mix test.cookbook` | Same integration runner, glob only `test/integration/plugins/**` (acceptance ii + iii). Do **not** also invoke this from `mix quality` / CI (would double-run). |
| `mix test.conformance` | YAML-driven conformance specs |
| `mix test.coverdata` / `mix quality` | Full integration glob via `coverage_runner.exs` (unfiltered) |

Cookbook boot tests live under `test/integration/plugins/` because they need Registry, Loader, EngineEventBus, and Bandit.

#### 12.4.2 BPMN execution scenario matrix

Every integration scenario runs a **real BPMN** end-to-end through the engine.
The suite must cover the Cartesian product of the following axes; combinations
the BPMN spec forbids are explicitly marked `NOT_APPLICABLE` in the matrix driver
and skipped with a recorded reason:

| Axis | Values |
|---|---|
| **Task multiplicity** | single-instance • parallel multi-instance • sequential multi-instance |
| **Scope nesting** | root-only • one Embedded Subprocess • one Call Activity • Subprocess-inside-Call-Activity • Call-Activity-inside-Subprocess |
| **Chain depth** | 1 level (root → child) • 2–3 levels (shallow) • **5–6 levels deeply nested** via any mix of Call Activities and Embedded Subprocesses |
| **Parallelism** | fully serial • Parallel Gateway split/join • parallel multi-instance • concurrent child PIs spawned via parallel Call Activities in a Parallel Gateway branch |
| **Boundary events** | none • interrupting Timer • interrupting Error • interrupting Message • non-interrupting Timer / Message (where the spec allows) |
| **Compensation** | none • compensation handler fired on error • compensation handler fired on explicit throw |
| **Token payload lifecycle** | no payload • contract-validated payload at every hop • payload mutated by each FNI and asserted against the final shape |
| **Data Objects** | none • scope-local Data Object mutated by multiple FNIs • Data Object passed across Call Activity boundary via input/output mapping |

**Mandatory headline scenarios** (all green before the Phase 4 exit criterion):

- **S1 — Linear happy path**: Start → UserTask → ServiceTask → End. Baseline.
- **S2 — Parallel Gateway fan-out + join** *(covered by C160–C164)*: two or more branches, payload-merge semantics verified per token at the joining gateway.
- **S3 — Exclusive Gateway routing matrix**: one fixture per branch, condition-driven over FEEL; the default branch is exercised with an unmatched payload.
- **S4 — Parallel multi-instance Service Task**: N parallel iterations with a plugin handler; aggregated result asserted.
- **S5 — Sequential multi-instance User Task**: N sequential iterations; assert token continuity and intermediate payload mutations between iterations.
- **S6 — Embedded Subprocess with boundary Timer**: interrupting timer fires mid-subprocess; outer scope resumes on the compensation/error path.
- **S7 — Call Activity, single-level**: child PI spawn, input mapping, child runs to completion, result mapping applied to parent token.
- **S8 — Call Activity chain, 5–6 levels deep**: root PI spawns child via Call Activity; child spawns grandchild; …; level-6 descendant runs to completion. Every level's PI and FNI must reach the correct terminal state; the entire chain of `parent_process_instance_id` links must resolve.
- **S9 — Deeply-nested mixed scopes**: root → Embedded Subprocess → Call Activity → Embedded Subprocess → Call Activity → Embedded Subprocess (6 scopes, alternating kinds). Asserts that scope-local data objects and token payloads propagate correctly across every boundary.
- **S10 — Cross-PI messaging (single-recipient)**: intermediate throw from one PI correlates to an intermediate catch in exactly one sibling PI (both share the same `<evil:correlationKey>` value); asserts `messages.correlations` has length 1, `messages.correlation_value` is non-null, the target FNI advances, and no other PI is touched.
- **S10a — Broadcast-within-key (serial-letter)**: three sibling PIs all subscribe to the same message name and evaluate their `<evil:correlationKey>` to the same value. A single `POST /messages/{message_name}/trigger` (or intermediate throw) with that correlation delivers to **all three** — assert `messages.correlations` has length 3, each target FNI advances, and `correlations[].flow_node_instance_id` is distinct across the three.
- **S10b — Catch-wins-over-Start**: a process has a Message Start Event on name `M`. One PI of that process is already running and waiting on an intermediate catch for `M` with correlation value `K`. A `POST /messages/{message_name}/trigger` with `correlation=K` arrives. Assert: **no new PI** is started, the existing PI's catch advances, `messages.correlations` has length 1, `response.startedProcessInstanceIds` is empty. A second publish with `correlation=K'` (no matching subscription) starts exactly one new PI via the Start Event.
- **S10c — Pending-TTL rematch**: `TDE_MESSAGE_PENDING_TTL=PT30S`. Publish a message with correlation `K` at T0 — no subscription exists, `pending_messages` row written with `state='pending'`. At T+10s, start a PI whose intermediate catch evaluates `<evil:correlationKey>` to `K`. Assert the pending row transitions to `state='delivered'`, the catch advances, and `messages.correlations` is populated with the late subscription.
- **S10d — Pending-TTL expiry**: same setup as S10c but no matching subscription arrives before T+30s. The sweeper transitions the pending row to `state='expired'`, a `warn` log line is emitted with the `message_id`, and a subsequent subscription with the same key at T+40s does **not** receive the expired message.
- **S10e — Pending-rematched after restart**: publish at T0; `SIGKILL` the engine at T+5s; restart at T+10s. The surviving `pending_messages` row is still `state='pending'` with `expires_at = T+30s`. A PI deployed post-restart (or resumed from disk) registers a matching subscription at T+15s — assert the row flips to `state='delivered'` and the subscription receives the payload; assert the resumed subscription's `expected_correlation_value` equals the pending row's `correlation_value` (i.e. the post-restart re-evaluation of `<evil:correlationKey>` against restored state produced the same value).
- **S10f — Mixed Intermediate Catch + Boundary on the same key**: a running PI has both an intermediate catch AND a message-boundary attached to a parallel Service Task, both subscribing to the same `(name, correlation_value)`. Assert that a single publish delivers to **both** (broadcast-within-key), the catch advances its flow, and the boundary interrupts the task.
- **S11 — Error boundary + retry**: Service Task raises an FNI `fatal`; boundary error handler fires; `/process-instances/{id}/retry` re-enters the failed FNI and completes the run. Final state `finished`, not `fatal`.
- **S12 — Compensation flow**: error in a compensable activity triggers the compensation handler; compensation runs to completion; PI terminal state is `compensated`.
- **S13 — Timer scheduler under concurrency**: scheduled timer fires exactly once per PI across thousands of concurrent PIs; no double-fire, no drift beyond the §0 tick precision.
- **S14 — Multi-instance over Call Activity**: a Call Activity configured as parallel multi-instance spawns N child PIs concurrently; parent waits for all to complete and aggregates their results.
- **S15 — Cross-PI escalation, interrupting boundary**: three-level chain Parent → Call Activity `CA1` → Child → Call Activity `CA2` → Grandchild. The Grandchild throws an `EscalationEnd` with code `ESC_42`. Neither the Grandchild nor the Child has an enclosing catch; the Parent has an **interrupting** Escalation Boundary on `CA1` matching `ESC_42`. Assertions: Parent continues down the boundary path and finishes `finished`; `CA1` FNI ends `interrupted`; Child PI ends `aborted` with `terminated_by = parent_escalation`; `CA2` FNI (in Child) ends `interrupted`; Grandchild PI ends `escalated`; the `[:evil_engine, :escalation, :raised]` telemetry event is emitted exactly **once** with the full ancestor-PI chain `[grandchild_process_instance_id, child_process_instance_id, parent_process_instance_id]`; the matching boundary FNI's `previous_flow_node_instance_ids` chain links back through `CA1` to the Grandchild's throw FNI (spanning two PI boundaries); **no** `[:evil_engine, :escalation, :uncaught]` event is emitted.
- **S15a — Cross-PI escalation, non-interrupting boundary**: same three-level fixture as S15, but the Parent's boundary on `CA1` is **non-interrupting**. Assertions: Child PI and Grandchild PI keep running to normal completion (`finished`); `CA1` FNI also reaches `finished`; in parallel, the Parent spawns a second token via the non-interrupting boundary path and that token finishes normally; the Parent PI ends `finished`; `[:evil_engine, :escalation, :raised]` is emitted exactly once; the Parent PI has **two** terminal token paths recorded (main `CA1` completion + boundary continuation) and both appear as independent branches in `process_instance_events`.
- **S15b — Uncaught cross-PI escalation via Escalation End**: same fixture as S15 but with the Parent's boundary on `CA1` removed. The walker traverses Grandchild → Child → Parent and finds no catch anywhere. Assertions:
  - Grandchild PI ends `escalated` (its own Escalation End Event terminal semantics stand).
  - Child PI ends `escalated`; `CA2` FNI ends `interrupted`.
  - Parent PI ends `escalated`; `CA1` FNI ends `interrupted`.
  - Exactly one `[:evil_engine, :escalation, :uncaught]` telemetry event is emitted at the Parent PI boundary, carrying `ancestor_pi_chain = [grandchild_process_instance_id, child_process_instance_id, parent_process_instance_id]`, the escalation code `ESC_42`, and the throw-site FNI id.
  - Exactly one `warn`-level structured JSON log carries the same fields.
  - **No PI anywhere in the fixture transitions to `fatal`** (uncaught escalations never fault).
- **S15c — Uncaught cross-PI escalation via Intermediate Throw**: same chain as S15 but the Grandchild uses an **Intermediate** Escalation Throw that continues to a normal End Event; no catches anywhere. Assertions:
  - Grandchild PI ends `finished` (normal end after the throw).
  - Child PI ends `finished`; `CA2` FNI ends `finished`.
  - Parent PI ends `finished`; `CA1` FNI ends `finished`.
  - No FNI anywhere is `interrupted`.
  - Exactly one `[:evil_engine, :escalation, :uncaught]` telemetry event + one `warn` log, with the full ancestor-PI chain and throw-site FNI id.
  - No PI transitions to `fatal` or `escalated` — an uncaught Intermediate Throw is a pure no-op for terminal state.

#### 12.4.3 Assertion framework

Every scenario runs the following assertion bundle against the committed database
state **after** the root PI reaches a terminal state (polled via the GraphQL
`processInstance` subscription, not by sleeping):

**Flow-Node execution correctness**

- Every `flow_node_instance` expected by the fixture YAML appears in the database, keyed by `(process_instance_id, flow_node_id, iteration_index)` — `iteration_index` is non-null for multi-instance tokens and participates in the primary-equality check.
- The **set of FNI rows is equal** to the fixture's expected set: no missing rows and no unexpected rows. Subset matches are not accepted.
- `started_at` / `finished_at` timestamps are strictly monotonic per PI and satisfy the fixture's `happens-before` DAG (parallelism-tolerant — not a linear log match).
- For every multi-instance activity, the number of FNI rows equals the declared cardinality; for sequential MI, `started_at` ordering is a total order; for parallel MI, it is not required to be a total order but must all fall inside the parent scope's active window.

**Final state**

- Every PI (root + every child spawned via Call Activity) reaches `state ∈ {finished, fatal, aborted, error, escalated, compensated}` **exactly** as declared by the fixture — no state substitutions accepted.
- Every FNI reaches `state ∈ {active, finished, fatal, aborted, interrupted}`, and every **terminal** FNI (non-`active`) matches the fixture exactly.
- `PI.finished_at` is non-null iff PI state is terminal; same for FNI.
- No `active` FNIs remain after the root PI is terminal — enforced as a SQL invariant in every assertion bundle.
- No orphan child PIs remain after the root terminates: `count(child PIs with state = 'running' AND root_ancestor = root.id) == 0`.

**Token payload**

- The final payload on every terminal FNI matches the fixture's expected JSON **exactly** (deep equality; no extraneous keys, no missing keys, order-insensitive for objects, order-sensitive for arrays).
- For every Data Object on every scope, the final value in `data_objects` matches the fixture (or is asserted absent — i.e. no `data_objects` row exists — if the fixture says so).
- For Call Activity results, both the **raw child result** and the **mapping-applied value on the parent FNI** are asserted independently.
- For multi-instance, the fixture asserts the full ordered/unordered list of per-iteration payloads and the aggregated payload at join.

**Data Object write audit (`data_object_writes`)**

- For every Data Object that the fixture touches, `data_object_writes` contains **exactly** the sequence of `(flow_node_instance_id, value)` tuples the fixture declares — set- and order-equal (ordered by `created_at`). Extra rows fail the test; missing rows fail the test.
- Every row's `flow_node_instance_id` resolves to an existing `flow_node_instances` row, and that FNI's `process_instance_id` equals the write's `process_instance_id` (no cross-PI writes exist). Furthermore (DOA-only invariant): the writing FNI's Flow Node model has at least one `bpmn:dataOutputAssociation` targeting the written Data Object — assertions cross-reference the parsed AST to verify there is no "orphan" write with no DOA predecessor. (This was a soft invariant when the handler-API path existed; with the DOA-only path it becomes hard.)
- The **last** row's `value` for each `(process_instance_id, data_object_id)` equals `data_objects.value` for that pair.
- ~~For every `data_object_writes` row there is exactly one `process_instance_events` row with `event_type = 'data_object.written'` whose payload carries the matching `write_id` (1:1 correspondence).~~ **Superseded:** the built-in database sink was removed; `process_instance_events` is no longer populated. Integration tests assert `data_object_writes` rows only.
- Contract-violation path: when a scenario forces a `<evil:valueContract>` violation, assert that `data_object_writes` has **zero** rows for that attempted write and the FNI transitioned to `fatal`. Independently, assert that no `%Event.DataObjectWritten{}` was emitted on `EngineEventBus` for that attempt — the contract check happens **before** the write transaction, so sinks never see the rejected write.

**Audit trail (`process_instance_events`) — The built-in database sink that populated this table was removed. The table is retained for migration compatibility but stays empty. The historical assertion bundle below applied when `TDE_EVENT_SINK_DATABASE=on` was set in test config; it is no longer exercised:

- Every event row the fixture declares is present, matched by `(event_type, flow_node_instance_id, previous_flow_node_instance_id)`.
- No unexpected event rows exist (set-equality, same as FNI rule).
- Referential integrity: every `flow_node_instance_id` referenced by an event row exists in `flow_node_instances`.
- `previous_flow_node_instance_id` chains form a valid DAG (no cycles, no dangling references).

**Parent/child correlation (Call Activity scenarios)**

- `child.parent_process_instance_id == parent.id` for every spawned child.
- Each child's `process_version_id` equals the version that was the latest non-deleted (`process_versions.deleted=false`) at the child's spawn time. If the parent's process version was deleted *after* the child spawned, the child's version link must still resolve.
- The Call Activity FNI on the parent is `finished` iff the child PI reached `finished`; any non-`finished` terminal state on the child propagates to the parent as per the configured error-boundary behavior.

**Engine invariants (asserted per scenario)**

- Zero entries in the `:telemetry` counter `engine.crashes` for the duration of the test.
- No `FATAL`-level JSON log line emitted.
- On `/stats`, all internal queues (timer scheduler, event bus backlog, persistence writer) return to baseline (0) **before** the assertion bundle runs — this catches leaks where a test appears green but leaves background work pending.
- `:telemetry` counter `engine.pi.spawned` increment equals the total PI count declared by the fixture (root + children).
- `:telemetry` counter `engine.fni.executed` increment equals the total FNI count declared by the fixture.

#### 12.4.4 Resume & crash-recovery variants

Every scenario in §12.4.2 is run at least once in **crash-resume mode**:

1. Start the root PI, wait for the fixture-declared "midpoint marker" FNI to reach `active`.
2. Kill the engine OS process uncleanly (SIGKILL from the test harness).
3. Restart the engine via the same release binary used in production.
4. Assert resume is automatic, every still-`running` PI rehydrates against its original `process_version_id` (soft-deleted versions remain resolvable for resume), and no PI is left in `running` state forever.
5. Let the PI finish; run the full §12.4.3 assertion bundle.
6. ~~Additionally assert that `process_instance_events` contains both the pre-crash and post-crash segments in the correct temporal order, with **no gaps** and **no duplicate events** straddling the crash boundary.~~ **Superseded** — `process_instance_events` is no longer populated; crash-resume correctness is asserted via kernel tables and FNI state only.

**Data Object crash-resume variants**

In addition to the generic midpoint-SIGKILL variant, every scenario whose fixture
touches Data Objects is also run twice with injected crash points around writes:

- **DO-SIGKILL-mid-transaction**: the test harness arms a fault injector that aborts the engine process **while** a specific Data Object write transaction is in flight (SIGKILL on the BEAM between the DOA-driven write-transaction entry and COMMIT). After restart, assert that Postgres rolled the transaction back atomically: either **both** kernel-state rows (`data_objects` upsert + `data_object_writes` insert) are present, or **neither** is. The resumed PI's in-memory cache matches `data_objects` exactly, so the DOA replays on resume and completes normally (per the FNI idempotency rules — the FNI re-runs its `onFinished` commit, the DOA re-fires, and the write-transaction succeeds on the second attempt). The final `data_object_writes` sequence has **no partial/phantom** rows.
- **DO-SIGKILL-post-commit-pre-event**: crash after the write transaction has committed but **before** the PI has published the `%Event.DataObjectWritten{}` onto `EngineEventBus` (i.e. before any of the `console`/`websocket` sinks saw it). Assert that after resume, downstream flow proceeds as if the write had happened (it did — it's in the DB), no duplicate `data_object_writes` row is produced by retry. The test asserts the kernel-state rows are correct.

#### 12.4.5 Deploy-rejection scenarios

Negative-path integration tests for the deploy surface:

- BPMN missing or blank `<evil:version>` → `422`, matches deploy-time validation.
- BPMN failing the configured linter gate ([configuration.md](configuration.md) §14.5) → `422` with structured `failures` body. Every `reason` code is exercised at least once across the fixture set: `ruleset_missing`, `score_below_minimum`, `errors_exceed_maximum`, `warnings_exceed_maximum`, `compliance_status_mismatch`, `schema_version_mismatch`.
- Seeding-Directory variant of the above: the same bad BPMN placed in `TDE_SEEDING_DIRECTORY` → file is skipped, an `error` JSON log is emitted carrying the filename and failures, engine startup continues, no `process_version` row is created.
- Deleted version: `POST /processes/{model_id}/start` against a deleted version is rejected with the documented error code; existing running PIs on that version continue to run and resume cleanly across a restart.

#### 12.4.6 Payload-cap rejection scenarios

Negative-path integration tests exercising `TDE_TOKEN_MAX_BYTES` enforcement at every boundary identified in §5.5 and §10.1.1. All tests run with the default cap of `65536` bytes unless stated. The helpers `mint_payload(n_bytes)` and `oversize_payload()` = `mint_payload(65537)` are shared across fixtures.

- **CAP-WRITE-RESULT**: a Script Task handler calls `write_result/2` with `oversize_payload()`. **Assert:** facade returns `{:error, :payload_too_large, %{size: 65537, limit: 65536}}`; FNI row ends with `state='fatal'` and `reason = %{kind: :payload_too_large, field: :fni_output, size: 65537, limit: 65536}`; no downstream FNI is ever created; PI row transitions to `state='fatal'`. No `:payload_too_large`-specific event type is emitted (per §16.4).
- **CAP-WRITE-DO**: a Service Task is modeled with a `dataOutputAssociation` targeting `order_payload`, and its handler returns a FlowNodeResult whose `outputs.order_payload` is `oversize_payload()`. **Assert:** the DOA-driven write pipeline evaluates contract validation **before** the payload cap check (code order: resolve target → evaluate value → validate contract → check cap); with a valid contract the cap check rejects with `{:error, :payload_too_large, ...}`; no `data_objects` row inserted or updated; no `data_object_writes` row created; no `Event.DataObjectWritten` reaches `EngineEventBus` (all three built-in sinks report zero deliveries for that event); the owning Service Task FNI transitions to `fatal` with `field: :data_object, data_object_id: "order_payload"` in the structured reason (the DOA cap-check is attributed to the FNI whose completion triggered the DOA).
- **CAP-PUBLISH-MSG**: a Send Task handler calls `publish_message("OrderShipped", oversize_payload())`. **Assert:** facade returns `{:error, :payload_too_large, ...}`; **no** `messages` row is inserted; **no** subscription anywhere in the engine fires; FNI transitions to `fatal`. Repeat for `publish_signal/2` (signals carry no payload on the REST trigger; oversize applies only if a throw-side mapping produces an oversize token before publish). The REST escalation trigger (`POST /escalations/{escalation_code}/trigger`) carries no payload and does not call PayloadCap.
- **CAP-PI-START-CONTEXT**: `POST /processes/{model_id}/start` with a `payload` (PI-start context) of 65537 bytes. **Assert:** HTTP response is `413` with body `{"error": "payload_too_large", "field": "payload", "size": 65537, "limit": 65536}`; no `process_instances` row is inserted; no PI `:gen_statem` is spawned; no `Event.PiStarted` reaches any sink.
- **CAP-TRIGGER-MSG**: `POST /messages/{message_name}/trigger` with an oversize `payload`. **Assert:** HTTP 413 with structured body; **no** `messages` row, **no** delivery, **no** Message Start Event fires (even if one exists for the supplied name). GraphQL has no command equivalent (query-only).
- **CAP-TASK-FINISH**: `PUT /user-tasks/{fniId}/finish` with an oversize `result`. **Assert:** HTTP 413; the User Task FNI remains in state `active` (not `fatal` on this path — the cap guards the API layer before the facade is touched, and the user is expected to retry with a smaller payload); the PI continues running; no state mutations are observable.
- **CAP-EXACTLY-AT-LIMIT**: every boundary above is repeated with `mint_payload(65536)` (exactly at the cap). **Assert:** every call succeeds; no `:payload_too_large` signal anywhere; normal execution proceeds; subsequent calls with `mint_payload(65537)` on the same PI still fail as expected (cap is stateless per-call).
- **CAP-CONFIGURABLE**: the full matrix is rerun with `TDE_TOKEN_MAX_BYTES=131072`. **Assert:** all `CAP-*` tests that previously failed at 65537 now succeed; fresh failures appear at 131073. The minimum `1024` is exercised via a separate boot-time assertion: `TDE_TOKEN_MAX_BYTES=512` refuses to boot with a structured error referencing `minimum_required: 1024`.
- **CAP-MEMORY-BEHAVIOR**: a micro-load variant (50 req/s for 30 s, alternating at-cap and cap+1-byte payloads across every boundary). **Assert:** engine RSS stays flat ±5 MB; GenServer mailbox depths stay bounded; no partial work leaks into `flow_node_instances` or `messages` tables. Validates the "enforcement precedes allocation that scales with payload size" invariant.

#### 12.4.7 Token-storage shape assertions

Positive-path integration tests verifying the payload-cap eliminations are actually applied and the schema matches [data-model.md](data-model.md) §4.2:

- **SHAPE-NO-FINAL-TOKEN-COLUMN**: a schema-inspection test fails if `information_schema.columns` reports a `final_token` column on `process_instances`.
- **SHAPE-NO-ACTIVE-TOKENS-TABLE**: a schema-inspection test fails if `information_schema.tables` reports an `active_tokens` table.
- **SHAPE-GATEWAY-PENDING-EXISTS**: `gateway_pending_arrivals` exists with the exact columns + unique index documented in [data-model.md](data-model.md) §4.2.
- **SHAPE-LZ4-APPLIED**: every column called out as `COMPRESSION lz4` in [data-model.md](data-model.md) §4.2 / §4.3 reports `lz4` in `pg_attribute.attcompression` (or the storage is still empty, which is also acceptable for columns that haven't seen a write yet in the test DB).
- **CALC-FINAL-TOKENS-FINISHED-LINEAR**: run the 3-step linear process from Phase 1's exit criterion, then GraphQL-query `processInstance(id: $id) { finalTokens }`. **Assert:** length-1 list containing exactly the End FNI's `output_token`.
- **CALC-FINAL-TOKENS-FINISHED-PARALLEL**: run a parallel-split process with two End Events that both fire. **Assert:** `finalTokens` length is 2, ordered by End FNI `finished_at`.
- **CALC-FINAL-TOKENS-NON-FINISHED**: run one PI each that terminates in each of `fatal`, `aborted`, `error`, `escalated`, `compensated`. **Assert:** `finalTokens` is `null` for every one of them.
- **CALC-FINAL-TOKENS-BATCHED**: issue `processInstances(first: 1000) { id finalTokens }` against a DB seeded with 1000 finished PIs. **Assert:** total DB query count is 2 (1 for the PI page, 1 for the batched End-Event output_token lookup). Measured via the Ecto log capture harness already in place for other tests.
- **RESUME-ACTIVE-FROM-FNI**: run a process up to a User Task (FNI in state `active` with an `input_token`), SIGKILL the engine, restart. **Assert:** on restart, the rehydrated PI's in-memory token at that FNI matches exactly the pre-crash `input_token`; no `active_tokens`-style reconciliation is performed; `gateway_pending_arrivals` is empty (no gateway is involved); PI continues cleanly on User Task completion.
- **RESUME-GATEWAY-PENDING** *(covered by `Resumption.rebuild_join_arrivals/2` + `parallel_gateway_lifecycle_test.exs`)*: run a parallel gateway with 2 of 3 branches arrived, SIGKILL the engine mid-wait, restart. **Assert:** `gateway_pending_arrivals` has exactly 2 rows with the correct `source_branch_sequence_flow_id` values and the correct `arrived_payload`; the third branch's subsequent arrival correctly fires the join; the gateway FNI's `output_token` is the merged result of all 3 branches per the join semantics.

#### 12.4.8 Sidecar plugin integration tests

> **Not a v1 CI obligation (PLUG-D1).** The sidecar host is deferred. The
> matrix below is retained as the design for a possible post-v1 revisit.
> v1 does not require `test/fixtures/plugins/`, `SidecarLoader`, or
> five-language proof in CI.

Sidecar plugin tests would exercise the full discovery → manifest parse → Port spawn →
gRPC handshake → register → execute → teardown lifecycle against real multi-language
fixture plugins.

**Fixture layout** — `test/fixtures/plugins/` (project root):

```
test/fixtures/plugins/
├── elixir-echo/
│   ├── plugin.toml
│   └── echo_service_task        # Elixir escript
├── python-echo/
│   ├── plugin.toml
│   └── echo_service_task.py
├── ruby-echo/
│   ├── plugin.toml
│   └── echo_service_task.rb
├── csharp-echo/
│   ├── plugin.toml
│   └── bin/EchoServiceTask      # dotnet publish output
├── nodejs-echo/
│   ├── plugin.toml
│   └── echo_service_task.js
├── malformed-manifest/
│   └── plugin.toml              # deliberately broken TOML
└── missing-binary/
    └── plugin.toml              # exec points to non-existent file
```

Each fixture plugin is a minimal sidecar implementing the gRPC plugin protocol
(`evil.engine.plugin.v1`). Every happy-path fixture registers one custom
ServiceTaskHandler that echoes its input as its output — enough to prove the
full round-trip without complex logic.

**Multi-language requirement** — five languages must be covered to validate the
language-agnostic claim: Elixir (escript), Python, Ruby, C# (dotnet), and
Node.js. Each must successfully discover, handshake, register, and execute a
Service Task end-to-end.

**Test isolation** — the integration test setup:

1. Overrides `Application.get_env(:peripheral_plugins, :sidecar_dir)` to point
   at `test/fixtures/plugins/`.
2. Triggers the `SidecarLoader` scan.
3. After the test run (in an ExUnit `on_exit` callback): resets `sidecar_dir` to
   the original value, disconnects all sidecar Port processes, and calls
   `Registry.reset_state()` so no plugin registrations leak into subsequent tests.

**Scenarios** (referenced as (i)–(vii) in `ImplementationPhases.md` Phase 4 step 3):

| ID | Scenario | Asserts |
|----|----------|---------|
| (i) | Happy-path sidecar Service Task | Plugin discovered, handshake succeeds, handler registered, Service Task executes, result returned through registry |
| (ii) | Sidecar crash mid-execution → reconnect | Binary killed mid-handle → Port restarts → in-flight FNI fails gracefully |
| (iii) | Repeated crash → quarantine | Crash count exceeds `TDE_PLUGINS_SIDECAR_RECONNECT_LIMIT` → `Event.PluginQuarantined` emitted, no further reconnects |
| (iv) | Malformed `plugin.toml` | Plugin quarantined, engine boots, other plugins unaffected |
| (v) | Deny-listed manifest | Plugin not spawned, structured log emitted |
| (vi) | Multi-language proof | One fixture per language passes full discover → handshake → register → execute cycle |
| (vii) | `sidecar_dir` isolation | Config restored after test, no plugin registrations leak |

### 12.5 Load tests

All load tests live in `test/load/` and are tagged `@tag :load`. Run via `mix test.load` (`cli.preferred_envs` maps that alias to `MIX_ENV=test`). The alias (and GitHub `load-bench.yml`) set `TDE_LOAD_TEST_POOL=1` **before** Mix loads `config/test.exs`, so Repo uses a real `DBConnection.ConnectionPool` rather than the Ecto sandbox (P89). Default load-test pool is 50 write / 25 read (`TDE_LOAD_TEST_POOL_SIZE`). Do not run `mix test test/load/<file>.exs --include load` under the default sandbox — E8's 10-minute timeout exceeds sandbox `ownership_timeout` (5 minutes) and every in-flight PI then logs `OwnershipError`.

Durability tests in `execution_durability_load_test.exs` are additionally tagged `@tag :durability`. `mix test.load` and the GitHub job **exclude** them. Run `mix test.load.durability` for that file only, or `mix test.load.all` for the default suite plus durability and hardening (one JSON report). Both aliases set `TDE_LOAD_DURABILITY` (`1` vs `all`); `mix test.load.all` also sets `TDE_LOAD_HARDENING=all`. Do not add durability or hardening to `load-bench.yml` on `ubuntu-latest`: mixed 100,000 is about an hour on 2 vCPUs.

#### Execution load tests (`execution_load_test.exs`)

Full API-driven lifecycle: deploy via HTTP, start PIs, auto-finish user tasks via EventSink, assert all PIs reach terminal state within time ceilings. Tests E1–E5 cover single fixture types (100–1,000 PIs). E6 mixes all 5 fixture types (5,000 PIs). E7 is a stress test with 10,000 linear PIs. E6 and E7 additionally capture `queue_time` telemetry and assert P99 checkout wait < 1,000ms. AutoFinisher and the echo service-task handlers retry `:fni_not_waiting` / `:process_instance_not_found` (P88) so a single early finish does not leave one PI waiting forever. E6's elapsed ceiling is 180 s on GitHub `ubuntu-latest` (2 vCPU), not 5× the Mac baseline.

#### Resume load tests (`resume_load_test.exs`)

Seed PIs directly via Ash writes (bypassing HTTP), then measure `ResumeRunner.resume_all()` wall-clock time. Tests L1–L8 cover 100 to 10,000 PIs with varying FNI counts and process types. L8 measures raw DB seeding throughput; its ceiling is 11 ms/PI (5× the ~2.1 ms/PI Linux baseline). The previous 3 ms/PI cap was only ~1.4× and failed on GitHub `ubuntu-latest` (2 vCPU) at 3.2 ms/PI.

#### Pool pressure tests (`pool_pressure_test.exs`)

Concurrent mixed-workload tests that exercise execution writes and GraphQL reads simultaneously. PI starts use `Task.async_stream` with configurable `max_concurrency` (default 20). PP1: 500 concurrent PIs + 50 GraphQL readers. PP2: 1,000 mixed PIs + 100 GraphQL readers (GraphQL tasks are **unlinked** so a reader crash must not EXIT the test process). PP3: burst-start 200 PIs while polling GraphQL continuously. Assertions: **zero `DBConnection.ConnectionError` telemetry**, all PIs reach terminal state, P99 `queue_time_ms` < 1,000ms. PP1/PP3 also require GraphQL HTTP 200. Under the sandbox these tests were not a production-pool signal (P82/P89); `mix test.load` uses a real pool.

#### Resume pressure tests (`resume_pressure_test.exs`)

RP1/RP2 seed 1,000–5,000 waiting user-task PIs and measure `ResumeRunner.resume_all/0`. Concurrent Absinthe/Ash GraphQL during resume used to abort the Ecto sandbox owner (P82). Load tests now use a real connection pool (P89); GraphQL-under-resume is still omitted from RP1/RP2 so the recorded KPI stays resume throughput only.

#### DMN load tests (`dmn_load_test.exs`)

DMN decision evaluation throughput under sustained load. Each measured batch terminates remaining PI processes afterward so later batches are not inflated by leftover BEAM processes. Assert ceilings are ~5× the 2026-05-21 M-series Mac averages (same multiplier as execution/resume). The original 3× Mac ceilings are too tight for GitHub `ubuntu-latest` (2 vCPU): D7 averaged 16,583 ms against a 14,937 ms cap.

#### Standard execution workloads (E8 / E9)

| Test | Workload id(s) | What it exercises |
|------|----------------|-------------------|
| E8 | `exec_10000_mixed_standard` | 10,000 root PIs round-robin across linear, parallel gateway, parallel multi-instance script task, and Call Activity fixtures |
| E10 | `exec_10000_parallel_gateway` | 10,000 root PIs, parallel gateway two-branch fixture only |
| E11 | `exec_10000_mi_parallel_script` | 10,000 root PIs, parallel multi-instance script task (collection of 3) |
| E12 | `exec_10000_call_activity` | 10,000 root PIs, Call Activity + child; `CompletionCounter` is `roots_only: true` |
| E9 | `exec_1000_linear_payload_1kib`, `_16kib`, `_64kib` | 1,000 linear PIs each at 1 KiB, 16 KiB, and ~64 KiB start payloads (JSON-encoded size capped at the engine payload limit) |

E8 uses `CompletionCounter.start(roots_only: true)` so Call Activity child PIs do not satisfy the await early — only root terminal PIs increment the counter. E12 does the same. E9 uses the default counter (all terminal PIs). E7 is the linear 10,000 counterpart of E10–E12 (same count, start→end fixture).

#### Durability execution (`execution_durability_load_test.exs`)

Opt-in volume runs. Same HTTP lifecycle as E7/E8/E10–E12. `mix test.load` excludes `@tag :durability`. `mix test.load.durability` runs only this file. `mix test.load.all` runs the default suite plus durability and hardening in the same ExUnit process (one JSON).

| Test name | Workload id | Count | Fixture |
|-----------|-------------|------:|---------|
| D: 20000 / 50000 / 100000 linear PIs | `exec_<n>_linear` | 20k / 50k / 100k | `linear_start_end.bpmn` |
| D: … parallel_gateway PIs | `exec_<n>_parallel_gateway` | same | two-branch parallel gateway |
| D: … mi_parallel_script PIs | `exec_<n>_mi_parallel_script` | same | parallel MI script task (collection of 3) |
| D: … call_activity PIs | `exec_<n>_call_activity` | same | Call Activity + child; `roots_only: true` |
| D: … mixed PIs | `exec_<n>_mixed_standard` | same | E8 round-robin; `roots_only: true` |

Ceilings are first-run wall-clock caps (20k: 20 min, 50k: 45 min, 100k: 90 min; ExUnit timeout is higher). Queue P99 must stay under 1,000 ms. There is no 30,000 step.

#### Hardening load tests (`mix test.load.hardening`)

Opt-in Layer B suite. Tagged `@tag :hardening` (also `@moduletag :load`). **Excluded** from `mix test.load`, `mix test.full`, `mix quality`, and `.github/workflows/load-bench.yml`. Run with `mix test.load.hardening` (`TDE_LOAD_HARDENING=1`). `mix test.load.all` includes these tests with the default suite and durability (`TDE_LOAD_HARDENING=all` plus `TDE_LOAD_DURABILITY=all`). Setting `TDE_LOAD_HARDENING=all` alone adds hardening to the default load suite without durability.

The Mix alias sets `TDE_LOAD_TEST_POOL=1` before Mix loads `config/test.exs` (P89), same as the other load aliases.

| File | Workload id(s) | What it exercises |
|------|----------------|-------------------|
| `jsonb_compression_load_test.exs` | `jsonb_lz4_*`, `jsonb_pglz_*` | Same VM: E8-shaped mix + ~60 KiB linear payloads + CapDoa/CapSend + up to 100 five-deep Call Activity trees; then `ALTER … SET COMPRESSION pglz` + rewrite; then the same mix. **Gate:** any named p50/p95 on LZ4 that is >10 % slower than PGLZ `flunk`s, except integer-ms SQL noise (`p95 < 2`) and GraphQL wall-clock deltas under 5 ms (Absinthe jitter). Do not auto-flip `TDE_JSONB_COMPRESSION`. Count = `TDE_LOAD_COMPRESSION_COUNT` (default `10000`). |
| `payload_cap_chaos_load_test.exs` | `payload_cap_chaos_5pct` | ~50 ops/s mix of start / message trigger / user-task finish; every 20th call is 65537 bytes (HTTP 413, no row). Duration = `TDE_LOAD_CHAOS_SECONDS` (default `600`). After a 15 s warmup, last RSS sample must be ≤ first sample + 32 MiB. Each sample scrapes Prometheus distributions (`:ets.take` on `:prometheus_metrics_dist`) and silences the test EventCollector (`capture_log: false`). |
| `resume_crash_load_test.exs` | `resume_crash_user_task_200`, `resume_crash_parallel_join_50`, `resume_crash_ca_depth5_100` | Crash-kill PI supervisors (`LoadHelpers.terminate_all_process_instances/0` uses `:kill`, P94), `ResumeRunner.resume_all/0` (roots only, P11). Assert `input_token` round-trip, `gateway_pending_arrivals` unchanged (2 rows per three-branch PI), `to_regclass('public.active_tokens')` is null. |

Smoke while iterating: `TDE_LOAD_COMPRESSION_COUNT=1000 TDE_LOAD_CHAOS_SECONDS=30 mix test.load.hardening`.

#### Hot-path triage

A recorded KPI is a **hot path** only if E6/E7/E8/E10/E11/E12 P99 `queue_time_ms` is ≥ 1 000, E8 wall time exceeds 5× the first measured baseline (206 507 ms on 2026-09-02; the test assert is capped at 600 s because 5× would exceed the timeout), `:erlang.memory()[:total]` is still climbing after `terminate_all_process_instances`, or resume/seeding throughput falls implausibly below the existing L-test ceilings. End-of-suite `memoryBytes.total` on the JSON report is a snapshot at write time, not a leak detector.

The first Phase 7 standard run (2026-09-03, Linux, Postgres in Docker) found **no hot path**. A later full suite on the same machine recorded E6 57 582 ms with queue P99 17 ms; E7 83 908 ms / 8 ms; E8 198 542 ms / 18 ms (first E8 baseline 206 507 ms). E9 1 KiB / 16 KiB / 64 KiB completed in 7 415 / 10 577 / 16 006 ms. Resume and seeding L-tests stayed inside their existing ceilings. Core was not rewritten.

#### Benchmark reporting

`mix test.load` runs `test/load_runner.exs`, which starts `EvilEngine.Test.BenchmarkReporter` before ExUnit and calls `EvilEngine.Test.LoadRunnerReport.finish!/1` after the suite. Instrumented workloads pass `:id` (and optional KPI metadata) to `LoadHelpers.measure/3`, which still prints `[BENCH]` lines to stdout and records a workload map into the reporter.

After every run — including when ExUnit reports failures — the runner writes a pretty JSON file to `test/load/reports/<utc_compact>.json` (gitignored via `.gitignore`). Top-level report fields:

| Field | Description |
|-------|-------------|
| `schemaVersion` | Always `1` |
| `recordedAt` | UTC ISO 8601 timestamp |
| `gitSha`, `otpRelease`, `elixirVersion` | Build provenance |
| `beamProcessCount` | `:erlang.system_info(:process_count)` at write time |
| `memoryBytes` | Snapshot of `:erlang.memory/0` (`total`, `processes`, `system`, `atom`, `binary`, `ets`) |
| `garbageCollection` | `numberOfCollections` and `wordsReclaimed` from `:erlang.statistics(:garbage_collection)` |
| `workloads` | Array of per-workload objects (`id`, `kind`, `processCount`, `elapsedMilliseconds`, `processInstancesPerSecond`, latency percentiles, optional queue-time P99, nested `kpis`) |

Runtime snapshot fields (`beamProcessCount`, `memoryBytes`, `garbageCollection`) are **top-level** on the report — they are not duplicated inside each workload object.

Optional baseline compare: set `TDE_LOAD_BASELINE_PATH` to a prior JSON file before `mix test.load`. After tests pass, overlapping workload ids are compared; throughput KPI drops or latency P99 rises of more than 20 % print regressions and the runner exits with status **2**. Missing or unreadable baseline files also exit **2**. When the env var is unset, compare is skipped. The GitHub load-bench workflow does **not** set this variable (runners are too noisy for a hard gate).

Load tests are **not** part of `mix quality` or `mix test.full` — they remain opt-in via `mix test.load`, `mix test.load.durability`, `mix test.load.hardening`, `mix test.load.all`, or the dispatch workflow below.

#### Test helpers

| Helper | Purpose |
|--------|---------|
| `LoadHelpers.seed_process_instances/3` | Bulk-seed PIs via direct Ash writes |
| `LoadHelpers.measure/3` | Wall-clock timing with `[BENCH]` log output; records into `BenchmarkReporter` when `:id` is set |
| `LoadHelpers.start_queue_time_collector/0` | Attach telemetry handler to collect DB queue_time samples |
| `LoadHelpers.start_source_query_collector/0` | Attach telemetry handler collecting `query_time_ms` keyed by `metadata.source` (table name; raw SQL tables are derived by `DbQueryHandler`) |
| `LoadHelpers.source_latencies_ms/2` | p50/p95/count for one table from that collector |
| `LoadHelpers.set_jsonb_compression!/1` | Layer B only: `ALTER … SET COMPRESSION` + `UPDATE col = col` rewrite (`lz4` or `pglz`) |
| `LoadHelpers.jsonb_payload_bytes/0` | Sum of `pg_column_size` across JSONB payload columns |
| `LoadHelpers.queue_time_p99/1` | Compute P99 from collected samples |
| `LoadHelpers.queue_time_max/1` | Compute max from collected samples |
| `LoadHelpers.start_connection_error_collector/0` | Track `DBConnection.ConnectionError` events via telemetry |
| `LoadHelpers.connection_error_count/1` | Read the connection error count |
| `DbAssertions.truncate_persistence_tables/0` | `TRUNCATE … CASCADE` between load tests when not on the sandbox |
| `CompletionCounter` | Lock-free PI completion counter via `:atomics` + telemetry; `start(roots_only: true)` counts only root terminal PIs |
| `BenchmarkReporter` | In-memory workload accumulator; `write!/1` emits schemaVersion 1 JSON |
| `LoadRunnerReport` | Post-run hook: writes report path, applies exit codes 1 (test failure) / 2 (baseline regression) |

### 12.6 CI enforcement

`.github/workflows/ci.yml` (push / pull_request to `main` and `develop`, plus `workflow_dispatch`):

- Postgres service published on host port **5543** (`config/test.exs`); `mix do --app peripheral_persistence ecto.create` + `ecto.migrate` before tests (`priv/read_repo/migrations` exists empty so Mix does not error on the read pool)
- `mix format --check-formatted`
- `mix credo --strict`
- One Mix cache of `deps` + `_build`, keyed on OS + `mix-precover` + `MIX_ENV` + OTP + Elixir + `mix.lock` (no app source hashes). Restore at job start; save after `mix compile --warnings-as-errors` and **before** coverage so ExCoveralls-instrumented BEAMs are not reused on the next run. Dialyzer PLTs stay a separate `priv/plts` cache (see `mix.exs` `plt_core_path` / `plt_local_path`) keyed on OS + OTP + Elixir + `mix.lock`. `_build` cache does not include PLTs. Packages CI uses the same unified Mix cache with a `-prod-` key prefix. `igniter` is `runtime: false` (not started). It is **not** `only: :dev`: Spark Mix tasks reference `Igniter` at compile time, so Elixir 1.20 type-checking fails if Igniter is absent from the test or prod load path. Ash policy SAT (via `crux`) uses Hex `simple_sat` — a pure Elixir solver. Do not drop it without a replacement (`picosat_elixir` or `simple_sat`); with neither, GraphQL/Ash authorization returns empty results. Mix may compile `crux` before optional SAT backends; CI and `mix setup` run `mix deps.compile.sat` (`simple_sat` then `crux --force`) before the rest of `deps.compile`. Cold `mix deps.compile` sets `MIX_OS_DEPS_COMPILE_PARTITION_COUNT` to `nproc`
- `mix test.coverdata` then `mix coveralls --umbrella --import-cover cover` — same coverage merge as `mix quality` (integration + conformance under one `:cover` session, then per-app unit tests). Enforces `coveralls.json` `minimum_coverage`. Does **not** upload to coveralls.io (`mix coveralls.github` / `mix coveralls.post` are the upload tasks and must not be used). Do **not** gate coverage on `mix coveralls --umbrella` alone (unit tests only; ~65% vs the 80% gate). `test/coverage_runner.exs` must **not** `:cover.compile` `Elixir.EvilEngine.Expressions.Nif.beam` (P79). Cookbook `mix test.cookbook` is **not** a separate CI step (the plugins tests are already in the integration glob). CI installs Node.js 24.20 (`actions/setup-node` `node-version: "24.20"`) so `node_script` / `ScriptSandbox` `.js` tests run; `ubuntu-latest` already provides `python3`.
- `mix sobelow` for security
- `mix deps.audit`
- Docker smoke: `postgres:16-alpine` with `max_connections=200` so production pool defaults (100 write + 50 read) can check out; smoke asserts `GET /health` **HTTP 204** (empty body — not JSON `"status":"ok"`)

`.github/workflows/load-bench.yml` (**manual only** — `workflow_dispatch`; **not** required on pull requests):

| Step | Detail |
|------|--------|
| Trigger | GitHub Actions → **Load benchmarks** → Run workflow |
| Stack | OTP `29.0.5`, Elixir `1.20.3-otp-29`, Rust `1.98.0`, Postgres `16-alpine` on host port **5543** (same credentials as `config/test.exs`; FEEL NIF needs Rust, not Node) |
| Run | `mix deps.get`, `mix deps.compile.sat`, `mix deps.compile`, `mix compile --warnings-as-errors`, `ecto.create` + `ecto.migrate`, then `mix test.load` (120-minute job timeout). Job env sets `MIX_ENV: test`, `TDE_LOAD_TEST_POOL: "1"` (P89), and `TDE_LOAD_TEST_POOL_SIZE: "50"` (50 write / 25 read; 75 total stays under the service-container Postgres `max_connections` of 100). Intended to complete on standard `ubuntu-latest` (2 vCPU, ~7 GB). Does **not** run `mix test.load.durability`. |
| Artifact | `actions/upload-artifact@v4` uploads `test/load/reports/*.json` as `load-bench-report` (`if: always()`, `if-no-files-found: error`) |
| Baseline | Does **not** set `TDE_LOAD_BASELINE_PATH` — download the artifact and compare locally |

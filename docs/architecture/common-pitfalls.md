# Common Pitfalls

Recurring constraints someone could hit **again**. Add an entry only if a
competent person could hit this without this note. One-off bugfixes, CI
incident reports, and named failing tests do not belong here.

Each entry: **Mistake** / **Why** / **Correct approach**. A few lines.
Point at architecture docs instead of copying their tables.

Test-harness and CI rules live in [`testing.md`](testing.md).

---

## Core must not import Peripheral — use a Persistence behaviour

**Mistake:** Calling `Ash.create/3` from `core_execution` to persist PI/FNI state.

**Why:** Core must not depend on Peripheral. Ash lives in `peripheral_persistence`.

**Correct approach:** `@behaviour EvilEngine.Execution.Persistence` in Core. Wire `EvilEngine.Persistence.ExecutionAdapter` via `:core_execution, :persistence_adapter`. Tests use `NoOp`. See [execution.md](execution.md).

---

## Do validation in `gen_statem` `init/1`

**Mistake:** Deferring model fetch / start-event resolution to an internal event after `init/1`.

**Why:** `start_link` returns `{:ok, pid}` as soon as `init/1` returns. Failures in queued events never reach the caller.

**Correct approach:** Validate synchronously in `init/1`. Return `{:stop, {reason, data}}` on failure.

---

## Resolve outgoing flows from `source_ref`, not `FlowNode.outgoing`

**Mistake:** Using `flow_node.outgoing` as the only successor list.

**Why:** `<bpmn:outgoing>` is optional. Many editors only set `sourceRef` / `targetRef` on sequence flows.

**Correct approach:** Scan `process.sequence_flows` by `source_ref` when `outgoing` is empty.

---

## Ash named create actions need `primary? true`

**Mistake:** A named `create :create_from_engine` without `primary?: true`, then `Ash.create(Resource, attrs)`.

**Why:** Ash 3.x `Ash.create/2` uses the primary create. A non-primary named action is invisible to that call.

**Correct approach:** Mark the engine create `primary?: true`, or call the named action explicitly.

---

## FNI IDs must match the resource's UUID type

**Mistake:** Inserting a random UUID v4 into a resource whose primary key is `:uuid_v7`.

**Why:** Ash rejects the dump. Pre-generated handler IDs must be the same type the resource declares.

**Correct approach:** Generate UUIDv7 (or whatever the resource declares) before `Ash.create`.

---

## Warm `ModelCache` only after the deploy transaction commits

**Mistake:** `ModelCache.put_new/2` inside the same `Repo.transaction` that inserts `process_versions`.

**Why:** ETS is not transactional. A rollback leaves a stale AST keyed by an uncommitted id.

**Correct approach:** Commit first, then warm the cache. Flush Ash notifications after commit (`Ash.Notifier.notify/1` with `return_notifications?: true` on creates). Same pattern for DMN deploy.

---

## FEEL context is `%Context{}` with string keys

**Mistake:** Passing `%{token: payload, this: payload}` (atom keys) to `Expressions.eval/2`, or setting `this` to the token.

**Why:** The NIF matches string keys. Atom keys evaluate to `null` with no error. `this` is flow-node metadata (`id`, `name`, `type`). `context` is `started_with_context`, not the token.

**Correct approach:** `Expressions.Context.from_handler_context/2`. Never build `%Context{}` by hand in a handler. Compile with a context shape that names the variables (`Expressions.compile/2`). See [expressions.md](expressions.md).

---

## Soft-deleted rows are invisible; public APIs never say "soft-delete"

**Mistake:** A `deleted` attribute without `filter expr(deleted == false)` on the primary `:read`, or returning `"soft-deleted"` to clients.

**Why:** `authorize?: false` does not bypass `base_filter`. Missing-vs-deleted must be indistinguishable (404 / "not found").

**Correct approach:** Primary `:read` filters `deleted == false`; `primary_read_warning?: false`. Do not add a read-including-deleted action. See [authorization.md](authorization.md) and the `soft-delete-isolation` rule.

---

## ResumeRunner resumes root PIs only

**Mistake:** Calling resume on a child PI (Call Activity / SubProcess / ESP / ad-hoc child).

**Why:** Child resume without the parent shell corrupts the tree. The parent owns the child lifecycle.

**Correct approach:** `ResumeRunner.resume_all/0` selects roots (`parent_process_instance_id` nil). Public retry targets a PI then resets the tree from the root. See [execution.md](execution.md) and the [retry handbook](../guides/handbook/retry.md).

---

## Ash read policies return `{:ok, []}`, not Forbidden

**Mistake:** Asserting `{:error, %Ash.Error.Forbidden{}}` on a policy-denied GraphQL/Ash read.

**Why:** Ash 3.x filters unauthorized rows out of reads. The caller sees empty, not an error.

**Correct approach:** Treat empty the same as not-found for reads. Writes still error.

---

## Do not camelCase opaque user-payload subtrees

**Mistake:** Recursively camelCasing `payload`, `inputToken`, `outputToken`, `claims`, `typeProperties`, `errorInfo`, and similar.

**Why:** User keys are part of the process contract. Structural keys are camelCase; opaque subtrees pass through.

**Correct approach:** `EvilEngine.Types.Wire` — convert struct fields only. See [api.md](api.md).

---

## Create partitions before INSERT

**Mistake:** Inserting into a `PARTITION BY RANGE` parent when the target period's child table does not exist.

**Why:** Postgres rejects the INSERT. Boot `mix evil.partitions.ensure` only creates the current window plus `TDE_PARTITION_AHEAD_MONTHS`.

**Correct approach:** Run `ensure_partitions` at boot / release pre-start. Long-uptime nodes need `pg_partman` (or equivalent) for drop. See [data-model.md](data-model.md) and [database.md](../guides/operations/database.md).

---

## Terminal PI transitions must persist every non-terminal FNI and cascade children

**Mistake:** Killing FNI pids on fatal/abort/error without persisting those rows, or leaving Call Activity / SubProcess children running.

**Why:** Resume rehydrates from the DB. Live children after parent death are orphans. Crash between persist and cascade can leave the same hole — cleanup must be idempotent.

**Correct approach:** Persist collateral FNIs (`:fatal` / `:aborted` / `:error` / `:interrupted` as appropriate), run `handle_aborted/1` for cleanup, abort child PIs. `:aborted` is **only** for user/API abort — Terminate End uses `:interrupted`. See [execution.md](execution.md).

---

## Signals are not messages

**Mistake:** Putting correlation keys or payloads on signals, or expecting catch-wins-over-start.

**Why:** Signals are broadcast-all by `signal_name`. No payload, no correlation. Catch and Signal Start can fire together.

**Correct approach:** Use messages for correlated payloads. See [routing.md](routing.md).

---

## XOR join does not absorb duplicate merge tokens

**Mistake:** Assuming an exclusive join swallows extra tokens the way a parallel join waits.

**Why:** Exclusive merge is pass-through. A second token on the same join is another execution.

**Correct approach:** Model the join correctly, or use parallel/inclusive/complex joins when you need merge semantics.

---

## Link throw searches the whole process scope

**Mistake:** Expecting link catch to be local to a subprocess.

**Why:** Link pairs match by `link_name` across the process. Duplicate catches fatal `:ambiguous_link_catch`; none fatal `:no_matching_link_catch`. Checked at runtime, not deploy.

**Correct approach:** Unique link names per process. See the [link-events handbook](../guides/handbook/link-events.md).

---

## WebSocket FNI dispatch is lane-gated; GraphQL FNI reads are not

**Mistake:** Assuming `engine:events` join rejects unauthorized callers, or that GraphQL FNI lists apply the same lane filter as live WS.

**Why:** Join stays open; `should_deliver?/2` drops events at dispatch. GraphQL reads use PI visibility, not per-FNI lane gating on the list.

**Correct approach:** Enforce lanes at WS dispatch. Do not treat GraphQL FNI fields as a live lane firewall. See [authorization.md](authorization.md).

---

## Persistence adapter calls go through `PersistenceRetry`

**Mistake:** Calling the persistence adapter directly from a handler/PI.

**Why:** Transient Postgres / pool errors must retry with the same policy everywhere.

**Correct approach:** `PersistenceRetry.with_retry/3`. See [persistence.md](persistence.md).

---

## Error messages must be diagnostic sentences

**Mistake:** Atom-to-words (`"In mapping failed"`) or `inspect/1` in `errorInfo.message` / HTTP bodies.

**Why:** The debugger and API consumers need the element, the expression, and why it failed.

**Correct approach:** `Helpers.build_error_info/1` + an explicit `humanize_error/1` clause per new error shape. See [api.md](api.md).

---

## `root_process_instance_id` is self for roots, inherited for children

**Mistake:** Leaving `root_process_instance_id` nil on a child, or setting it to the immediate parent.

**Why:** Studio debugger subscribes to the root channel. Fan-out uses this field.

**Correct approach:** Root: equal to `process_instance_id`. Child: copy from the parent handler context. See [event-system.md](event-system.md).

---

## Event Subprocess shell is not a token-entered subprocess

**Mistake:** Incoming/outgoing sequence flows on the ESP shell; treating it as a separate deployment; killing the scope PI when an interrupting ESP fires; delivering a message to an ESP start when a Catch/Boundary exists.

**Why:** An ESP is dormant until its typed start fires. It runs as a **child PI** of the scope (synthetic model, same version). Interrupting cancels sibling FNIs; the scope still reaches `:finished`. Message precedence: Catch/Boundary → ESP start → standalone Message Start.

**Correct approach:** No sequence flows on the shell. One typed start. See [execution.md](execution.md) and the [event-subprocesses handbook](../guides/handbook/event-subprocesses.md). Inner Start Events are never externally startable — `subprocess_node_id` without a parent is `:orphan_subprocess_start`.

---

## Claim and lane checks belong in `EvilEngine.Api`

**Mistake:** Re-implementing JWT claim or lane checks in a Phoenix controller.

**Why:** Plugins call the same facade with `skip_claims: true`. A controller-only check is a bypass.

**Correct approach:** `EvilEngine.Api.Validation`. Controllers map HTTP and call the facade. See [authorization.md](authorization.md).

---

## Complex Gateway joins need `activationCondition` and a SESE region

**Mistake:** A mixed split+join Complex Gateway; a join without `<bpmn:activationCondition>`; cancelling FNIs that sit on the split or join nodes themselves.

**Why:** Mixed gateways are rejected at deploy. Split completeness is runtime. The region between the paired split and join is exclusive of those two nodes.

**Correct approach:** Split or join, never both. Join condition uses `activatedCount` / `incomingCount`. See [execution.md](execution.md) and the [complex-gateways handbook](../guides/handbook/complex-gateways.md).

---

## Compensation is registration, not a subscription — and not automatic on failure

**Mistake:** Treating a Compensation Boundary as a timer/message boundary, or expecting fatal/error/abort/escalation to run compensation handlers.

**Why:** Compensation boundaries are passive (`cancelActivity="false"`). Handlers link via `<bpmn:association>`. Only Compensate Throw/End (and transaction cancel) dispatch them. Hazard (uncaught error) does **not** compensate.

**Correct approach:** Model an explicit compensate throw if you want compensation on error. `isForCompensation` activities have no sequence flows. See the [compensation handbook](../guides/handbook/compensation.md).

---

## Ad-hoc inner activities have no Start or End events

**Mistake:** Putting a Start/End inside `<bpmn:adHocSubProcess>`, or treating `cancelRemainingInstances="false"` as missing (`|| true`).

**Why:** Ad-hoc activities are activated on demand. `false` is a real value — `||` turns it into `true`.

**Correct approach:** `Map.get(attrs, :cancel_remaining_instances, true)`. See the [adhoc handbook](../guides/handbook/adhoc-subprocesses.md).

---

## Retry checkpoints cannot sit on joins, MI iterations, or inside ad-hoc/transaction scopes

**Mistake:** `resetToFlowNodeInstanceId` pointing at a parallel join, an MI iteration FNI, or a node inside a transaction / ad-hoc child.

**Why:** Those states are not a safe resume cursor. HTTP 422 with a specific error code.

**Correct approach:** Retry at the fork, the MI shell, or upstream. See the [retry handbook](../guides/handbook/retry.md).

---

## Inclusive joins and conditional waiters re-evaluate on state change

**Mistake:** Evaluating an inclusive join or a conditional event only at first arrival, or skipping the immediate check when a waiter registers.

**Why:** A late-arriving token or a condition that is already true at subscribe time never fires.

**Correct approach:** Re-evaluate inclusive joins after every FNI state change. Conditional subscribe includes an immediate evaluation (edge-triggered false→true afterwards). Conditions do not cross PI scope.

---

## Error Boundary codes resolve `errorRef`; `fail_async` is the Service Task failure path

**Mistake:** Matching boundaries on raw XML order, or expecting `{:error, _}` from Service Task `handle_enter/3`.

**Why:** Catch-side codes come from inline `evil:errorCode` else global `errorRef`. Service Tasks are async-only; production failure is `fail_async`.

**Correct approach:** Specific resolved code first, then catch-all. `facade.service_tasks.fail_async.(id, code, message)`. See [execution.md](execution.md).

---

## Event-Based Gateway: do not kill siblings that are still `:active`

**Mistake:** Interrupting EBG losers as soon as the winner reports, while sibling handler Tasks are still entering.

**Why:** The PI inserted both successors as `:active` before either parked. Killing mid-persist races the sandbox and can leave a loser finishing.

**Correct approach:** Interrupt `:waiting` immediately. Stamp `:active` losers `ebg_pending_cancel` and wait for `{:async}` / `{:wait}` before persist-interrupt. Do not complete `PT0S` timer catches synchronously from `handle_enter`.

---

## GraphQL: offset pagination, complexity is `limit × fields`, no empty fragments

**Mistake:** Keyset pagination (`hasNextPage` missing); setting `TDE_GRAPHQL_MAX_COMPLEXITY` as if it were "how big the PI is"; emitting `... on TaskNode { }`.

**Why:** Lists use offset pagination. AshGraphql scores `limit × selected child fields` (debugger `dataObjectValues(limit: 500)` is 6500; default cap 10000). Empty inline fragments are invalid GraphQL. Depth is sized for recursive `SubProcessNode.flowNodes`.

**Correct approach:** Offset pagination. Do not lower the complexity default below the debugger snapshot. Omit empty `on` types in `buildFlowNodeSelection`. See [api.md](api.md) and [configuration.md](configuration.md).

---

## Do not put `max_children` on the PI DynamicSupervisor

**Mistake:** Setting `max_children` from `TDE_MAX_CONCURRENT_PIS`, or queueing leftover PIs during resume.

**Why:** Resume must bring the whole tree back. A cap mid-resume orphans children.

**Correct approach:** Supervisor `max_children` is `:infinity`. The env var is a soft pre-check on **new public starts** only. Resume bypasses it. See [execution.md](execution.md).

---

## Production Timer Start persistence is not NoOp

**Mistake:** Leaving `:core_timers, :persistence_module` on `NoOp` in production.

**Why:** NoOp is the test default. Cycle Timer Starts then vanish across restart.

**Correct approach:** Production uses `EvilEngine.Persistence.TimerStartScheduleAdapter`. Tests keep NoOp except `ExecutionCase`. See [timers.md](timers.md).

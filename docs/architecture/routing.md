---
title: "Evil Engine — Message/Signal/Escalation Routing"
parent_document: "../ImplementationPlan.md"
---

<!-- Extracted from ImplementationPlan.md §3.5 (Message/Signal/Escalation routing). -->

### 3.5 Message/Signal/Escalation routing

Messages are routed by `(message_name, correlation_value)`; Signals are
pure broadcast; Escalations bubble along a **scope chain** that walks upward
through enclosing subprocesses / event subprocesses and crosses **at most one
PI boundary per hop** — from a child PI up to its Call Activity FNI in the
parent — repeating until caught or until the root of the root PI is reached. Escalations never broadcast to unrelated PIs.

#### 3.5.1 Subscription registry (in-memory, per-node)

- A single `GenServer` per engine node (`EvilEngine.Events.MessageSubscriptions`) owns the registry. It is backed by ETS for O(1) lookup on `(message_name, correlation_value)`.
- A subscription row: `%Subscription{process_instance_id, flow_node_instance_id, flow_node_id, message_name, expected_correlation_value, kind :: :intermediate_catch | :boundary | :event_subprocess_start, registered_at, :via_pid}`.
- Intermediate Catch, Boundary Event (Message), and Event Subprocess Start Events share this registry — matching is identical across all three (the `kind` field is informational only, used for audit + debugging).
- The registry is **in-memory only**. On engine restart it is empty until PIs resume; each PI re-evaluates `<evil:correlationKey>` against its restored state and re-registers its active subscriptions before the Subscription GenServer declares itself "ready".

#### 3.5.2 Correlation value derivation

`<evil:correlationKey>` is FEEL over PI state/context (catch-side subscribe).
`<evil:correlationRetrievalExpression>` is FEEL over the outgoing token /
handler context (throw-side publish). Where each one runs:

- **Catch / Boundary / Event-Subprocess-Start subscribe**: PI's `<evil:correlationKey>` evaluated against current PI state (token + Data Objects + `Identity`, see [expressions.md](./expressions.md) §8 context). Result cached on the `%Subscription{}` row as `expected_correlation_value`.
  - If the process declares no `<evil:correlationKey>`, the subscription's `expected_correlation_value` is `:none` — it matches any message whose `correlation_value` is `:none`.
- **Throw (Intermediate Throw / Message End Event)**: throw's `<evil:correlationRetrievalExpression>` evaluated against the outgoing token payload. Result is stamped onto `messages.correlation_value` at publish time.
- **API `POST /messages/{message_name}/trigger`**: caller supplies `correlation` in the request body. If absent, `correlation_value = :none`.
- **Message Start Event**: at the moment of starting a new PI from a message, `<evil:correlationKey>` is evaluated against **the incoming payload** (there is no PI state yet), and the resulting value is seeded as the new PI's first correlation value. Subsequent subscriptions inside that PI re-evaluate `<evil:correlationKey>` against the now-populated PI state.

#### 3.5.3 Publish-side algorithm

A published message `(name, payload, correlation_value)` flows through
`EvilEngine.Events.MessagePublisher.publish_message/1`:

1. Write a row to `messages` (audit — always, whether or not it correlates).
2. Look up the subscription registry with `(name, correlation_value)`. Collect **every** matching subscription (broadcast-within-key — serial-letter semantics).
3. For each matching subscription, send a typed `%Event.MessageArrived{}` to the owning PI's `:gen_statem` via its registered pid; the PI dispatches to the target FNI through its internal catch registry ([../ImplementationPlan.md](../ImplementationPlan.md) §5.4).
4. Record the delivery on `messages.correlations` as `[{process_instance_id, flow_node_instance_id}]` — one entry per delivery.
5. **Catch-wins-over-Start rule**: if step 2 yielded **zero** matching subscriptions **and** any deployed non-deleted process version (i.e. `process_versions.deleted=false`) has a Message Start Event with matching `name`, start one new PI per such process (each seeding its own correlation value via §3.5.2). If step 2 yielded at least one match, Message Start Events are **not** triggered for this publish — the message is considered consumed by the subscription(s).
6. If step 2 yielded zero matching subscriptions **and** no deployed process has a Message Start Event with matching `name`, move to §3.5.4.

**Event Subprocess Message Start interaction (ESP-D13 / ESP-D13b).** An ESP Message Start registers with the informational `:event_subprocess_start` kind but is **excluded from the delivery set** in step 2 — it is a gated Start Event, not a fan-out delivery. The full precedence ladder for a message `(name, correlation)` is: **(1)** inline Message Catch / Message Boundary (the broadcast-within-key fan-out of step 2), **(2)** ESP Message Start of a running scope (fires only when step 2 delivered to zero catch/boundary subscriptions, correlated at scope activation), **(3)** standalone Message Start Event (new PI). A Catch/Boundary therefore **always** beats an ESP Message Start, and an ESP Message Start beats a standalone Message Start (a running instance consumes the message before a new PI is created). See §3.5.8.

#### 3.5.4 Unmatched publishes (pending with TTL)

Pending messages are held in the durable `pending_messages` table ([data-model.md](./data-model.md) §4.3) for
`EVIL_MESSAGE_PENDING_TTL` (default 60 s) so that a subscription registering
shortly after publish still catches the message.

- On publish with zero matches (§3.5.3 step 6): insert a `pending_messages` row with `state='pending'`, `expires_at = published_at + EVIL_MESSAGE_PENDING_TTL`.
- On every subscription register (`MessageSubscriptions.register/1`): drain pending messages for that `(name, expected_correlation_value)` — any pending rows still inside TTL are delivered immediately via §3.5.3 step 3 and their `state` set to `'delivered'`.
- A periodic sweeper (every 10 s by default) transitions expired `pending` rows to `state='expired'` and emits a `warn` JSON log carrying the `message_id`, `name`, and `correlation_value`.
- `pending_messages` never holds Signals or Escalations — those are not TTL'd.
- **Delete-on-transition**: the post-transition row lifetime is governed by `EVIL_PENDING_MESSAGES_KEEP_AFTER_TRANSITION` (default `true`). With the default, rows in `delivered`/`expired`/`cancelled` state persist until the retention runner sweeps them (as an engine-level audit of delivery attempts) — Studio's debugger and ops dashboards can answer "was message X held and for how long before it delivered?" until retention ages the row out. With the flag set to `false`, the engine physically deletes the row in the same transaction that moves its state away from `pending`, so the table holds only rows still in flight. Only terminal-state rows are eligible in either mode; a `pending` row is never deleted except by a state transition or by an explicit cancellation (PI cancelled while holding a registered-catch subscription that would have drained it).
- **Orphan pending cleanup**: when a publish delivers to at least one live subscriber or triggers a Message Start Event, the publisher cancels all existing `pending_messages` rows for that `(message_name, correlation_value)` via `cancel_pending_for_message/2`. This prevents stale pending rows from earlier zero-match publishes from being drained by the next subscriber that registers after a live delivery.
- **`skip_pending` flag**: REST API message triggers (`POST /messages/:name/trigger`) pass `skip_pending: true` through `Api.publish_message/5` to the publisher. When set, the publisher never inserts a `pending_messages` row even on zero-match. BPMN throws and plugin facade calls follow the standard pending-with-TTL behavior.

#### 3.5.5 Resume / restart behavior

1. Engine boots; `MessageSubscriptions` GenServer is empty.
2. `EvilEngine.Execution.ResumeRunner` rehydrates every `state='running'` PI. Per-PI rehydration is delegated to `ProcessInstance.Resumption`, which reads **only** the PI row, `flow_node_instances WHERE state='active'` for that PI, `gateway_pending_arrivals` scoped to that PI (half-completed joins), `data_objects` scoped to that PI (to rebuild the in-memory DO cache ), and `engine_timers WHERE state='armed'` scoped to that PI. Active token payloads come from each active FNI's `input_token` column; the payload slim-down eliminates the `active_tokens` shadow table, so there is no second source to reconcile against. For half-completed parallel/inclusive-gateway joins, the PI rehydrates the arrival buffer directly from `gateway_pending_arrivals` and re-arms the remaining-branch waits.
3. As each PI resumes and its active catches/boundaries re-enter `waiting`, they re-register via `MessageSubscriptions.register/1` (re-evaluating `<evil:correlationKey>` against restored PI state).
4. Each `register/1` call drains `pending_messages` for its `(name, expected_correlation_value)` — this is the mechanism that lets a message published seconds before a restart still reach its target PI after resume (provided `expires_at` has not elapsed).
5. The engine does not declare itself "ready" (and does not begin accepting new HTTP publishes) until step 2–4 are complete for every PI. This prevents the race where a fresh publish sneaks in before resumed PIs have their subscriptions re-registered.

#### 3.5.6 Signals

Signals skip §3.5.2–§3.5.3 (no correlation, no payload) but follow the same
pending-with-TTL resume-race model as Messages. The single entry point
is `EvilEngine.Events.SignalPublisher.publish_signal/1`.

**Overview.** Signal events use a broadcast model — every active subscriber
for a given `signal_name` receives the signal simultaneously. Unlike messages,
signals have:

- **No payload**: Signals carry no data. The token passes through unchanged.
- **No correlation**: Signals match by `signal_name` only. No
  `<evil:correlationKey>` or `<evil:correlationRetrievalExpression>`.
- **True broadcast to all event types**: When a signal is published, ALL
  matching Signal Catch Events, Signal Boundary Events, AND Signal Start Events
  fire simultaneously. There is no catch-wins-over-Start gating (contrast
  §3.5.3 step 5).

**Subscription registry.** A single `GenServer` per engine node
(`EvilEngine.Events.SignalSubscriptions`) owns the registry. It is backed by
an ETS `:bag` table keyed by `signal_name` for O(1) lookup on publish. A
subscription row: `%Subscription{subscription_id, process_instance_id,
flow_node_instance_id, flow_node_id, signal_name, kind :: :intermediate_catch
| :boundary | :event_subprocess_start, registered_at, via_pid}`. Event
Subprocess Signal Starts register with the `:event_subprocess_start` kind and
fire alongside catches, boundaries, and standalone Signal Starts (broadcast-all,
no catch-wins-over-Start gate — see §3.5.8). The registry is **in-memory only**;
on engine restart it is empty until PIs resume and their active catches /
boundaries re-register. `POST /signals/:signal_name/trigger` returns 503
until `SignalSubscriptions.mark_ready/0` is called by the resume pipeline
(same readiness gate as `MessageSubscriptions` in §3.5.5).

**Infrastructure modules.**

| Module | Domain | Purpose |
|--------|--------|---------|
| `EvilEngine.Events.SignalPublisher` | core_events | Orchestrates the broadcast pipeline |
| `EvilEngine.Events.SignalSubscriptions` | core_events | ETS-backed GenServer for in-memory subscriptions |
| `EvilEngine.Events.SignalPersistence` | core_events | Behaviour for signal audit + pending persistence |
| `EvilEngine.Persistence.SignalPersistenceAdapter` | peripheral_persistence | Ash-backed implementation |
| `EvilEngine.Execution.SignalStartHandler` | core_execution | Starts PIs from Signal Start Events |
| `EvilEngineWeb.Http.SignalController` | api_web | REST endpoint `POST /signals/:signal_name/trigger` |
| `EvilEngine.EngineFacade.Signals` | engine_sdk | Plugin facade namespace (`signals.publish/1`) |

**Broadcast pipeline.** `SignalPublisher.publish_signal/1` runs:

1. Generate UUID signal ID.
2. Insert audit row in `signals` table (no payload, no correlation).
3. ETS lookup for matching subscriptions by `signal_name`.
4. Deliver `{:signal_arrived, signal_id}` to each subscription via
   `send(via_pid, ...)`. Emit `%Event.SignalArrived{}` per delivery via
   `EngineEventBus`.
5. Simultaneously call `SignalStartHandler.start_processes_for_signal/1` —
   start new PIs from every deployed Signal Start Event matching the name
   (empty payload, `system:signal_trigger` identity).
6. If zero deliveries **and** zero start events fired → insert
   `pending_signals` with TTL.
7. Persist delivery list on the audit row (`signals.deliveries` jsonb).
8. Emit `%Event.SignalPublished{}` via `EngineEventBus`.
9. Return `{:ok, %PublishResult{}}`.

Steps 4 and 5 both run regardless of each other's results — a signal always
broadcasts to catch/boundary subscribers **and** starts new PIs at the same
time.

**Pending signal behavior.** When a signal has zero listeners and zero start
events at publish time, it is cached in `pending_signals` with a configurable
TTL (default `PT60S`, env `EVIL_SIGNAL_PENDING_TTL`, wired as
`config :core_events, :signal_pending_ttl`). The first subscriber that
registers and claims a pending row consumes it (FIFO drain per
`signal_name`) — subsequent subscribers do not receive that pending signal.
`SignalSubscriptions.register/1` queries in-TTL `pending_signals` rows for
the subscription's `signal_name`, delivers `{:signal_arrived, signal_id}` to
the registering `via_pid`, appends to `signals.deliveries`, and transitions
the pending row to `state='delivered'`.

**Orphan pending cleanup.** When a publish delivers to at least one live
subscriber or triggers at least one Signal Start Event, the publisher
cancels all existing `pending_signals` rows for that `signal_name` via
`cancel_pending_for_signal_name/1`. This prevents stale pending rows from
earlier zero-match publishes from being drained by the next subscriber that
registers after the live delivery has already occurred.

**`skip_pending` flag.** REST API signal triggers (`POST /signals/:name/trigger`)
pass `skip_pending: true` through `Api.publish_signal/3` to the publisher.
When set, the publisher never inserts a `pending_signals` row even on
zero-match — REST triggers are a debugging tool, not a standard procedure,
and should not leave pending rows that would be drained by future process
instances. BPMN throws and plugin facade calls do not set this flag — they
follow the standard pending-with-TTL behavior for publish-before-subscribe
races.

**TTL sweeper.** `EvilEngine.Events.PendingSweeper` scans `pending_messages`,
`pending_signals`, and `pending_escalations` on one tick (every 10 s by
default, `EVIL_PENDING_SWEEPER_INTERVAL`), flipping expired `pending` rows to
`expired`.

**Resume.** On engine boot, signal subscriptions re-register as each PI
rehydrates (same mechanism as §3.5.5 for messages). Each `register/1` call
drains matching in-TTL `pending_signals`, so a signal broadcast just before a
crash can still reach a PI that resumes within TTL.

**Handler dispatch.**

| BPMN element | Handler module |
|-------------|---------------|
| `<intermediateThrowEvent>` + SignalEventDef | `FlowNodes.SignalThrowEvent` |
| `<endEvent>` + SignalEventDef | `FlowNodes.SignalEndEvent` |
| `<intermediateCatchEvent>` + SignalEventDef | `FlowNodes.SignalCatchEvent` |
| `<boundaryEvent>` + SignalEventDef | `FlowNodes.SignalBoundaryEvent` |
| `<startEvent>` + SignalEventDef | `FlowNodes.SignalStartEvent` |

Catch and boundary handlers register via `SignalSubscriptions.register/1`
and block on `receive {:signal_arrived, signal_id}`. Throw handlers call
`SignalPublisher.publish_signal/1` synchronously. Signal Start Events are not
subscription-based — `ModelCache.find_signal_start_events/1` discovers them
at publish time via the `SignalStartHandler` callback.

**What this does not do.** Signals have no correlation — broadcast is global
within `signal_name`. Pending hold only closes the publish-before-register
race; it does not introduce retry or redelivery semantics. An already-delivered
signal is never re-delivered to the same subscription.

#### 3.5.7 Escalations (implemented — Phase 4)

An escalation propagates along the **scope chain** starting from the throw site. Propagation is deterministic and synchronous within the message-passing chain — there is no centralized walker function and no pending-escalation cache. Each handler Task and PI independently handles the escalation message it receives, one scope at a time.

**Propagation mechanism:**

```
Throw (child PI)
  → notify parent handler Task (CA / SubProcess)
    → EscalationResolver checks boundaries on host FlowNode
      → match   → fire boundary on parent PI
      → no match → passthrough to parent PI → propagate to grandparent handler Task
        → repeat until caught or root-of-root
```

**Handler-level messages:**
- `{:child_pi_escalation, pid, escalation_info}` — child PI terminated via Escalation End, parent handler checks boundaries on the CA/SP host node
- `{:child_pi_escalation_passthrough, pid, escalation_info}` — child PI sent an Escalation Intermediate Throw (token still running), parent handler checks boundaries on the CA/SP host node and recurses into `await_child_completion`

**PI-level messages:**
- `{:fni_result, id, {:escalation_end, info, result}}` — Escalation End Event FNI finished; PI interrupts siblings, sets `escalation_info`, maybe transitions to `:escalated`
- `{:fni_result, id, {:escalation_throw, info, result}}` — Escalation Intermediate Throw; PI dispatches outgoing token (PI keeps running), propagates to parent
- `{:escalation_passthrough, info}` — CA/SP no-matched passthrough; PI propagates further up
- `{:fni_result, id, {:escalation_end_propagate, info, result}}` — CA/SP host received uncaught End escalation from child; PI interrupts siblings, transitions to `:escalated`

**Uncaught at the root of the root PI:** Propagation stops. The affected PIs' terminal states are determined by the **throw element**:

- **Escalation End Event**: the throwing PI terminates in `:escalated`. Every ancestor PI through which the uncaught escalation propagated also terminates in `:escalated`; their Call Activity FNIs transition to `:interrupted`.
- **Escalation Intermediate Throw**: the PI keeps running. The token continues past the throw. Ancestor PIs are **not** touched — Intermediate Throws carry no PI-ending semantics even when uncaught.

In both cases, the leaf-most PI that reaches root-of-root without a catch emits `[:evil_engine, :escalation, :uncaught]` telemetry + `Logger.warning`. **No PI ever transitions to `fatal` because an escalation was uncaught** — `fatal` is reserved for engine/runtime faults.

**Interrupting vs. non-interrupting catches.** An **interrupting** Escalation Boundary Event cancels the host activity (child PI aborted) before routing the token out of the boundary. A **non-interrupting** one leaves the host running and spawns a parallel boundary-flow token. See `docs/architecture/execution.md` §Escalation Events for full state semantics.

**Invariants.**

- Escalations never broadcast — they reach at most one catch per scope, and after the first match propagation stops.
- Escalations never skip scope levels — every enclosing scope between the throw site and the catch must be examined in order.
- Escalations never reach unrelated PIs — the only PI-boundary hop allowed is child → parent via the handler Task that spawned the child.
- `EscalationResolver.find_first_interrupting_escalation_boundary/4` and `find_non_interrupting_escalation_boundaries/4` are the single boundary-resolution authority; they are called from CA and SubProcess handler Tasks.

##### 3.5.7.1 Pending-escalation hold (dropped — D1)

**Not implemented.** The pending-escalation hold described in earlier design documents was dropped in the Phase 4 implementation (decision D1).

**Rationale:** Escalation propagation is deterministic and synchronous. Boundaries are static BPMN elements attached to host activities — they are pre-spawned in `:waiting` state by the PI when the host activity's Task starts. There is no publish-before-register race condition for escalations, because the boundary FNI is already active when the child throws. No `pending_escalations` table, no `PendingSweeper` involvement, and no late-catch drain logic are needed.

Observable escalation outcomes are available via:
- `EscalationRaised` event (on every throw, caught and uncaught)
- `[:evil_engine, :escalation, :raised]` telemetry
- `[:evil_engine, :escalation, :uncaught]` telemetry (at root-of-root when no catch found)
- `FlowNodeInstanceFinished` events on throw FNIs
- PI state transitions (`ProcessInstanceStateChanged` to `:escalated`)

#### 3.5.8 Event Subprocess start-event routing

An **Event Subprocess (ESP)** start event (`<bpmn:subProcess triggeredByEvent="true">`) is a **scope-owned** trigger: the scope PI registers it on init/resume via `FlowNodes.EventSubprocess.register_triggers/1` (aliased as `EspScope` in the PI) and it lies dormant until an event occurs within its enclosing scope. Routing differs by trigger kind. Execution semantics (interrupting vs non-interrupting, shell FNI, child PI) live in [execution.md](./execution.md) §Event Subprocess Handler; this section covers **routing/precedence only**.

**Message ESP starts (ESP-D13 / ESP-D13b).** Registered in `MessageSubscriptions` with kind `:event_subprocess_start`, but **excluded from the delivery set** and fired by `resolve_start_events` only when `deliveries == []` — the same gate as standalone Message Starts, ordered **before** them. Precedence ladder for `(name, correlation)`:

1. **Inline Message Catch / Message Boundary** (existing broadcast-within-key fan-out) — always consumes.
2. **ESP Message Start** of a running scope (correlated) — fires only if tier 1 delivered to nothing; no new PI is created.
3. **Standalone Message Start** — new PI, only if tiers 1 and 2 are both empty.

A Catch/Boundary always beats an ESP Message Start (correlate-to-existing-catch), and an ESP Message Start beats a Standalone Message Start (correlate-to-existing-instance). Two peer ESP Message Starts in the same scope with the same key both fire.

**Signal ESP starts (ESP-D13c).** Registered in `SignalSubscriptions` with kind `:event_subprocess_start`. Signals are broadcast-all with **no** catch-wins-over-Start gate — an ESP Signal Start fires **alongside** any active Signal Catch/Boundary and any standalone Signal Start for the same `signal_name`. A non-interrupting ESP Signal Start published twice fires twice (two independent child PIs).

**Timer / Conditional ESP starts.** No cross-entity routing conflict — each is an independent trigger. Timer starts arm the `Scheduler` relative to **scope activation** (not deploy time) and fire via the PI `:info` message `{:timer_fired, ref, %{kind: :event_subprocess_start, subprocess_node_id: ...}}`; `timeCycle` re-arms per tick (scope-owned), date/duration are one-shot. Conditional starts are **edge-triggered** (fire on a `false → true` transition of the FEEL condition), re-evaluated on every scope FNI state change.

**Error / Escalation ESP starts.** Not subscription-based — resolved **reactively** at raise time by `EvilEngine.Execution.EventSubprocessResolver` (`find_matching_error_start/2` / `find_matching_escalation_start/2`). A scope-level ESP catches an error/escalation raised in its scope **before** it propagates to the parent (proximity), and a specific code beats a catch-all ESP start within the same scope (specificity). A boundary on the throwing activity is always tested before the scope ESP (boundary and ESP occupy different proximity levels), so boundary-vs-ESP is decided by proximity, never specificity.

**Correlation at scope activation.** A message ESP start's `expected_correlation_value` is evaluated from `<evil:correlationKey>` against the scope's state at registration time (scope activation), exactly like a Catch/Boundary subscription (§3.5.2). If the scope declares no `<evil:correlationKey>`, the ESP start matches only messages whose `correlation_value` is `:none`.

# Message, signal, and escalation routing

Messages are routed by `(message_name, correlation_value)`; Signals are
pure broadcast; Escalations bubble along a **scope chain** that walks upward
through enclosing subprocesses / event subprocesses and crosses **at most one
PI boundary per hop** — from a child PI up to its Call Activity FNI in the
parent — repeating until caught or until the root of the root PI is reached. Escalations never broadcast to unrelated PIs.

#### 3.5.1 Subscription registry (in-memory, per-node)

- A single `GenServer` per engine node (`BfwEngine.Events.MessageSubscriptions`) owns the registry. It is backed by ETS for O(1) lookup on `(message_name, correlation_value)`.
- A subscription row: `%Subscription{process_instance_id, flow_node_instance_id, flow_node_id, message_name, expected_correlation_value, kind :: :intermediate_catch | :boundary | :event_subprocess_start, registered_at, :via_pid}`.
- Intermediate Catch, Boundary Event (Message), and Event Subprocess Start Events share this registry — matching is identical across all three (the `kind` field is informational only, used for audit + debugging). The publisher and the pending drain use `kind` for one thing: an `:event_subprocess_start` row is told `{:event_subprocess_message, subprocess_node_id, payload}` instead of `{:message_arrived, …}` (§3.5.8).
- The registry is **in-memory only**. On engine restart it is empty until PIs resume; each PI re-evaluates `<bfw:correlationKey>` against its restored state and re-registers its active subscriptions before the Subscription GenServer declares itself "ready".
- **Lifecycle.** `via_pid` is the handler Task of a catch, boundary, or Receive Task, and the scope PI for an Event Subprocess start (whose `flow_node_instance_id` field holds the start event id). Rows are removed:
  - by the handler with `unregister/1` when its message arrives, or when its `park_async` write fails;
  - by the PI with `unregister_all_for_flow_node_instance/1` whenever it interrupts, aborts, or fatals a flow node instance from outside (host finished, sibling boundary fired, region cancel, Event-Based Gateway loser, PI abort/fatal, MI iteration cancel) through `ProcessInstance.HandlerDispatch.release_handler/4` — by flow node instance id, because a handler cancelled before its `{:async, …}` result reached the PI has not reported its `subscription_id` yet;
  - by the PI with `unregister_all_for_process_instance/1` on PI abort, fatal, and interrupting scope events;
  - by the publisher with `prune/1`: `publish_message/1` skips and prunes every matched row whose `via_pid` is no longer alive, so a dead waiter never counts as a delivery and never suppresses a start event or the pending hold. An Event Subprocess row of a live scope is never pruned.
- A resumed handler re-registers with a new `subscription_id` and reports it before `{:resume_settled, id}` through `FniLifecycle.record_resumed_subscription/2` (patched into the persisted `type_properties` and merged into the PI entry).
- `SignalSubscriptions` (§3.5.6) follows the same lifecycle with the same function names.

#### 3.5.2 Correlation value derivation

`<bfw:correlationKey>` is FEEL over PI state/context (catch-side subscribe).
`<bfw:correlationRetrievalExpression>` is FEEL over the published message
body / handler context (throw-side publish). Both results become a string in
`MessageEventHelper`: a string is used as is, a FEEL date, time, date-time or
duration becomes its ISO 8601 text (`date("2026-01-01")` correlates as
`"2026-01-01"`), FEEL `null` means no correlation value (`:none`), and
anything else goes through `to_string/1`; a value that cannot be converted
fails with `correlation_expression_failed`. Where each one runs:

- **Catch / Boundary / Event-Subprocess-Start subscribe**: PI's `<bfw:correlationKey>` evaluated against current PI state (token + Data Objects + `Identity`, see [expressions.md](./expressions.md) §8 context). Result cached on the `%Subscription{}` row as `expected_correlation_value`. A message Event Subprocess start binds `token` to its scope's start payload (§3.5.8).
  - If the process declares no `<bfw:correlationKey>`, the subscription's `expected_correlation_value` is `:none` — it matches any message whose `correlation_value` is `:none`.
- **Throw (Intermediate Throw / Message End Event / Send Task)**: `MessageEventHelper.resolve_throw_correlation/3` evaluates the `<bfw:correlationRetrievalExpression>` with `token` bound to the published message body (the `bfw:inputMapping` result). Throw events carry it inside `<bpmn:messageEventDefinition>`; a Send Task, which has no event definition, carries it in its own `<extensionElements>` (`FlowNodeData.SendTask.correlation_retrieval_expression`). Without the expression, `<bfw:correlationKey>` is evaluated against the same body. The result is stamped onto `messages.correlation_value` at publish time.
- **Subprocess scopes inherit the key.** An embedded, transaction, or ad-hoc subprocess scope runs on a synthetic process model that inherits the parent process's `<bfw:correlationKey>` (`ModelCache.fetch_subprocess_model/2`); the Studio models the key on `bpmn:Process` only. Catch **and** throw events inside the scope evaluate the inherited key against their own token: a catch subscribes with the result, a throw without `<bfw:correlationRetrievalExpression>` stamps it onto the published message. A called process (Call Activity) uses its own key.
- **API `POST /messages/{message_name}/trigger`**: caller supplies `correlation` in the request body. If absent, `correlation_value = :none`.
- **Message Start Event**: at the moment of starting a new PI from a message, `<bfw:correlationKey>` is evaluated against **the incoming payload** (there is no PI state yet), and the resulting value is seeded as the new PI's first correlation value. Subsequent subscriptions inside that PI re-evaluate `<bfw:correlationKey>` against the now-populated PI state.

#### 3.5.3 Publish-side algorithm

A published message `(name, payload, correlation_value)` flows through
`BfwEngine.Events.MessagePublisher.publish_message/1`:

1. Write a row to `messages` (audit — always, whether or not it correlates).
2. Look up the subscription registry with `(name, correlation_value)`. Collect **every** matching subscription (broadcast-within-key — serial-letter semantics).
3. For each matching subscription, send a typed `%Event.MessageArrived{}` to the owning PI's `:gen_statem` via its registered pid; the PI dispatches to the target FNI through its internal catch registry (see [execution.md](./execution.md)).
4. Record the delivery on `messages.correlations` as `[{process_instance_id, flow_node_instance_id}]` — one entry per delivery.
5. **Catch-wins-over-Start rule**: if step 2 yielded **zero** matching subscriptions, start new PIs from matching Message Start Events under the start discovery rule below (each seeding its own correlation value via §3.5.2). If step 2 yielded at least one match, Message Start Events are **not** triggered for this publish — the message is considered consumed by the subscription(s).
6. If step 2 yielded zero matching subscriptions **and** start discovery started no PI, move to §3.5.4.

**Start discovery rule.** A message start, a signal start (§3.5.6), and a cycle timer start fire (see [timers.md](./timers.md)) create **at most one PI per enabled process**, on that process's **latest live version** (newest `deployed_at` among enabled, non-deleted versions, resolved by `CalledElementResolver.resolve_latest_version/1`), and only if that version itself has the matching start event. An older version that still has the start event never starts a PI; a process whose latest live version dropped the start event starts nothing. The filter lives in `BfwEngine.Execution.StartEventDiscovery` (`latest_live_starts/1` for message and signal candidates from the `ModelCache` start-event index, `latest_live_version?/2` for cycle fires). The index is warmed at boot from the latest version of every process (`BfwEngine.Persistence.Application.warm_start_event_index/0`, before `ResumeRunner` opens the subscription registries), and soft-deleting a version fetches the new latest version into `ModelCache`. Stale index entries for older versions are harmless because the filter drops them.

**Event Subprocess Message Start interaction.** An ESP Message Start registers with the informational `:event_subprocess_start` kind but is **excluded from the delivery set** in step 2 — it is a gated Start Event, not a fan-out delivery. The full precedence ladder for a message `(name, correlation)` is: **(1)** inline Message Catch / Message Boundary (the broadcast-within-key fan-out of step 2), **(2)** ESP Message Start of a running scope (fires only when step 2 delivered to zero catch/boundary subscriptions, correlated at scope activation), **(3)** standalone Message Start Event (new PI). On a live publish a waiting Catch/Boundary therefore **always** beats an ESP Message Start, and an ESP Message Start beats a standalone Message Start (a running instance consumes the message before a new PI is created). A message held pending is drained by the first subscription that registers for its key, which can be an ESP start (§3.5.4). See §3.5.8.

#### 3.5.4 Unmatched publishes (pending with TTL)

Pending messages are held in the durable `pending_messages` table ([data-model.md](./data-model.md) §4.3) for
`BFE_MESSAGE_PENDING_TTL` (default 60 s) so that a subscription registering
shortly after publish still catches the message.

- On publish with zero matches (§3.5.3 step 6): insert a `pending_messages` row with `state='pending'`, `expires_at = published_at + BFE_MESSAGE_PENDING_TTL`.
- On every subscription register (`MessageSubscriptions.register/1`): drain pending messages for that `(name, expected_correlation_value)` — any pending rows still inside TTL are delivered immediately via §3.5.3 step 3 and their `state` set to `'delivered'`. An Event Subprocess start that registers at scope activation drains the same way and fires its Event Subprocess as on a live publish. This is intended: a pending row exists only because no subscription matched at publish time, so no Catch/Boundary was waiting that could lose the message; the first subscription of the key to register, Catch, Boundary, or Event Subprocess start, takes it.
- A periodic sweeper (every 10 s by default) transitions expired `pending` rows to `state='expired'` and emits a `warn` JSON log carrying the `message_id`, `name`, and `correlation_value`.
- `pending_messages` never holds Signals or Escalations — those are not TTL'd.
- **Delete-on-transition**: the post-transition row lifetime is governed by `BFE_PENDING_MESSAGES_KEEP_AFTER_TRANSITION` (default `true`). With the default, rows in `delivered`/`expired`/`cancelled` state persist until operator SQL ages them out (delivery-attempt audit). With the flag set to `false`, the engine physically deletes the row on deliver/expire/cancel (`destroy_if_pending` still requires `state == 'pending'`), so the table holds only rows still in flight.
- **Orphan pending cleanup**: when a publish delivers to at least one live subscriber or triggers a Message Start Event, the publisher cancels all existing `pending_messages` rows for that `(message_name, correlation_value)` via `cancel_pending_for_message/2`. This prevents stale pending rows from earlier zero-match publishes from being drained by the next subscriber that registers after a live delivery.
- **Known window — pending insert.** The publisher looks the registry up, then inserts the pending row. A subscription that registers between the two drains nothing, and the row waits for the next registration of that key within TTL (an interrupting catch never registers again). Not closed: closing it needs the lookup and the insert under one lock.
- **Known window — non-interrupting boundary re-register.** A non-interrupting message or signal boundary unregisters on each fire and registers again after notifying the PI. A publish in that gap sees no boundary subscription and falls through to an Event Subprocess start, a standalone start event, or the pending hold; a start it triggers cannot be undone.
#### 3.5.5 Resume / restart behavior

1. Engine boots; `MessageSubscriptions` GenServer is empty.
2. `BfwEngine.Execution.ResumeRunner` rehydrates every root `state='running'` PI from its PI row, all of its FNI rows, its `gateway_pending_arrivals`, and its `data_objects` (details in [execution.md](execution.md) §Resume on Startup). PI-scoped catch/boundary timers resume from FNI `type_properties` into Scheduler ETS; Cycle Timer Starts reload from `timer_start_schedules` via `StartEventManager.reload_start_schedules/0` (not per-PI).
3. As each PI resumes and its active catches/boundaries re-enter `waiting`, they re-register via `MessageSubscriptions.register/1` (re-evaluating `<bfw:correlationKey>` against restored PI state).
4. Each `register/1` call drains `pending_messages` for its `(name, expected_correlation_value)` — this is the mechanism that lets a message published seconds before a restart still reach its target PI after resume (provided `expires_at` has not elapsed).
5. The engine does not declare itself "ready" until every resumed PI, children included, has reported its subscriptions re-registered (`ProcessInstance.await_resume_settled/2`). Until then REST and plugin publishes answer 503, and in-engine publishes (throw events) wait in `MessageSubscriptions.await_ready/1` / `SignalSubscriptions.await_ready/1` (30 s cap), so neither can fall through to a start event before the catchers are back.

#### 3.5.6 Signals

Signals skip §3.5.2–§3.5.3 (no correlation, no payload) but follow the same
pending-with-TTL resume-race model as Messages. The single entry point
is `BfwEngine.Events.SignalPublisher.publish_signal/1`.

**Overview.** Signal events use a broadcast model — every active subscriber
for a given `signal_name` receives the signal simultaneously. Unlike messages,
signals have:

- **No payload**: Signals carry no data. The token passes through unchanged.
- **No correlation**: Signals match by `signal_name` only. No
  `<bfw:correlationKey>` or `<bfw:correlationRetrievalExpression>`.
- **True broadcast to all event types**: When a signal is published, ALL
  matching Signal Catch Events, Signal Boundary Events, AND Signal Start Events
  fire simultaneously. There is no catch-wins-over-Start gating (contrast
  §3.5.3 step 5).

**Subscription registry.** A single `GenServer` per engine node
(`BfwEngine.Events.SignalSubscriptions`) owns the registry. It is backed by
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
| `BfwEngine.Events.SignalPublisher` | core_events | Orchestrates the broadcast pipeline |
| `BfwEngine.Events.SignalSubscriptions` | core_events | ETS-backed GenServer for in-memory subscriptions |
| `BfwEngine.Events.SignalPersistence` | core_events | Behaviour for signal audit + pending persistence |
| `BfwEngine.Persistence.SignalPersistenceAdapter` | peripheral_persistence | Ash-backed implementation |
| `BfwEngine.Execution.SignalStartHandler` | core_execution | Starts PIs from Signal Start Events |
| `BfwEngineWeb.Http.SignalController` | api_web | REST endpoint `POST /signals/:signal_name/trigger` |
| `BfwEngine.EngineFacade.Signals` | engine_sdk | Plugin facade namespace (`signals.publish/1`) |

**Broadcast pipeline.** `SignalPublisher.publish_signal/1` runs:

1. Generate UUID signal ID.
2. Insert audit row in `signals` table (no payload, no correlation).
3. ETS lookup for matching subscriptions by `signal_name`.
4. Deliver `{:signal_arrived, signal_id}` to each subscription via
   `send(via_pid, ...)`. Emit `%Event.SignalArrived{}` per delivery via
   `EngineEventBus`.
5. Simultaneously call `SignalStartHandler.start_processes_for_signal/1` —
   start new PIs from Signal Start Events matching the name under the start
   discovery rule (§3.5.3) (empty payload, `system:signal_trigger` identity).
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
TTL (default `PT60S`, env `BFE_SIGNAL_PENDING_TTL`, wired as
`config :core_events, :signal_pending_ttl`). The first subscriber that
registers and claims a pending row consumes it (FIFO drain per
`signal_name`) — subsequent subscribers do not receive that pending signal.
`SignalSubscriptions.register/1` queries in-TTL `pending_signals` rows for
the subscription's `signal_name`, delivers `{:signal_arrived, signal_id}` to
the registering `via_pid` (an Event Subprocess start is told
`{:event_subprocess_signal, subprocess_node_id}` and fires), appends to
`signals.deliveries`, and transitions the pending row to `state='delivered'`.

**Orphan pending cleanup.** When a publish delivers to at least one live
subscriber or triggers at least one Signal Start Event, the publisher
cancels all existing `pending_signals` rows for that `signal_name` via
`cancel_pending_for_signal_name/1`. This prevents stale pending rows from
earlier zero-match publishes from being drained by the next subscriber that
registers after the live delivery has already occurred.

**TTL sweeper.** `BfwEngine.Events.PendingSweeper` scans `pending_messages`
and `pending_signals` on one tick (every 10 s by
default, `BFE_PENDING_SWEEPER_INTERVAL`), flipping expired `pending` rows to
`expired`. Escalations are not held in a pending table (escalation D1).

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

#### 3.5.7 Escalations

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
- `{:escalation_passthrough, info}` — CA/SP no-matched passthrough; the PI first tries its own escalation Event Subprocess starts (`EspScope.resolve_escalation_catch/2`, same as an Escalation Throw raised in that scope), then propagates further up
- `{:fni_result, id, {:escalation_end_propagate, info, result}}` — CA/SP host received uncaught End escalation from child; PI interrupts siblings, transitions to `:escalated`

**Uncaught at the root of the root PI:** Propagation stops. The affected PIs' terminal states are determined by the **throw element**:

- **Escalation End Event**: the throwing PI terminates in `:escalated`. Every ancestor PI through which the uncaught escalation propagated also terminates in `:escalated`; their Call Activity FNIs transition to `:interrupted`.
- **Escalation Intermediate Throw**: the PI keeps running. The token continues past the throw. Ancestor PIs are **not** touched — Intermediate Throws carry no PI-ending semantics even when uncaught.

In both cases, the leaf-most PI that reaches root-of-root without a catch emits `[:bfw_engine, :escalation, :uncaught]` telemetry + `Logger.warning`. **No PI ever transitions to `fatal` because an escalation was uncaught** — `fatal` is reserved for engine/runtime faults.

**Interrupting vs. non-interrupting catches.** An **interrupting** Escalation Boundary Event cancels the host activity (child PI aborted) before routing the token out of the boundary. A **non-interrupting** one leaves the host running and spawns a parallel boundary-flow token. See `docs/architecture/execution.md` §Escalation Events for full state semantics.

**Invariants.**

- Escalations never broadcast — they reach at most one catch per scope, and after the first match propagation stops.
- Escalations never skip scope levels — every enclosing scope between the throw site and the catch must be examined in order.
- Escalations never reach unrelated PIs — the only PI-boundary hop allowed is child → parent via the handler Task that spawned the child.
- `EscalationResolver.find_first_interrupting_escalation_boundary/4` and `find_non_interrupting_escalation_boundaries/4` are the single boundary-resolution authority; they are called from CA and SubProcess handler Tasks.

##### 3.5.7.1 Pending-escalation hold

**Not implemented.** Escalations are not held pending.

**Rationale:** Escalation propagation is deterministic and synchronous. Boundaries are static BPMN elements attached to host activities — they are pre-spawned in `:waiting` state by the PI when the host activity's Task starts. There is no publish-before-register race condition for escalations, because the boundary FNI is already active when the child throws. No `pending_escalations` table, no `PendingSweeper` involvement, and no late-catch drain logic are needed.

Observable escalation outcomes are available via:
- `EscalationRaised` event (on every throw, caught and uncaught)
- `[:bfw_engine, :escalation, :raised]` telemetry
- `[:bfw_engine, :escalation, :uncaught]` telemetry (at root-of-root when no catch found)
- `FlowNodeInstanceFinished` events on throw FNIs
- PI state transitions (`ProcessInstanceStateChanged` to `:escalated`)

#### 3.5.8 Event Subprocess start-event routing

An **Event Subprocess (ESP)** start event (`<bpmn:subProcess triggeredByEvent="true">`) is a **scope-owned** trigger: the scope PI registers it on init/resume via `FlowNodes.EventSubprocess.register_triggers/1` (aliased as `EspScope` in the PI) and it lies dormant until an event occurs within its enclosing scope. Routing differs by trigger kind. Execution semantics (interrupting vs non-interrupting, shell FNI, child PI) live in [execution.md](./execution.md) §Event Subprocess Handler; this section covers **routing/precedence only**.

**Message Event Subprocess starts.** Registered in `MessageSubscriptions` with kind `:event_subprocess_start`, but **excluded from the delivery set** and fired by `resolve_start_events` only when `deliveries == []` — the same gate as standalone Message Starts, ordered **before** them. Precedence ladder for `(name, correlation)`:

1. **Inline Message Catch / Message Boundary** (existing broadcast-within-key fan-out) — always consumes.
2. **ESP Message Start** of a running scope (correlated) — fires only if tier 1 delivered to nothing; no new PI is created.
3. **Standalone Message Start** — new PI, only if tiers 1 and 2 are both empty.

On a live publish a waiting Catch/Boundary always beats an ESP Message Start (correlate-to-existing-catch), and an ESP Message Start beats a Standalone Message Start (correlate-to-existing-instance); a pending message goes to whichever subscription of its key registers first (§3.5.4). Two peer ESP Message Starts in the same scope with the same key both fire.

**Signal Event Subprocess starts.** Registered in `SignalSubscriptions` with kind `:event_subprocess_start`. Signals are broadcast-all with **no** catch-wins-over-Start gate — an ESP Signal Start fires **alongside** any active Signal Catch/Boundary and any standalone Signal Start for the same `signal_name`. A non-interrupting ESP Signal Start published twice fires twice (two independent child PIs).

**Timer / Conditional ESP starts.** No cross-entity routing conflict — each is an independent trigger. Timer starts arm the `Scheduler` relative to **scope activation** (not deploy time) and fire via the PI `:info` message `{:timer_fired, ref, %{kind: :event_subprocess_start, subprocess_node_id: ...}}`; `timeCycle` is armed as a Scheduler cycle, date/duration are one-shot (details in [timers.md](./timers.md)). A timer start whose spec cannot be resolved to a fire time (a FEEL result that is not a date-time, duration, or cycle string, an invalid ISO 8601 text, a zero interval) makes `register_triggers/1` return `{:error, {:event_subprocess_timer_resolution_failed, subprocess_node_id, %{expression, reason}}, data}`; the scope PI goes fatal with that `error_info`, like a failing correlation key below. Conditional starts are **edge-triggered** (fire on a `false → true` transition of the FEEL condition), re-evaluated on every scope FNI state change, with `token` bound to the scope instance's start payload (the same binding as the message start correlation below, also after a resume).

**Error / Escalation ESP starts.** Not subscription-based — resolved **reactively** at raise time by `BfwEngine.Execution.EventSubprocessResolver` (`find_matching_error_start/2` / `find_matching_escalation_start/2`). A scope-level ESP catches an error/escalation raised in its scope **before** it propagates to the parent (proximity), and a specific code beats a catch-all ESP start within the same scope (specificity). A boundary on the throwing activity is always tested before the scope ESP (boundary and ESP occupy different proximity levels), so boundary-vs-ESP is decided by proximity, never specificity.

**Correlation at scope activation.** A message ESP start's `expected_correlation_value` is evaluated from `<bfw:correlationKey>` at registration time (scope activation), with the same context bindings as a Catch/Boundary subscription (§3.5.2) except that `token` is bound to the scope instance's start payload (`State.start_payload`): the start request's `payload` for a root instance, the token passed in after the shell's `bfw:inputMapping` for a Call Activity or subprocess child. On resume the payload is recovered from the input token of the scope's Start Event FNI (`Resumption.start_payload/1`; an ad-hoc scope without a Start Event uses its earliest FNI), so the correlation value is the same after a restart. The start request's `context` stays reachable as the `context` binding. If the scope declares no `<bfw:correlationKey>`, the ESP start matches only messages whose `correlation_value` is `:none`. If the expression fails, `register_triggers/1` returns `{:error, {:event_subprocess_correlation_failed, subprocess_node_id, %{expression, reason}}, data}` and the scope PI goes fatal with that error as its `error_info` (`ErrorInfo` names the Event Subprocess and the expression).
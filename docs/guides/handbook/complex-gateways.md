# Complex Gateways

Complex Gateways are Bifrost Forge World Engine's **opinionated, deterministic**
take on the BPMN 2.0 Complex Gateway. Where the BPMN specification leaves the
Complex Gateway deliberately under-defined ("you supply your own activation
rule"), this engine gives it a precise, predictable contract:

- a **conditional split** that looks like an Inclusive split but **forbids
  accidental unconditional fan-out**, and
- a single-fire **threshold join** that fires the moment a FEEL
  `activationCondition` becomes true — perfect for "proceed as soon as 2 of 3
  approvals arrive" style quorums.

> **Not portable BPMN.** These semantics are specific to
> Bifrost Forge World Engine. A model that relies on the Complex Gateway behaviours
> described here will **not** behave the same way (or at all) on other BPMN
> engines. If you need a portable model, use an [Inclusive
> Gateway](inclusive-gateways.md) instead. See
> [Inclusive vs Complex Gateways](#inclusive-vs-complex-gateways) below.

A Complex Gateway must be **either** a split (one incoming, many outgoing)
**or** a join (many incoming, one outgoing). A gateway with both multiple
incoming and multiple outgoing flows is a *mixed* gateway and is **rejected at
deploy time** (`complex_gateway_mixed`).

## Complex Split (Diverging)

A Complex Split has one incoming and multiple outgoing sequence flows. It
evaluates **all** outgoing conditional flows via FEEL and activates every path
whose condition is truthy — just like an Inclusive split — **with one crucial
difference**: there is no unconditional fall-through.

| Outcome | Behavior |
|---------|----------|
| 1+ conditions are `true` | All truthy paths are taken (tokens forked) |
| Zero conditions are `true`, default flow exists | Default flow only |
| Zero conditions are `true`, no default flow | PI transitions to `fatal` (`complex_split_no_matching_condition`) |
| Any expression evaluation fails | PI transitions to `fatal` (`complex_split_condition_failed`) |

### No unconditional fall-through

This is the defining rule of the Complex Split, and the single most important
thing to remember:

> **Every outgoing flow of a Complex Split must carry a `conditionExpression`
> OR be the gateway's `default` flow.**

An outgoing flow that has neither a condition nor the `default` marker is an
**unconditional non-default flow**. The engine **fatals at runtime** with
`complex_gateway_unconditional_flow` when the split is entered. The diagram
**still deploys** (WIP models are allowed). Studio lints a warning in
`bpmn-development` and an error in `bpmn-production-ready`. Mixed Complex
gateways, a join missing `activationCondition`, and SESE region violations
remain **deploy-time** rejects.

Contrast this with the [Inclusive Gateway](inclusive-gateways.md), which
*silently activates* unconditional flows alongside the truthy ones. On an
Inclusive split, forgetting a condition means the flow always fires — often a
subtle bug. On a Complex split, forgetting a condition fatals when the token
reaches the gateway. The default flow fires **only** when no conditional
flow matches.

### BPMN Example — Complex Split

```xml
<bpmn:complexGateway id="Split_Review" name="Route Review" default="Flow_Standard">
  <bpmn:incoming>Flow_In</bpmn:incoming>
  <bpmn:outgoing>Flow_Legal</bpmn:outgoing>
  <bpmn:outgoing>Flow_Finance</bpmn:outgoing>
  <bpmn:outgoing>Flow_Standard</bpmn:outgoing>
</bpmn:complexGateway>

<bpmn:sequenceFlow id="Flow_Legal" sourceRef="Split_Review" targetRef="Task_Legal">
  <bpmn:conditionExpression>token.amount &gt; 100000</bpmn:conditionExpression>
</bpmn:sequenceFlow>

<bpmn:sequenceFlow id="Flow_Finance" sourceRef="Split_Review" targetRef="Task_Finance">
  <bpmn:conditionExpression>token.needsFinance = true</bpmn:conditionExpression>
</bpmn:sequenceFlow>

<bpmn:sequenceFlow id="Flow_Standard" sourceRef="Split_Review" targetRef="Task_Standard" />
```

- If `amount > 100000` **and** `needsFinance` is `true`, both `Task_Legal` and
  `Task_Finance` run in parallel.
- If neither matches, `Task_Standard` runs (the default).
- If you added a fourth outgoing flow with no condition and no `default`,
  entering the split is a **runtime fatal** (`complex_gateway_unconditional_flow`).
  The diagram still deploys; Studio lints warning (`bpmn-development`) / error
  (`bpmn-production-ready`).

## Complex Join (Converging) — Threshold Join

A Complex Join waits for tokens from its incoming branches and fires **once**,
the moment its FEEL `activationCondition` becomes `true`. This is a
**threshold** (or *quorum*) join: you decide, in FEEL, how many branches must
arrive before the process continues.

Unlike the [Inclusive Join](inclusive-gateways.md#or-join-converging), which
fires based purely on structural dead-path elimination, the Complex Join is
driven by an explicit condition you write.

### The `activationCondition`

The join's fire rule lives in a standard BPMN `<bpmn:activationCondition>`
child element. It is a FEEL expression that, in addition to the usual bindings
(`token`, `context`, `dataObjects`, `process`, `processInstance`, `identity`),
receives two special counters:

| Binding | Meaning |
|---------|---------|
| `activatedCount` | How many incoming branches have delivered a token **so far** |
| `incomingCount` | The total number of incoming sequence flows into the join |

Common conditions:

- `activatedCount >= 2` — fire as soon as any 2 branches arrive (a 2-of-N quorum).
- `activatedCount = incomingCount` — wait for **every** branch (behaves like a strict join).
- `activatedCount >= incomingCount - 1` — fire when all but one branch has arrived.

During the evaluation, `token` is the **merge of all branch payloads that have
arrived so far**, so you can also write data-driven conditions such as
`activatedCount >= 2 and token.approved = true`.

`<bpmn:activationCondition>` is **required** for a Complex Join. Deploying a
join without one is rejected with
`complex_gateway_join_missing_activation_condition`.

### How the join decides: fire, wait, or error

The engine re-evaluates the join **on every token arrival** and **after every
flow node state change** in the process instance. Each time, it decides:

1. **Fire** — the `activationCondition` is `true`. The join merges the arrived
   branch payloads (last-wins per key) and continues along its single outgoing
   flow. This happens **exactly once**.
2. **Wait** — the condition is `false`, but at least one branch could still
   deliver a token. The join keeps waiting.
3. **Error** — the condition is `false` **and** every incoming branch
   has either already arrived or is now dead (no upstream activity can still
   reach the join). The threshold can never be met, so the join FNI transitions
   to `fatal` with `complex_join_condition_unmet` and a message such as *"all
   branches have finished but the gateway's activation condition
   'activatedCount >= 3' was not met (activatedCount=2, incomingCount=3)"*.

An impossible quorum fails loudly and immediately, rather than leaving the
process silently stuck.

### Worked example — "2 of 3"

Imagine three reviewers working in parallel; you want to proceed as soon as any
two of them respond.

```xml
<bpmn:complexGateway id="Join_Reviews" name="2 of 3 reviewers">
  <bpmn:incoming>Flow_R1</bpmn:incoming>
  <bpmn:incoming>Flow_R2</bpmn:incoming>
  <bpmn:incoming>Flow_R3</bpmn:incoming>
  <bpmn:outgoing>Flow_Decide</bpmn:outgoing>
  <bpmn:activationCondition>activatedCount &gt;= 2</bpmn:activationCondition>
</bpmn:complexGateway>
```

- Reviewer 1 responds → `activatedCount = 1` → condition `false` → **wait**.
- Reviewer 2 responds → `activatedCount = 2` → condition `true` → **fire**. The
  process continues to `Flow_Decide` immediately, without waiting for
  reviewer 3.
- Reviewer 3's branch is a *loser*. When the join fires, the engine actively
  **cancels** reviewer 3's still-open task (see [Scoped Cancellation](#scoped-cancellation)
  below), so it is not left dangling and no straggler token can reach the
  already-fired join.

If you had instead written `activationCondition` as `activatedCount >= 3` but
one reviewer's branch died (e.g. an upstream exclusive gateway sent the token
elsewhere), the join would fail: all branches resolved,
`activatedCount` stuck at 2, threshold of 3 unreachable → `fatal`
(`complex_join_condition_unmet`).

### Token merge at the join

When the join fires, all arrived branch payloads are merged using "last-wins
per key" — identical to Parallel and Inclusive joins:

```
Branch R1 token: { "caseId": "42", "r1": "approve" }
Branch R2 token: { "caseId": "42", "r2": "approve" }
→ Merged:        { "caseId": "42", "r1": "approve", "r2": "approve" }
```

## Scoped Cancellation

A threshold join fires the moment its quorum is reached — but the branches that
lost the race may still be running (a reviewer still has their task open, a
timer is still counting down, a service call is still in flight). The winning
fire **cancels the losing branches** so nothing is left dangling.

Crucially, this cancellation is **scoped**. It only touches the work that lives
**between the Complex Split that opened the branches and the Complex Join that
closes them** — a region called a **SESE region** (Single-Entry,
Single-Exit). Work elsewhere in the process is never affected.

### The Split ↔ Join pairing

Every Complex Join is **paired with exactly one Complex Split** — the nearest
enclosing Complex Split "above" it in the flow. The block of flow nodes between
that split and the join is the region that gets cancelled when the join fires.

This pairing is mandatory and is checked **at deploy time**. A model is rejected
if:

| Problem | Deploy error | Meaning |
|---------|--------------|---------|
| The join has no Complex Split above it | `complex_join_no_paired_split` | There is nothing to pair the join with — a Complex Join must sit downstream of a Complex Split |
| A branch escapes the region | `complex_region_cross_boundary` | A sequence flow leaves the block somewhere other than through the split (entry) or the join (exit) — the region is not "single-entry / single-exit" |
| Two regions partially overlap | `complex_region_overlap` | Regions must either be completely separate or **fully nested** — they may not partially cross each other |

These rules guarantee the region is always a clean, well-bounded block, so
"cancel the losers" has an unambiguous meaning.

### What gets cancelled — and what does not

When the join fires:

- **Cancelled:** every flow node **inside the region** that is still `active`
  or `waiting` — open user tasks, running timers, in-flight service tasks, and
  even entire child processes started by a Call Activity or SubProcess inside
  the region. Each cancelled activity runs its normal cleanup (subscriptions
  removed, timers stopped, child processes aborted) and is recorded as
  `interrupted` with the reason `cancelled_by_complex_join`.
- **Not touched:** anything **outside the region** — including parallel work
  that belongs to an *enclosing* region. The process-wide message and signal
  subscriptions are also left intact (this is a *scoped* cancellation, not a
  process-wide terminate).

### Worked example — fastest 2 of 3, cancel the loser

Reusing the "2 of 3 reviewers" model, with the three reviewer tasks sitting
between a Complex Split and the `Join_Reviews` Complex Join:

1. The split forks to Reviewer 1, Reviewer 2, and Reviewer 3 (three open user
   tasks).
2. Reviewer 1 finishes → `activatedCount = 1` → the join **waits**.
3. Reviewer 2 finishes → `activatedCount = 2` → the join **fires**.
4. Reviewer 3's task is still open. Because it lives inside the split→join
   region, it is **cancelled** (`interrupted`, reason
   `cancelled_by_complex_join`). The reviewer's task disappears from their
   worklist; nothing is left waiting.
5. The process continues past the join with the merged payload of reviewers 1
   and 2.

### Nested regions

Regions may be **nested** (a complex split/join pair entirely inside another).
Cancellation respects the nesting: when an **inner** join fires, it cancels only
the **inner** region. Any branches belonging to the **outer** region keep
running untouched, and the outer join still waits for its own threshold.

For example, an inner "fastest 1 of 2" that fires and cancels its loser does
**not** disturb a separate outer-region user task running in parallel — that
task keeps waiting until the outer join's own condition is met.

### Resume after restart

Scoped cancellation survives an engine restart. If the engine stops while a
complex region is still open, resuming the process rehydrates the join and
re-evaluates its `activationCondition`, so it can still fire and cancel the
losing branches correctly.

## Inclusive vs Complex Gateways

Inclusive and Complex Gateways can look almost identical on the canvas — both
route along conditional paths and both merge multiple branches. Their
behaviours are **deliberately different**. Use this table to keep them
straight:

| Aspect | Inclusive Gateway | Complex Gateway |
|--------|-------------------|-----------------|
| Split — flow with no condition, not default | **Silently activated** (always fires) | **Deploy error** — every flow must be conditional or default |
| Split — zero truthy, default present | Default flow only | Default flow only (same) |
| Split — zero truthy, no default | `fatal` (`no_matching_condition`) | `fatal` (`complex_split_no_matching_condition`) |
| Join — what makes it fire | Dead-path elimination: all live paths arrived | A FEEL `activationCondition` becomes true |
| Join — inputs you control | None (structural only) | `activatedCount`, `incomingCount`, and the merged `token` |
| Join — threshold / quorum | Not supported | Yes — that is its whole purpose |
| Join — impossible / unmet condition | N/A (fires with whatever arrived) | `fatal` (`complex_join_condition_unmet`) |
| Join — losing branches on fire | Left to complete | Cancelled within the paired SESE region |
| Split ↔ Join pairing | None | Mandatory 1:1; unpaired / leaky / overlapping regions rejected at deploy |
| Portable BPMN | Yes (standard) | No (engine-specific) |

### When to use which

- **Reach for an [Inclusive Gateway](inclusive-gateways.md) first.** It is the
  portable, standards-compliant choice for OR-split / OR-join: activate every
  matching path, then merge when all live paths have arrived. This covers the
  large majority of "some of these paths, then rejoin" scenarios.

- **Reach for a Complex Gateway when you specifically need one of these:**
  - a **quorum / threshold** merge — "continue as soon as *N* of *M* branches
    arrive" (`activatedCount >= N`);
  - a split that **refuses to silently fan out** — you want every outgoing flow
    to be an explicit decision (conditional or default), enforced at deploy;
  - a winning branch that should **cancel the losers** inside a bounded SESE
    region.

  In exchange for these capabilities you give up BPMN portability and opt into
  engine-specific semantics.

## Mixed Gateways

A Complex Gateway with **both** multiple incoming and multiple outgoing flows
is a *mixed* gateway and is **rejected at deploy** (`complex_gateway_mixed`).
As a defensive fallback it is also rejected at runtime (`mixed_gateway`). Model
splitting and joining as two separate Complex Gateway nodes.

## Error States

| Error | Cause | When |
|-------|-------|------|
| `complex_gateway_mixed` | Gateway has both >1 incoming and >1 outgoing flows | Deploy |
| `complex_gateway_unconditional_flow` | A Complex Split has an outgoing flow that is neither conditional nor the default | Runtime (`fatal`) |
| `complex_gateway_join_missing_activation_condition` | A Complex Join has no `<bpmn:activationCondition>` | Deploy |
| `complex_split_no_matching_condition` | No outgoing condition is truthy and there is no default flow | Runtime (`fatal`) |
| `complex_split_condition_failed` | A FEEL condition on an outgoing flow failed to evaluate | Runtime (`fatal`) |
| `complex_join_condition_unmet` | All branches resolved but the `activationCondition` was never met | Runtime (`fatal`) |
| `complex_join_condition_failed` | The `activationCondition` FEEL expression failed to evaluate | Runtime (`fatal`) |
| `complex_join_no_paired_split` | A Complex Join has no dominating Complex Split to pair with | Deploy |
| `complex_region_cross_boundary` | A branch escapes the split→join region other than through the split or join (not single-entry / single-exit) | Deploy |
| `complex_region_overlap` | Two complex regions partially overlap instead of being disjoint or fully nested | Deploy |

## Retry

Like all join gateway FNIs, a Complex Join is an **invalid retry checkpoint** —
retrying with a Complex Join as the reset target returns HTTP 422
(`retry_checkpoint_is_join_gateway`). Retry from an upstream task or the process
start instead.

## Related

- [Inclusive Gateways](inclusive-gateways.md) -- the portable OR-gateway; read this first
- [Exclusive Gateways](exclusive-gateways.md) -- exactly-one-path routing
- [Parallel Gateways](parallel-gateways.md) -- unconditional fork/join
- [FEEL Expressions](expressions.md) -- expression syntax and context bindings
- [Error Handling](error-handling.md) -- fatal states and encounter-time validation
- [Deploying Processes](deploying-processes.md) -- deploy processes with gateways

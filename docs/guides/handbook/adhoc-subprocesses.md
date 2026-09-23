# Ad-hoc Sub-Process

An **Ad-hoc Sub-Process** (`bpmn:adHocSubProcess`) is a "menu" or "toolbox" of
activities that can be activated in any order — or in an engine- or
plugin-controlled order — instead of following a fixed sequence flow. It is
the BPMN 2.0 construct for unstructured work: a set of tasks that all belong
to the same unit of work, where the *modeler* does not (and cannot) know in
advance which tasks will run, how many times, or in what order.

> **Prerequisite reading.** An Ad-hoc Sub-Process spawns a child process
> instance exactly like an [Embedded Subprocess](embedded-subprocesses.md) —
> read that guide first if you are not already familiar with the shell/child-PI
> pattern. Everything about data pipeline (`bfw:inputMapping` /
> `bfw:outputMapping`) and boundary events carries over unchanged.

---

## §1 What is an Ad-hoc Sub-Process?

Visually, an Ad-hoc Sub-Process is a subprocess shape with a tilde (`~`)
marker in its bottom-left corner (the standard BPMN 2.0 ad-hoc marker,
rendered identically in the Studio and in `bpmn.io`). Inside, you place plain
activities — tasks, call activities, even further embedded subprocesses —
with **no Start Event and no End Event**, and with sequence flows used only
to express optional dependencies between a handful of activities, not the
overall execution order.

| | Embedded Subprocess | Ad-hoc Sub-Process |
|---|---|---|
| Execution order | Fixed by sequence flow topology | Undetermined; activities activate independently |
| Start/End Events | Required (exactly one Start) | **Forbidden** |
| "Done" signal | Reaching an End Event | A completion condition, or every activity performed once, or an explicit `complete` call |
| Typical use | A known process (e.g. "review then approve") | A known *set of possible actions* with an unknown order (e.g. "an agent's toolbox", "a checklist") |

### When to use it vs. alternatives

- **Embedded Subprocess** — you know the order tasks must run in. Use plain
  sequence flow.
- **Call Activity** — you want to reuse a whole separate process definition.
  Ad-hoc sub-processes are inline, not separately deployed/versioned.
- **Event Subprocess** — you want to react to *one* triggering event (message,
  timer, error, ...) that happens zero-or-more times within a scope. Ad-hoc is
  about a *set* of activities that get worked through, not a single reactive
  handler.
- **Ad-hoc Sub-Process** — you have a bounded set of possible actions and
  either a rule-based way to decide which run (engine-managed), or an external
  decision-maker — a human, a plugin, or an AI agent — who picks (plugin-managed).

---

## §2 Execution Modes

The `implementation` attribute on `<bpmn:adHocSubProcess>` selects between two
fundamentally different execution models.

### §2.1 Engine-managed mode (no `implementation` attribute)

The engine itself decides which activities to activate and when, using two
optional controls:

- **`bfw:activeElements`** — a FEEL expression, evaluated once when the
  ad-hoc scope starts, that must return a list of flow node IDs. Those
  activities are activated immediately.
- **No `bfw:activeElements`** — every inner activity that has **no incoming
  sequence flow** (the "enabled set") auto-activates immediately.
  Activities that *do* have an incoming sequence flow become enabled only
  after their predecessor finishes (§5).

Best for deterministic, rule-driven activation patterns where the set of
activities to run can be computed up front from the process token.

> **Example — "Onboarding Checklist".** A new-employee onboarding process with
> five independent tasks: order laptop, create accounts, assign desk, schedule
> orientation, request badge. None depends on any other. All five have no
> incoming sequence flow, so all five auto-activate the moment the ad-hoc
> scope starts. No `completionCondition` is set, so the subprocess
> auto-completes once every task has been performed at least once (§4.3).

### §2.2 Plugin-managed mode (`implementation` attribute set)

The plugin — not the engine — decides which activities run and when. The
engine exposes the toolbox via the `EngineFacade.adhoc_subprocesses` namespace
(REST equivalents also exist):

| Facade closure | REST endpoint | Purpose |
|-----------------|----------------|---------|
| `get_enabled_activities.(child_process_instance_id)` | `GET /adhoc-subprocesses/{id}/activities` | List inner activities with `enabled`, `performed_count`, `active_count` |
| `activate_activity.(child_process_instance_id, activity_id)` | `POST /adhoc-subprocesses/{id}/activities/{activity_id}/activate` | Start one inner activity, returning its new FNI ID |
| `complete.(child_process_instance_id)` | `POST /adhoc-subprocesses/{id}/complete` | Signal that no further activities should start |
| `get_status.(child_process_instance_id)` | `GET /adhoc-subprocesses/{id}/status` | Poll active/performed/enabled state and whether completion was signaled |

All four take the **ad-hoc scope's own child process instance ID** — never the
parent PI or the shell flow node instance ID. That ID arrives via
`SubProcessChildStarted.childProcessInstanceId` (with
`isAdHocSubprocess: true`) when the scope starts, and is echoed as
`processInstanceId` on every subsequent `AdHocActivityActivated` /
`AdHocSubProcessCompleted` event for that scope.

A typical plugin lifecycle: receive `SubProcessChildStarted` (or the plugin's
own `handle_enter`, for a plugin implementing a dedicated ad-hoc handler) →
call `get_enabled_activities` → activate one or more → listen for
`FlowNodeInstanceFinished` on the inner activities → decide the next move →
eventually call `complete`.

Best for dynamic decision-making, external system integration, and
human-in-the-loop workflows.

> **Example — "AI Agent Toolbox".** An AI agent receives a customer inquiry.
> The ad-hoc sub-process contains tools: `LookupOrder`, `CheckInventory`,
> `CreateTicket`, `SendEmail`, `EscalateToHuman`. The AI plugin inspects the
> inquiry, picks tools based on reasoning, may call `LookupOrder` multiple
> times with different parameters (the same activity can be
> activated more than once; each call creates a new FNI), and calls `complete`
> once the inquiry is resolved. See the fully worked example plugin in
> `examples/plugins/adhoc/ai_toolbox/`.

> **Example — "Repair Workshop".** A mechanic receives a car. The ad-hoc
> sub-process contains: `DiagnoseEngine`, `ReplaceOil`, `CheckBrakes`,
> `RotateTires`, `Repaint`. Rather than a plugin, a thin REST-backed UI lets
> the mechanic pick tasks based on the diagnosis result, calling
> `POST /adhoc-subprocesses/{id}/activities/{activity_id}/activate` directly
> from a web form.

---

## §3 Ordering: Parallel vs. Sequential

The `ordering` attribute (`Parallel` or `Sequential`, default `Parallel`)
controls how many inner activities may be active at once.

### §3.1 Parallel ordering (default)

Multiple activities may be active simultaneously; there is no engine-imposed
mutual exclusion between them. `bfw:activeElements` is optional here — it
only narrows the *initial* set, it does not impose an order among them.

> **Example — "Document Processing Pipeline".** Extract metadata, scan for
> PII, generate thumbnail, validate format. All four are independent and all
> four run at the same time.

### §3.2 Sequential ordering

At most one inner activity is active at a time.

- **Engine-managed + Sequential requires `bfw:activeElements`**. The
  *order of the list* returned by the FEEL expression is used only to pick the
  **first** matching ID. Sequential engine-managed mode activates that one
  activity at start; remaining list IDs are logged and ignored. After it
  finishes, `AdHocMode` auto-chain activates the next unperformed inner
  activity in **model order** (not the leftover FEEL list). Plugin/REST
  `activate_activity` is how a caller drives a different next step.
  Deploying (or linting in `bpmn-production-ready`) a sequential, engine-managed
  ad-hoc sub-process without `bfw:activeElements` is rejected — without an
  explicit ordering expression the engine has no deterministic basis for
  picking the first activity.
- **Plugin-managed + Sequential**: the plugin is responsible for activating
  one activity at a time. If it calls `activate_activity` while another inner
  FNI is still active/waiting, the call fails with
  `{:error, :adhoc_sequential_busy}` — treat that as "wait for the current
  activity's `FlowNodeInstanceFinished`", not as a fatal condition.

Best for tasks that depend on each other's results, rate-limited operations,
or step-by-step workflows where order matters but the *specific* steps
selected still vary run-to-run.

> **Example — "Guided Troubleshooting".** A plugin-managed sequential ad-hoc
> sub-process where an AI agent runs diagnostic steps one at a time, each
> step's result informing the next choice: `CheckLogs` → (finds a memory
> issue) → `AnalyzeHeapDump` → (finds a leak in module X) → `RestartService`.
>
> **Example — "Sequential Data Migration".** Engine-managed, with
> `bfw:activeElements` returning
> `["ValidateSchema", "MigrateTable_Users", "MigrateTable_Orders", "VerifyIntegrity"]`.
> Only `ValidateSchema` is activated at start. After it finishes, auto-chain
> continues with the next unperformed inner activity in the model (not the
> remaining three IDs as a FEEL-list script). To force a specific next step
> that is not next in the model, use plugin/REST `activate_activity`.

---

## §4 Completion Behavior

### §4.1 Completion condition (FEEL expression)

`<bpmn:completionCondition>` is the standard BPMN child element (not
an `bfw:*` extension), a FEEL expression re-evaluated after every inner
activity completes. It receives three dedicated bindings, present **only**
during this evaluation — the standard `token` / `this` / `context` bindings
are **not** available here:

| Binding | Meaning |
|---------|---------|
| `performedActivities` | Integer count of inner FNIs currently in `:finished` state |
| `activeCount` | Integer count of inner FNIs currently `:active` or `:waiting` |
| `totalActivities` | Total number of inner activities defined in the model |

When the expression evaluates to `true`, the ad-hoc sub-process completes.

> **Example:** `completionCondition = "performedActivities >= 3"` — complete
> once any 3 of 5 tasks are done, regardless of which three.

### §4.2 `cancelRemainingInstances`

Boolean, default `true`:

- **`true`** — the moment the completion condition fires, every remaining
  active/waiting inner FNI is interrupted immediately.
- **`false`** — the engine stops accepting new activations, but lets already
  active FNIs drain naturally before the sub-process actually completes.

> **Example:** a data-enrichment pipeline with five optional enrichers,
> `completionCondition = "token.confidence > 0.9"`,
> `cancelRemainingInstances = true` — once confidence is high enough, every
> still-running enricher is stopped immediately rather than waiting for it to
> finish on its own.

### §4.3 Auto-complete (no completion condition, engine-managed)

When neither `completionCondition` nor `implementation` is set, the
sub-process auto-completes once **every** inner activity has been performed
at least once. This is the BPMN spec's default completion behavior.

### §4.4 Plugin-managed completion

In plugin-managed mode there is no auto-complete logic at all — the plugin is
fully in charge and must call `facade.adhoc_subprocesses.complete.(child_process_instance_id)`
(or the equivalent REST call) when it decides the work is done. An
`AdHocSubProcessCompleted` event is emitted either way, with
`completionReason` reflecting how the scope ended: `completed`, `fatal`,
`error`, `aborted`, `crashed`, `escalation`, or `unknown`.

---

## §5 Inner Activities and Sequence Flows

Sequence flows *inside* an ad-hoc sub-process are optional and express
partial dependencies, not a full execution order:

- Activities with **no incoming sequence flow** form the "enabled set" —
  available for activation from the start.
- Activities with an incoming sequence flow become enabled only after their
  predecessor completes.
- You can freely mix free-standing activities and short dependency chains.
- The same activity can be activated more than once — each
  activation creates a brand-new flow node instance; there is no "already ran"
  restriction at the engine level.

> **Example — "Customer Support Toolkit".** `IdentifyCustomer` has no
> incoming flows (enabled immediately). `ViewOrderHistory` has a sequence flow
> from `IdentifyCustomer` (enabled only after identification). `ApplyDiscount`
> and `ProcessReturn` are free-standing (always enabled). The agent identifies
> the customer first; only then can they view order history, while
> independently applying discounts or processing returns at any time.

---

## §6 Boundary Events

Every boundary event type supported on an Embedded Subprocess is also
supported on the ad-hoc sub-process shell: Error, Timer, Message,
Signal, Escalation, Conditional, and Compensation.

- **Timer boundary (non-interrupting)** — a reminder pattern: "notify someone
  if this hasn't been resolved in 15 minutes", without stopping the ongoing
  work.
- **Timer boundary (interrupting)** — a hard timeout: "abort the whole
  toolbox after 60 minutes and follow an escalation path".
- **Error boundary** — particularly useful in plugin-managed mode, to catch
  failures bubbling up from an inner activity (e.g. a Service Task) without
  crashing the whole ad-hoc scope.
- **Message/Signal boundary** — react to an external event while the ad-hoc
  scope is still in progress (e.g. "customer cancelled the request").

---

## §7 Data Pipeline

The ad-hoc sub-process shell supports the same data pipeline extensions as
every other subprocess variant:

- **`bfw:inputMapping`** — shapes the child PI's initial token from the
  parent's token.
- **`bfw:outputMapping`** — shapes the parent's continuation token from the
  child PI's final state once the ad-hoc scope completes.
- **`bfw:payloadContract` / `bfw:resultContract`** — JSON Schema validation
  on entry and exit; a violation is fatal to the shell FNI, same as Call
  Activity and Embedded Subprocess.

---

## §8 Decision Guide: Choosing the Right Mode

| Scenario | Ordering | Mode | `bfw:activeElements` | Completion | Example |
|----------|----------|------|-------------------------|------------|---------|
| Independent checklist tasks | Parallel | Engine | Optional | All performed | Onboarding |
| Deterministic multi-step pipeline | Sequential | Engine | Required | Condition or all performed | Data migration |
| AI agent with dynamic tool selection | Parallel or Sequential | Plugin | N/A | Plugin calls `complete` | AI Toolbox |
| Human-driven task selection | Parallel | Plugin (or REST) | N/A | Condition or plugin `complete` | Repair Workshop |
| Rule-driven subset activation | Parallel | Engine | FEEL filter | Condition | Document processing |
| Guided troubleshooting | Sequential | Plugin | N/A | Plugin calls `complete` | Diagnostic agent |

---

## §9 Limitations and Gotchas

- **No Start Events or End Events inside the ad-hoc sub-process** — a
  BPMN 2.0 spec constraint, enforced at deploy time
  (`adhoc_subprocess_has_start_event` / `adhoc_subprocess_has_end_event`).
- **No ad-hoc inside ad-hoc** — nesting restriction, same rationale as nested
  transactions (`nested_adhoc_subprocess`).
- **No ad-hoc inside an Event Subprocess** — disallowed
  (`adhoc_inside_event_subprocess`). An unstructured toolbox is not a
  useful event handler. Ad-hoc inside a *plain* embedded subprocess, and
  embedded subprocess/call activity inside an ad-hoc ("complex tools"),
  are both fine.
- **The ad-hoc sub-process must contain at least one activity** — an empty
  toolbox is rejected at deploy time (`adhoc_subprocess_empty`).
- **Retry granularity: the entire ad-hoc scope is retried as a unit.** A
  `resetToFlowNodeInstanceId` checkpoint pointing inside an ad-hoc sub-process
  scope is rejected — the
  inner scope's non-deterministic execution order makes a mid-scope checkpoint
  meaningless. Retry from the shell FNI (or further upstream) instead. See
  [Retry](retry.md).
- **Sequential engine-managed without `bfw:activeElements` is rejected at
  deploy time** and flagged by the Studio linter's
  `adhoc-subprocess-ordering` rule even before deployment.
- **`completionCondition`'s FEEL bindings are not the standard ones.** Only
  `performedActivities`, `activeCount`, and `totalActivities` are available —
  `token`, `this`, and `context` are **not** bound during this evaluation
  (see §4.1). This trips up authors who copy a `completionCondition` from a
  Multi-Instance loop, where the binding set is different.

---

## Related Topics

- [Embedded Subprocesses](embedded-subprocesses.md) — the shell/child-PI
  pattern that Ad-hoc Sub-Process reuses
- [Event Subprocesses](event-subprocesses.md) — for reactive, event-triggered
  scopes instead of a toolbox of activities
- [Transaction Subprocess](transactions.md) — another subprocess variant with
  its own opinionated completion semantics
- [Compensation](compensation.md) — Compensation Boundary Events on ad-hoc
  inner activities work exactly as on any other activity
- [Retry](retry.md) — retry restrictions for ad-hoc scopes
- `examples/plugins/adhoc/ai_toolbox/` — a fully worked plugin-managed example

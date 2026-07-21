---
title: Evil Engine — Implementation Plan
date: 2026-04-24
status: APPROVED
---

# Evil Engine — Implementation Plan

> Working title: *"The Anvil of Khorne"*.
> This document is the concrete, phase-by-phase implementation plan derived from
> the project's original product concept. It resolves every `AGENT:` / `TODO:`
> marker in that concept and locks in the architectural decisions made during
> planning.
>
> §16 only contains remaining open technical questions (to be answered during
> the relevant phase), risk register, and explicit v1 non-goals.

### Companion documents

This plan has been split across several documents to keep each one focused:

| Topic | Document |
|---|---|
| Full architectural diagram + narrative | [`Architecture.md`](./Architecture.md) |
| **Detailed architecture docs (one topic per file)** | **[`architecture/index.md`](./architecture/index.md)** |
| Full database schema diagram + per-table notes | [`Schema.md`](./Schema.md) |
| Every term used in this plan | [`Glossary.md`](./Glossary.md) |
| Phased roll-out plan for contributors | [`ImplementationPhases.md`](./ImplementationPhases.md) |

All docs cross-reference each other; section IDs (`§N`, `§N.M`) and
in the companion docs always refer back into this plan.
Sections extracted to `architecture/*.md` are marked with a
`> Full specification:` blockquote linking to the target document.

---

## Table of Contents

0. [Design Decisions](#0-design-decisions)
1. [Tech stack (final)](#1-tech-stack-final)
2. [High-level architecture (DDD domains)](#2-high-level-architecture-ddd-domains)
3. [Runtime architecture](#3-runtime-architecture)
4. [Data model](#4-data-model-postgres)
5. [Process Instance specification (fleshed out)](#5-process-instance-specification-fleshed-out)
6. [Flow Node Instance specification (fleshed out)](#6-flow-node-instance-specification-fleshed-out)
7. [BPMN element coverage](#7-bpmn-element-coverage-per-priority-tier)
8. [Expression engine (FEEL)](#8-expression-engine-feel)
9. [Plugin system & SDKs](#9-plugin-system--sdks)
10. [API design](#10-api-design)
11. [Observability](#11-observability)
12. [Testing strategy](#12-testing-strategy)
13. [Security](#13-security)
14. [Packaging & ops](#14-packaging--ops)
15. [Phases, priorities & order](#15-phases-priorities--order)
16. [Open items, defaults, and risks](#16-open-items-defaults-and-risks)

---

## 0. Design Decisions

Significant design decisions made during implementation. Each entry records the decision, when it was made (phase), and a brief rationale. Add new rows here when a meaningful architectural choice diverges from the original plan or establishes a lasting pattern.

| ID | Phase | Decision | Rationale |
|----|-------|----------|-----------|
| D1 | Phase 4 | **No pending-escalation cache; deterministic propagation.** The `pending_escalations` table, `PendingSweeper` involvement, and all late-catch drain logic (§3.5.7.1) were dropped. Escalation boundaries are pre-spawned in `:waiting` state when the host activity starts — there is no publish-before-register race condition for escalations. Propagation follows the existing parent-chain message-passing architecture (one handler Task + PI per scope level), which is deterministic and synchronous. | Eliminates a DB table, sweeper involvement, and complex late-catch semantics. The race condition that motivated the pending-escalation hold does not exist for Escalation Boundaries (unlike Messages, which are sent from outside the engine). |
| CG-D1 | Phase 5 | **Complex Split is opinionated inclusive-style, no unconditional fall-through.** Every outgoing flow must be conditional or the `default`; an unconditional non-default flow is a deploy error. Default fires only when zero conditionals match. | Catches the classic "forgot a condition, so it always fires" Inclusive-split bug at deploy time instead of silently at runtime. |
| CG-D2 | Phase 5 | **Complex Join is a single-fire threshold join.** Fires once when the FEEL `activationCondition` becomes true; deliberately no re-fire / reset. | Avoids the BPMN spec's oscillation-prone reset semantics; keeps the join deterministic. |
| CG-D3 | Phase 5 | **Twist 1 — dead-path exhaustion is an error.** When every incoming branch is arrived-or-dead and the condition is still false → fatal `complex_join_condition_unmet`. | An impossible quorum fails loudly and immediately rather than leaving the PI silently stuck forever. |
| CG-D4 | Phase 5 | **Twist 2 — firing cancels the losers in the SESE region.** On fire, all still-active/waiting FNIs inside the region bounded by the paired split are interrupted (`cancelled_by_complex_join`). | Turns "fastest N-of-M" into a clean scoped mini-terminate; no stragglers, no orphaned tasks/timers/child PIs. |
| CG-D5 | Phase 5 | **Strict 1:1 join↔split pairing (SESE).** A Complex Join must pair to exactly one Complex Split; zero / ambiguous / non-SESE pairing is a deploy error. | Makes "which branches get cancelled" unambiguous and bounded. |
| CG-D7 | Phase 5 | **Threshold bindings are `activatedCount` / `incomingCount`.** Injected as top-level FEEL bindings while evaluating the join's `activationCondition`. | Matches the seeded `activatedCount >= 2` fixture and reads naturally for quorum conditions. |
| CG-D10 | Phase 5 | **Pairing rule `S = idom_complex(J)`.** The paired split is the nearest enclosing Complex Split that dominates the join (immediate dominator restricted to Complex Splits); region = `forward_reachable(S) ∩ backward_reachable(J) \ {S,J}`. | Deterministic; always picks the innermost enclosing split, so nested regions are strictly contained (laminar) and never partially overlap. |
| D2 | Phase 5 | **Subprocess Start-Event isolation via a core parent-presence invariant.** A Start Event nested in an embedded / event / (future) transactional subprocess is never externally startable. The authoritative guard is intrinsic to `Execution.start_process_instance/1`: `subprocess_node_id` present ⇒ `parent_process_instance_id` required, else `{:error, :orphan_subprocess_start}`. The public start surface (REST + `Api` facade) excludes `subprocess_node_id`; extraneous request params are **ignored**, not rejected, consistent with other endpoints. A deploy-time `duplicate_flow_node_id` validator enforces global flow-node ID uniqueness across a process and every nested subprocess scope. | A single chokepoint (every entry point — REST, plugin, Call Activity, SubProcess, ESP — flows through it) converts today's incidental data-scoping protection into an explicit, regression-tested invariant, without adding noisy per-key rejection. Global unique IDs remove start-event/subprocess resolution ambiguity. A request-validation layer that *rejects* unknown params is acknowledged as useful but separate/out-of-scope. |
| ESP-D1 | Phase 5 | **An Event Subprocess (ESP) executes as a child ProcessInstance of its scope PI**, reusing the embedded-subprocess synthetic-model machinery (`ModelCache.fetch_subprocess_model/2`, `start_process_instance/1` with `subprocess_node_id`). | The inner graph is already stored in `type_data`; child-PI spawn, resume, and abort/fatal/error/escalation cascade already exist for embedded subprocesses. Minimal new runtime surface. |
| ESP-D2 | Phase 5 | **The scope PI owns ESP trigger subscriptions.** On init and resume it scans its `flow_nodes` for `triggered_by_event: true` subprocesses and registers each trigger (message/signal subscription, timer arm, conditional waiter); Error/Escalation are resolved reactively at raise time. Triggers lie dormant until fired. | Attaches the handler to the whole scope (not one activity, unlike boundary events); matches "dormant, observe until triggered". |
| ESP-D3 | Phase 5 | **Interrupting ESP** interrupts every *other* active/waiting FNI in the scope via `interrupt_remaining_fnis` (reason `:interrupted_by_event_subprocess`) — which does **not** stop the PI — tears down the other triggers, then spawns the ESP child; on completion the scope finishes normally. | Reuses the "interrupt siblings, keep PI alive" primitive (Terminate End Event, Complex Gateway Twist 2). Single-threaded in the PI's `gen_statem`; cannot target the scope PI itself. |
| ESP-D4 | Phase 5 | **Non-interrupting ESP** spawns a parallel child PI, keeps the trigger armed (re-arms) for multiple concurrent instances, and the scope PI continues; the scope does not finish until the main flow and all ESP child PIs are done. | Standard BPMN non-interrupting semantics; reuses the `active_count`-driven completion loop. |
| ESP-D5 | Phase 5 | **Trigger sourcing per start type:** Message = correlation subscription (kind `:event_subprocess_start`); Signal = signal subscription (same kind); Timer = PI-scoped `Scheduler` arm relative to scope activation (date/duration once, cycle re-arms); Conditional = scope-PI edge-triggered waiter; Error/Escalation = reactive scope resolution at raise time. | Correlation/timer/condition are relative to scope activation, not deployment. Error/escalation are scoped catchers on the propagation path. |
| ESP-D6 | Phase 5 | **Conflict-resolution law: proximity first, specificity second.** Error/escalation propagate outward; at each step the candidate set is boundaries on the activity being exited, then the ESP starts of the directly-containing scope, then bubble outward — first match wins. Within one candidate set, specific code beats catch-all. A boundary and an ESP are never in the same set, so boundary-vs-ESP is always decided by proximity. Message = tiered (see ESP-D13); Signal = broadcast-all; Timer/Conditional = independent. | Spec-aligned (BPMN outward propagation, innermost-scope-wins) and deterministic. Reuses `EscalationResolver` and `EventSubprocessResolver` specificity ranking. |
| ESP-D7 | Phase 5 | **Deploy-time ESP validation:** exactly one start event; typed start (never None); an Error start must be interrupting (`event_subprocess_error_start_must_interrupt`); the shell must have no incoming/outgoing sequence flows (`event_subprocess_has_sequence_flow`). Inner structural validation runs recursively (like embedded subprocess). "≥1 End Event" stays a runtime check. | Prevents undeployable diagrams while keeping WIP tolerance for end-event completeness. |
| ESP-D8 | Phase 5 | **The ESP inner scope may contain any supported flow node**, including Call Activities, Embedded Subprocesses, and nested Event Subprocesses at arbitrary depth. | It runs as a full child PI; capability is inherited. |
| ESP-D9 | Phase 5 | **Lanes are orthogonal to ESP triggering** — triggers are never lane-gated; inner activities may carry lane assignments (inherited like embedded subprocess). | BPMN: event subprocesses stand above lanes. |
| ESP-D10 | Phase 5 | **Resume** re-registers dormant triggers during scope-PI resume (same scan as fresh init); a triggered-but-incomplete ESP is reattached via its shell FNI's `child_process_instance_id` (existing embedded reattach path). | Reuses existing child-PI resume plus one scan step. |
| ESP-D11 | Phase 5 | **Retry/Abort/Fatal:** ESP child PIs are ordinary child PIs covered by tree-reset, abort cascade, and fatal cascade via the shell FNI callbacks. An uncaught error/escalation raised by the ESP child itself is offered to the shell's own boundary, then propagates to the scope PI's own parent — never back into the same scope. | Consistent with "the handler cannot re-handle its own escape". |
| ESP-D12 | Phase 5 | **A running ESP is a shell FNI** (`flow_node_id` = ESP shell id, `type: :sub_process`) owning `child_process_instance_id` and participating in `active_count`. Interrupting → one shell FNI; non-interrupting → one shell FNI per fire. | Makes completion tracking, resume, and abort cascade fall out of existing FNI machinery. |
| ESP-D13 | Phase 5 | **An ESP Message Start is a gated Start Event** subject to catch-wins-over-start: any active inline Message Catch/Boundary with a matching `(name, correlation)` always beats it (and beats a standalone start). The ESP message start registers with an informational `:event_subprocess_start` kind but is excluded from the delivery set and fires only when `deliveries == []`. | User directive: Catch/Boundary always beats a Start Event regardless of where it lies. Spec-aligned. |
| ESP-D13b | Phase 5 | **An ESP Message Start beats a Standalone Message Start** when no catch consumes the message: the running instance handles it and no new PI is created. Precedence ladder: inline catch/boundary → ESP message start → standalone message start. | Correlate to the in-flight instance before creating a new one. |
| ESP-D13c | Phase 5 | **Signal ESP starts keep broadcast-all simultaneous semantics** — an ESP signal start fires alongside signal catches/boundaries and standalone signal starts. The message catch-wins-over-start gate does not apply to signals. | Signals are not point-to-point; the "catch beats start" directive was scoped to messages. |
| ESP-D14 | Phase 5 | **Scope:** Message/Signal/Timer/Error/Escalation/Conditional starts. **Compensation start** added in Phase 5.4 (see COMP-D1, COMP-D5). | Compensation start triggers consume a thrown compensation for the containing scope and run the ESP inner flow. |
| ESP-D15 | Phase 5 | **An ESP inner Start Event is never externally startable** — it is spawned only by the scope PI's trigger machinery, always with both `subprocess_node_id` and `parent_process_instance_id`. This is the Subprocess Start-Event Isolation invariant (see **D2** above); cross-referenced, not duplicated. | Guarantees ESP starts are scope-owned; a user/plugin/Call Activity can never trigger an ESP inner start directly. |
| ESP-D16 | Phase 5 | **The ESP child PI is announced with the existing `SubProcessChildStarted` event carrying a new mandatory `is_event_subprocess` boolean** (`true` for ESP shells, `false` for embedded / plain shells); the richer `EventSubprocessTriggered` event is emitted in addition for engine-level observers. | Deterministic, reuses the SP-13 root-PI WebSocket fan-out, and the flag lets third-party consumers react ESP-specifically. |
| ESP-D17 | Phase 5 | **Coordinated Studio↔Engine linter-score contract fix (Studio authoritative).** The engine's process-level `<evil:linterRulesetScore>` parser + `LinterGate` are rewritten to consume the Studio's definitions-level `<evil:Properties>/<evil:LinterRulesetScore>` shape (attributes `rulesetId`, `scorePercent`, `complianceStatus`, `computedAtIso`, `schemaVersion`, `maxPoints`, `penaltyPoints`, `rawErrorFindings`, `rawWarningFindings`). | The old engine path was dead code against real Studio output; fixing it unblocks deployment of any Studio-linted diagram, ESP included. |
| COMP-D1 | Phase 5 | **Compensation-only scope (v1).** Compensate Throw, Compensate End, Compensation Boundary, Compensation-start Event Subprocess, plus `isForCompensation` + `<bpmn:association>` parsing. Transaction + Cancel End/Boundary are a follow-up that depends on this work. | Compensation is useful standalone (saga pattern, escalation-drives-rollback) and is the prerequisite for transaction/cancel. Building the smaller feature first reduces risk. |
| COMP-D2 | Phase 5 | **Sequential strict reverse-completion order (LIFO), one handler at a time.** `activityRef` targets a single activity; absent `activityRef` broadcasts to all completed activities in scope in reverse completion order. | Matches BPMN 2.0 §10.6 and the Camunda/Flowable implementations. Sequential execution is simpler to reason about and resume; parallel compensation is a documented follow-up. |
| COMP-D3 | Phase 5 | **Re-derive the compensation registry on resume from persisted finished FNIs + the BPMN model (no new registry table).** In-flight throw runs resume from a persisted cursor stored in `type_properties`. | Same "reconstructed vs re-derived" philosophy used for join routing. No schema migration needed; the registry is a cheap runtime view over data already persisted by the FNI lifecycle. |
| COMP-D4 | Phase 5 | **Compensation End is non-interrupting to parallel branches.** It consumes its token like a None End Event (not a Terminate). When the PI quiesces with `compensation_end_reached` and no stronger terminal (error/escalation/terminate), the PI terminal state is `:compensated`; otherwise `:finished`. | Matches BPMN 2.0 §10.6 and Camunda: "a compensation end event triggers compensation and the current path of execution is ended; same behavior as a compensation intermediate throwing event." A Compensate End only ends its own path. |
| COMP-D5 | Phase 5 | **Compensation Start event is legal only inside a `triggeredByEvent` subprocess.** This is the only hard compensation-position rule enforced at deploy time; all other compensation checks (missing association, unresolved `activityRef`) are linter/runtime concerns. | Mirrors the ESP-D7 style. The deploy-time validator stays lenient (WIP diagrams can be deployed); structural correctness beyond this rule is the Studio linter's job. |
| COMP-D6 | Phase 5 | **State model: only PI terminal `:compensated` ships in v1.** No `compensating` PI state and no new FNI state. "Compensation is active / what got compensated" is expressed via `CompensationTriggered` / `ActivityCompensated` events + `type_properties` markers on the involved FNIs. | Avoids duplicating every `:running` gen_statem clause for a `:compensating` state; preserves the "finished is terminal" FNI invariant that retry/resume rely on. A live `compensating` indicator is a deferred follow-up. |
| COMP-D7 | Phase 5 | **Responsibility split: thin handlers + `CompensationResolver` + `ProcessInstance.CompensationOrchestrator`.** Handlers return a tuple tag; the resolver does model matching; the orchestrator builds ordered plans (no spawning); the PI stays a thin executor. | Follows the anti-god-module pattern established by `BoundaryOrchestrator` (which documents "does not spawn FNIs — those remain in ProcessInstance"). All matching/ordering logic sits in pure, unit-testable modules. |
| COMP-D8 | Phase 5 | **Subprocess / Call Activity scope (v1): atomic-unit compensation only.** Embedded subprocesses and call activities are compensated as atomic units via a compensation boundary on the shell + a parent-scope handler. No cross-PI recursion into a child PI's inner completed activities. | Deep hierarchical recursion into embedded-subprocess internals is spec-correct but materially larger, touching child-PI boundary and resume/registry design. Call-activity non-propagation is permanent per BPMN spec. |
| TX-D1 | Phase 5 | **Transaction is a SubProcess variant, not a separate type.** Parser maps `bpmn:transaction` to `:sub_process` with `is_transaction: true` on `FlowNodeData.SubProcess`. Handler routing branches on this flag to use `TransactionSubProcess`. | Reuses 95% of the embedded subprocess infrastructure (ModelCache, boundary orchestration, resume, retry). Mirrors how ESP was added (`triggered_by_event: true`). |
| TX-D2 | Phase 5 | **New PI terminal state: `:cancelled`.** When a child PI is cancelled via Cancel End Event, it transitions to `:cancelled`. Distinct from `:aborted` (API kill switch) and `:compensated` (explicit compensation throw/end). | Clean state semantics matching the three Terminal-but-handled states family. |
| TX-D3 | Phase 5 | **Cancel End fires automatic LIFO compensation within the child PI.** Sequence: (1) Cancel End → child PI interrupts siblings, (2) child PI runs LIFO compensation for completed activities via `CompensationOrchestrator`, (3) child PI transitions to `:cancelled` and notifies parent. | Compensation runs inside the child PI's scope (correct scoping per BPMN §10.4.3). Parent only sees the final `:cancelled` state. |
| TX-D4 | Phase 5 | **Cancel Boundary is reactive (Error-model), not subscription-based (Timer/Message-model).** The Transaction handler Task awaits `{:child_pi_cancelled, ...}` and routes through `BoundaryResolver.find_matching_cancel_boundary/2`. | Cancel is deterministic and internal — there is no external event source to subscribe to. Same pattern as Error Boundary on Call Activity / Embedded Subprocess. |
| TX-D5 | Phase 5 | **No nested transactions in v1.** Deploy-time validator rejects `bpmn:transaction` inside another `bpmn:transaction`. Embedded subprocesses and call activities inside a transaction are allowed and compensated as atomic units (COMP-D8). | Nested transactions add complexity with little practical value. No mainstream engine supports them well. |
| TX-D6 | Phase 5 | **`method` attribute parsed and stored but not executed.** No wire-level transaction protocol integration (WS-AT, WS-BA). | Matches Camunda, Flowable, jBPM. The attribute is preserved in the model for BPMN fidelity. |
| TX-D7 | Phase 5 | **Hazard (uncaught error) does NOT trigger compensation.** An error propagating out of the transaction without an error boundary fatals the child PI. No compensation runs. Parent sees `{:child_pi_fatal, ...}`. | Spec-correct (BPMN 2.0 §13.4.6). Modelers who want compensation on error should wire an Error Boundary inside the transaction that routes to a Compensate Throw before the Cancel End. |
| TX-D8 | Phase 5 | **Retry restrictions: no checkpoint inside a transaction scope AND no retry of any nested PI below a transaction.** `resetToFlowNodeInstanceId` pointing inside a cancelled transaction → `retry_checkpoint_inside_transaction`. Retrying any PI with a transaction ancestor → `retry_inside_transaction_scope`. Applies transitively to TX → SP → CA chains. | Atomicity: once a transaction exists in the process tree, all nested PIs are part of that atomic scope. The correct approach is always to retry from the transaction shell or further upstream. |
| TX-D9 | Phase 5 | **`:cancelled` is NOT retryable.** Like `:compensated` and `:escalated`, a `:cancelled` PI represents a handled business outcome, not a failure. The parent continues via the Cancel Boundary. | Consistent with the "terminal-but-handled" family of states. |
| AH-D1 | Phase 1 | **Reuse `:sub_process` atom + `is_ad_hoc: true` on `FlowNodeData.SubProcess`** (same pattern as `is_transaction`). No separate `:adhoc_sub_process` atom. | Minimizes wire-format changes. Engine SDK `FlowNodeType.SubProcess` already covers embedded/transaction/ESP; the discriminant lives in `type_data` and SDK `SubProcessTypeData`. |
| AH-D2 | Phase 4 | **PI GenServer uses a Strategy Module pattern (`ProcessInstance.Mode` behaviour)** to keep the PI itself unopinionated. Three divergence points (start event resolution, initial dispatch, completion check) delegate to a `Mode` implementation. `StandardMode` preserves current behavior byte-identically; `AdHocMode` overrides: skip start event → no-op initial dispatch → complete on explicit signal. | Isolates all ad-hoc divergence into one module instead of scattering `if is_ad_hoc` branches through the PI. `StandardMode` extraction is a pure refactor, independently testable before `AdHocMode` exists. |
| AH-D3 | Phase 4 | **Two execution models selected via the `implementation` attribute:** Engine-managed (FEEL `evil:activeElements` determines active elements) when absent, Plugin-managed (async handler + facade API) when set. | Engine-managed is the deterministic path (Camunda's `activeElementsCollection` analog); Plugin-managed is the dynamic path for AI agents and external systems. |
| AH-D4 | Phase 1 | **`completionCondition` is a standard BPMN FEEL expression** (not `evil:*`), evaluated after each inner activity completes. | Spec-compliant; reuses the existing FEEL precompilation pipeline. |
| AH-D5 | Phase 1 | **`ordering` attribute: `Parallel` (default) or `Sequential`.** A missing `ordering` defaults silently to Parallel; the validator only rejects unrecognizable non-nil values. The Studio linter produces an advisory warning for an absent `ordering`. | Spec-compliant; Sequential means only one inner activity active at a time. |
| AH-D6 | Phase 1 | **`cancelRemainingInstances` attribute: boolean, default `true`.** When the completion condition fires and this is `true`, remaining FNIs are interrupted; when `false`, active FNIs drain naturally. | Spec-compliant. |
| AH-D7 | Phase 2 | **No Start Events or End Events inside the ad-hoc subprocess** — deploy-time validation rejects them. The child PI uses a synthetic "auto-start" mechanism that enables all activities without incoming sequence flows. | BPMN 2.0 spec §10.2.5 forbids them. |
| AH-D8 | Phase 4 | **Inner activities with no incoming sequence flows are the "enabled set"** — available for activation from the start. Activities with incoming flows become enabled when their predecessor completes. | BPMN 2.0 spec §13.3.5 execution semantics. |
| AH-D9 | Phase 4 | **Auto-complete when neither `completionCondition` nor `implementation` is set:** the subprocess completes once every inner activity has been performed at least once. Plugin-managed mode ignores this — the plugin calls `complete` explicitly. | Spec default behavior. |
| AH-D10 | Phase 3 | **New engine events `AdHocActivityActivated` (per activation) and `AdHocSubProcessCompleted` (on completion).** Child PI spawn reuses `SubProcessChildStarted` with a new `isAdHocSubprocess: true` flag. | Provides a full audit trail for the debugger and AI-agent observability. |
| AH-D11 | Phase 8 | **Studio `BpmnElementType.AdHocSubprocess`** — new enum value + dedicated interface, following the Transaction pattern. | Allows targeted pane visibility, help texts, linter rules, and icon mapping in the Studio. |
| AH-D12 | Phase 1 | **`evil:activeElements` FEEL extension** returns a list of element IDs to auto-activate. When absent, all enabled activities (no incoming flows) auto-start. | Gives fine-grained control over which inner activities are activated on entry (Camunda's `activeElementsCollection` pattern); the key control mechanism for plugins and AI agents. |
| AH-D13 | Phase 1 | **All boundary event types supported on the ad-hoc subprocess shell** (Error, Timer, Message, Signal, Escalation, Conditional, Compensation) — same set as embedded subprocess. | Error boundaries are particularly useful for catching failures in plugin-managed mode; Timer boundaries enable timeout patterns. |
| AH-D14 | Phase 1 | **Data pipeline support on ad-hoc subprocess:** `evil:inputMapping`, `evil:outputMapping`, `evil:payloadContract`, `evil:resultContract`. | Consistent with all other subprocess types; input mappings shape the child PI's initial token, output mappings shape the parent's continuation token. |
| AH-D15 | Phase 2 | **Nesting rules:** ad-hoc inside embedded subprocess is allowed, and embedded subprocess/call activity inside ad-hoc is allowed ("complex tools"). Ad-hoc inside ad-hoc is rejected (nesting restriction, same as nested transactions). **Ad-hoc inside event subprocess is rejected** as an opinionated platform decision (not a spec violation). | An unstructured toolbox as an event handler is counter-intuitive; the restriction avoids a confusing combination without a clear use case. |
| AH-D16 | Phase 4 | **Plugins (and engine-managed mode) can activate the same inner activity multiple times;** each activation creates a new FNI. | BPMN spec §10.2.5 permits activities to be "executed several times". Essential for the AI-agent pattern (calling the same tool repeatedly with different parameters). |
| AH-D17 | Phase 6 | **Retry restriction:** `resetToFlowNodeInstanceId` must not point inside an ad-hoc subprocess scope. Ad-hoc child PIs are retried as a unit by retrying the shell FNI. | Same pattern as Transaction (TX-D8); the inner scope's non-deterministic execution order makes mid-scope retry meaningless. |
| AH-D18 | Phase 2 | **Engine-managed sequential ad-hoc requires `evil:activeElements`.** When `ordering="Sequential"` and no `implementation` is set, the validator and Studio linter reject the diagram if `evil:activeElements` is absent. Parallel ordering and plugin-managed mode are unaffected. | Without an explicit FEEL expression ordering the activities, the engine has no deterministic basis for choosing which activity to execute next. |

---

## 1. Tech stack (final)

### Primary stack

| Layer | Choice | Rationale |
|---|---|---|
| Language / runtime | **Elixir on BEAM (OTP 26+)** | Actor-per-PI is native; supervision trees match "no crash must propagate"; hot-code-loading covers zero-downtime; Distributed Erlang makes future clustering cheap |
| HTTP + WebSockets | **Phoenix** | Mature, lightweight, Phoenix Channels give us the WebSocket pub-sub surface for free |
| GraphQL | **Absinthe** (via **AshGraphql**) | Auto-generated SDL with paging/filter/sort from Ash resources |
| REST / JSON:API | **AshJsonApi** and/or **Phoenix Controllers** | JSON:API for resource-shaped endpoints; plain controllers for trigger endpoints |
| OpenAPI | **open_api_spex** | Emits OpenAPI 3.1 from Phoenix controllers |
| Data modeling | **Ash Framework** (+ **AshPostgres**) | DDD-first; actions, calculations, relationships, policies; avoids Ecto-schema duplication; resources become the published read model |
| Database | **PostgreSQL 16+** | Required by concept; JSONB + GIN + partial indexes + LISTEN/NOTIFY + logical replication all leveraged |
| Migrations | **Ecto.Migrator** (via `mix ash_postgres.generate_migrations`) | Generated from resource changes, reviewable |
| JSON Schema validation | **ex_json_schema** | JSON Schema 2020-12 support |
| FEEL expressions | **`feel_ex`** (OSS) if validated, else in-engine FEEL subset | See §8 |
| Auth / JWT | **Joken** + **JOSE** (HS/RS/ES families, JWKS with caching) | Battle-tested Elixir JWT libs |
| Observability | **`:telemetry`** + **PromEx** (Prometheus) + **`logger_json`** (structured JSON logs) | Counters feed `/stats` and Prometheus `/metrics`; no OpenTelemetry/distributed tracing in v1 |
| Process parsing | **`saxy`** (streaming XML) + custom AST layer | Fast, low-allocation XML streaming |
| Mock clients, testing | **Mox**, **StreamData**, **PropCheck** / **Concuerror** | Property + concurrency testing |
| Releases | **`mix release`** (OTP release) | Self-contained, no host Elixir required in Docker |

### Secondary escape hatch

| Area | Fallback |
|---|---|
| FEEL hot path | Rust NIF via **Rustler** wrapping `feel-rs` or a custom Rust FEEL crate, only if Elixir FEEL profiling is insufficient |
| Heavy computation in custom Service Tasks (user code) | Plugin-specific; not a core concern |

### Schema / Data Contract format

- **JSON Schema Draft 2020-12** for every data contract (User Task result, Service Task result, Throw Event payload, Message Start Event payload, Data Object contents).
- Stored **alongside** the BPMN XML in `<bpmn:extensionElements><evil:dataContract>…</evil:dataContract></bpmn:extensionElements>`, serialized as JSON inside an XML CDATA block (or referenced by URI at deploy time).
- Validated with `ex_json_schema` at runtime, with element-appropriate error handling ():
  - **Service Task** contract violations (payload or result) → FNI transitions to `Fatal`.
  - **User Task input** (`payload_contract`) violations → FNI transitions to `Fatal` (upstream data is broken, user cannot fix it).
  - **User Task finish** (`result_contract`) violations → error returned to caller, FNI stays `:waiting` (retryable — the user can correct their submission).
  - In all cases, validation runs **after** input/output mappers are applied (if any), so mappers can reshape data into a valid format before the contract checks it.

---

## 2. High-level architecture (DDD domains)

Per the original product concept: Core / API / Peripheral. Concrete domain layout below. Each box is an OTP application inside an **umbrella project** (`apps/`), letting us enforce the "no cross-cutting blocking" rule (Architectural / Domain Driven Design) via explicit inter-app APIs.

```
apps/
├── core_types/              # Core     — shared, behavior-free structs (Identity, Token, :telemetry event payloads, canonical error tuples). No logic. Every app may depend on it; it depends on nothing
├── core_execution/          # Core     — the runtime
├── core_expressions/        # Core     — FEEL evaluator, identity resolver
├── core_bpmn/               # Core     — BPMN parser, validator, data-contract compiler, and the in-memory `EvilEngine.BPMN.ModelCache` GenServer (per-node, ETS-backed) that holds `{process_version_id → AST}`. Owns the parsed Process Model AST under `EvilEngine.BPMN.Model.*`. The AST is in-memory only; `process_versions.bpmn_xml` is the single persistent form.
├── core_timers/             # Core     — timer scheduler (single-node; cluster-ready interface)
├── core_events/             # Core     — in-process bus (Phoenix.PubSub) + the `EngineEventBus` abstraction that fans out every typed `EvilEngine.Types.Event.*` payload to every registered `EvilEngine.Plugin.EventSink` (§9.1). Owns the four built-in sinks: `console`, `telemetry`, `websocket`, `database` (DB sink default-OFF; )
├── api_auth/                # API      — Built-in JWT validator (HS256 + RS256/ES256 + JWKS). Pluggable via `@behaviour EvilEngine.Plugin.AuthProvider`.
├── api_facade/              # API      — EvilEngine.Api service-layer facade. No Phoenix dep.
├── api_web/                 # API      — REST + GraphQL + WebSocket + Admin (merged from api_http/api_graphql/api_websocket/api_admin)
├── peripheral_persistence/  # Peripheral — Ash resources + AshPostgres + the `database` EventSink (off by default) + the `RetentionRunner` GenServer that enforces opt-in per-terminal-state retention policies and the `purgeProcessInstances` operator mutation target
├── peripheral_telemetry/    # Peripheral — :telemetry counters backing /stats + PromEx Prometheus /metrics (no OTel in v1)
├── peripheral_plugins/      # Peripheral — plugin registry, sidecar gRPC bridge, conflict detector
└── engine_sdk/              # Public    — behaviours + test helpers for Elixir plugin authors. Re-exports `EvilEngine.BPMN.{Model.*, ModelCache, Parser}` so in-engine and out-of-tree Elixir tooling parses BPMN XML and consumes the AST with the same semantics the engine uses; plus the subset of `core_types` + plugin-relevant domain types plugin authors need
```

**Invariants**:

- Core domains never call API domains.
- Peripheral domains subscribe to Core events; they never push synchronous work onto Core.
- Plugins live under `peripheral_plugins` or as external sidecars — never inside Core.
- `core_types` contains no logic — only `defstruct`s, `@type`s, and cross-cutting enums. Every other app may depend on it; it depends on nothing (not even `ash`, `ecto`, or `phoenix`). This keeps it usable from plugins, tests, and Mix tasks with zero boot cost.
- Each domain publishes its own types inside its own namespace (see §2.1). **No type is duplicated across domains.** If two domains need the same type, it is promoted into `core_types`.

### 2.1 Contracts & published types

This subsection lists every kind of contract in the engine and which domain owns
it. Contracts are **domain-local by default** with a single shared
`core_types` app for truly cross-cutting, behavior-free structs. There is no
central "contracts" god-app.

#### 2.1.1 `core_types` — cross-cutting, behavior-free structs

Contains only `defstruct` + `@type` declarations. No logic, no side effects, no
external deps. Every other app may depend on it; it depends on nothing.

| Module | Purpose |
|---|---|
| `EvilEngine.Types.Identity` | Structured JWT claim — `{id, name?, email?, roles?, groups?, claims}` (§13 / [`Authorization.md`](./architecture/authorization.md) §3). `id` ← JWT `sub` (required); `claims` is the full decoded JWT payload map, available to plugins for custom claim inspection. Attached to every API action and every PI start request. Plugin identities carry `id: "plugin:<name>"` with `roles: [:plugin]` |
| `EvilEngine.Types.Token` | Process execution token — `{id, process_instance_id, scope_trace, payload, ⟪originating_flow_node_instance_id⟫, created_at}`. Carried end-to-end between Flow Nodes |
| `EvilEngine.Types.Event.*` | One struct per `:telemetry` event payload. E.g. `Event.ProcessInstanceStateChanged`, `Event.FlowNodeInstanceStarted`, `Event.FlowNodeInstanceFinished`, `Event.MessagePublished`, `Event.MessageArrived`, `Event.SignalPublished`, `Event.EscalationRaised`, `Event.TimerFired`, `Event.DataObjectWritten`, `Event.DeployAttempted`, `Event.DeployRejected`, `Event.RetentionPurged` (payload: `process_instance_id`, `purged_at`, `row_counts :: %{process_instance_events: non_neg_integer(), data_object_writes: non_neg_integer(), flow_node_instances: non_neg_integer(), data_objects: non_neg_integer()}`, `policy_source :: :retention_runner | :manual_purge`), `Event.EngineAuditPurged` (payload: `table :: :messages | :pending_messages | :signals | :escalations | :compensations | :engine_timers`, `cutoff :: DateTime.t()`, `row_count :: non_neg_integer()`, `policy_source :: :retention_runner` — manual-purge is out of scope in v1 non-goals), `Event.SinkFailed` (payload: `sink_name`, `event_kind`, `reason`, `occurred_at` — emitted by `EngineEventBus` when a registered sink's `handle_event/2` crashes, so operators can observe sink health without affecting other sinks). These are the exact shapes consumed by every `EvilEngine.Plugin.EventSink` implementation (the four built-in sinks + any plugin-registered sinks), see §3.6 |
| `EvilEngine.Types.Error` | Canonical tagged error tuples that cross domain boundaries, e.g. <code>{:error, :process_version_not_found}</code>, <code>{:error, :fni_fatal, reason}</code>, <code>{:error, :linter_gate_failed, failures}</code>. Used in <code>{:ok, _} / {:error, _}</code> return values from public actions |
| `EvilEngine.Types.PayloadEnvelope` | The JSON payload wrapper (`%{data, metadata}`) carried with every Token and every inter-PI message |

Nothing else goes here. If a candidate type is only needed inside one domain, it
stays inside that domain. If a candidate type needs `Ash.Resource`, `Ecto.Schema`,
or `Phoenix.Channel`, it is **not** a `core_types` type — those concerns live in
their owning domain.

#### 2.1.2 Per-domain published types

Each domain exposes its published types inside a single public namespace. Other
domains must go through that namespace — they never peek at internal modules.

| Owner domain | Public namespace | What it contains |
|---|---|---|
| `core_bpmn` | `EvilEngine.BPMN.Model.*` | The parsed Process Model AST (see §2.1.3). This is `core_bpmn`'s Published Language — the output language of the parser and the input language of every runtime handler |
| `core_execution` | `EvilEngine.Execution.FlowNodeHandler` (behaviour), `EvilEngine.Execution.FlowNodeResult` (struct), `EvilEngine.Execution.ProcessInstance.Facade` (behaviour + typed module used by FNIs) | The runtime contract — what every element handler returns and how handlers talk back to their PI (§5.5, §7) |
| `core_expressions` | `EvilEngine.Expressions.Context`, `EvilEngine.Expressions.Result` | The FEEL evaluator's input/output types (§8) |
| `core_timers` | `EvilEngine.Timers.Schedule`, `EvilEngine.Timers.Ref` | Scheduler inputs/outputs (§3.4) |
| `core_events` | Topic constants + event struct re-exports from `core_types` | Thin — event struct *shapes* live in `core_types`; this domain only owns the transport |
| `api_auth` | `EvilEngine.Auth.JwtVerifier` (behaviour only exists for test stubs), JWKS config structs | JWT validator internals (§13) |
| API domains | GraphQL schema (AshGraphql-generated) + `EvilEngineWeb.*.Request/Response` structs per controller | HTTP/GraphQL/WS on-the-wire shapes. These are API concerns and must not leak inward into Core |
| `peripheral_persistence` | Ash resources (`Processes`, `ProcessInstances`, `FlowNodeInstances`, `ProcessInstanceEvents`, …), plus the `DatabaseSink` module implementing `@behaviour EvilEngine.Plugin.EventSink` and the `RetentionRunner` GenServer + `PurgeResult` struct | The stored shapes; consumed by `api_web` (GraphQL) via Ash. Core never imports these |
| `engine_sdk` | All `@behaviour` modules for plugins + Mox fixtures + curated re-exports of the subset of `core_types` and `EvilEngine.BPMN.Model.*` plugins legitimately need **plus** `EvilEngine.BPMN.ModelCache.fetch/1` and a read-only facade over <code>EvilEngine.BPMN.Parser.parse_string/1</code> | The Published Language for external Elixir plugin authors (§9.3) |
| `api_web` (Model graph) | GraphQL types `ProcessModel`, `FlowNode` (interface) + one concrete node type per `FlowNodeData.*`, `SequenceFlow`, `Lane`, `DataObjectModel`, `BoundaryEvent`, `MultiInstance`, `LinterRulesetScore`, `BpmnExtension`; resolvers against `EvilEngine.BPMN.ModelCache` | Language-neutral access to the parsed AST for every API consumer; types are compile-time-derived from `EvilEngine.BPMN.Model.*` so they cannot drift from the parser |

Rules:

- **Diamond dependencies are forbidden.** If two domains need the same type, it is promoted into `core_types` (never duplicated and never stored in a third domain that both depend on).
- **No Core domain imports from any API or Peripheral domain.** Types flow strictly downward (API → Core → Peripheral); telemetry events flow upward.
- **`engine_sdk` re-exports, never re-defines.** A plugin-facing `@type` is always an alias for an inner type owned by a Core domain or `core_types`.

#### 2.1.3 Parsed Process Model AST (`EvilEngine.BPMN.Model.*`)

Owned by `core_bpmn`. The parser produces these structs from BPMN XML; the
runtime (§7) consumes them by pattern-match. The AST is the **canonical in-memory
representation** and is **not persisted** — the authoritative persistent form is
`process_versions.bpmn_xml` (§4.1). An in-process cache keyed by
`process_version_id` makes the parse cost a one-time per-node-per-version event
(see "In-memory cache" below).

**Top-level structure:**

```elixir
defmodule EvilEngine.BPMN.Model.Process do
  @enforce_keys [
    :id, :version,
    :flow_nodes, :sequence_flows, :lanes, :data_objects,
    :extensions, :linter_scores, :raw_xml
  ]
  defstruct @enforce_keys
end

defmodule EvilEngine.BPMN.Model.FlowNode do
  # Polymorphic on :type. :type_data is an EvilEngine.BPMN.Model.FlowNodeData.* struct.
  @enforce_keys [
    :id, :type, :type_data, :name, :lane_id,
    :incoming, :outgoing, :boundary_events,
    :multi_instance, :extensions, :data_contracts
  ]
  defstruct @enforce_keys
end
```

**Supporting structs under `EvilEngine.BPMN.Model.*`:**

- `SequenceFlow` — `{id, source_ref, target_ref, condition_expression, is_default}`
- `Lane` — `{id, name, claims, members}`
- `DataObject` — `{id, name, value_contract}`
- `BoundaryEvent` — `{id, attached_to_flow_node_id, interrupting?, type, type_data}`
- `MultiInstance` — `{is_sequential?, cardinality_expression, collection_expression, completion_condition}`
- `Extension` — `{namespace, element_name, attributes, text_content}` — preserves anything under `<bpmn:extensionElements>` the parser doesn't otherwise consume
- `DataContract` — `{source_xml, precompiled :: ExJsonSchema.Schema.Root.t()}` — the JSON Schema is compiled **at deploy time** and cached on the AST so runtime never re-parses
- `LinterRulesetScore` — exact 1:1 mapping of `<evil:linterRulesetScore>` XML attributes (§14.5); carried on `%Process{}`

**Per-element type data under `EvilEngine.BPMN.Model.FlowNodeData.*`:**

One struct per BPMN element kind the engine supports (§7): `StartEvent`,
`EndEvent`, `UserTask`, `ServiceTask`, `ManualTask`, `ReceiveTask`, `SendTask`,
`ScriptTask`, `CallActivity`, `EmbeddedSubprocess`, `EventSubprocess`,
`ExclusiveGateway`, `ParallelGateway`, `EventBasedGateway`, `InclusiveGateway`,
`MessageCatchEvent`, `MessageThrowEvent`, `SignalCatchEvent`, `SignalThrowEvent`,
`TimerCatchEvent`, `ErrorEvent`, `EscalationEvent`, `CompensationEvent`,
`TerminateEvent`, `ConditionalCatchEvent`. All under `core_bpmn` (so the parser
depends on no downstream domain).

**Runtime usage:**

Every handler's callback signature (§7) is

```elixir
@callback handle_enter(
            flow_node :: EvilEngine.BPMN.Model.FlowNode.t(),
            token     :: EvilEngine.Types.Token.t(),
            facade    :: module()
          ) ::
            {:ok,    EvilEngine.Execution.FlowNodeResult.t()}
          | {:error, reason :: term()}
          | {:async, flow_node_instance_id :: Ecto.UUID.t()}
```

Handlers **pattern-match** on `flow_node.type_data` — no raw XML, no
`Map.get(flow_node, "someAttribute")`, no opaque blobs. If a new attribute is
needed, it is added to the owning `FlowNodeData.*` struct first. Because the AST
is never persisted, the parser may evolve freely between engine versions — every
boot re-parses from `bpmn_xml` using the current parser.

The <code>{:async, flow_node_instance_id}</code> return shape is the long-running-work contract for
Service Task handlers: the FNI parks in `waiting` and the plugin owns the work
end-to-end, calling back later through `engine_facade.finish_async_service_task/2`
or `engine_facade.fail_async_service_task/3` (§9.2.5). Other element types may
return only <code>{:ok, _}</code> or <code>{:error, _}</code>; returning <code>{:async, _}</code> from a non-Service-Task
handler is a deploy-time-detectable / runtime-detectable bug that transitions
the FNI to `fatal`. See §7 "Service Task" for the full async lifecycle.

**In-memory cache (`EvilEngine.BPMN.ModelCache`):**

A single GenServer per engine node (`EvilEngine.BPMN.ModelCache`, in `core_bpmn`)
owns the authoritative map `{process_version_id → %EvilEngine.BPMN.Model.Process{}}`.
Backed by ETS for concurrent O(1) reads. The cache is the single access point
for the AST at runtime — handlers, `core_execution`, and resume all go through
it.

- **Build (deploy time)**: `POST /processes` and Seeding-Directory loads both
  call `ModelCache.put_new/1` with the freshly-parsed AST immediately after the
  `process_versions` row is committed. Parse errors reject the deployment before
  the row exists; the cache never holds a partially-parsed or invalid AST.
- **Cache miss (first runtime access of a version)**: happens on engine restart
  or for rarely-used versions evicted by ops-initiated rebuild. `ModelCache.fetch/1`
  reads `process_versions.bpmn_xml`, re-parses, compiles Data Contracts
  (`ExJsonSchema.Schema.Root.t()`) and FEEL expressions (§8.2), inserts the
  resulting AST, and returns it. Subsequent fetches are ETS reads.
- **Cache hit**: pure ETS lookup — no DB, no parse, no compile.
- **Lifetime**: for the lifetime of the engine node. Soft-deleted versions
  (`deleted=true`) remain cached so resuming PIs keep working; the row
  is evicted only when the engine shuts down.
- **Resume behavior**: when `EvilEngine.Execution.Resume` rehydrates a PI, it
  calls `ModelCache.fetch(pi.process_version_id)`. Cold cache → one parse per
  distinct version across all resuming PIs; warm cache (same version shared by
  many PIs) → one parse regardless of PI count.
- **Never written to disk.** No serialization codec, no `model_schema_version`,
  no jsonb shadow column. The authoritative version-pinned input to the parser
  is always `process_versions.bpmn_xml`.

### 2.2 Inter-domain runtime flow

```
         ┌────────────────────────────────────┐
         │    API wire surfaces               │
         │  (HTTP, GraphQL, WS, Admin, Auth)  │
         └──────────────┬─────────────────────┘
                        │ translate wire request → Elixir call
                        ▼
         ┌────────────────────────────────────┐
         │   EvilEngine.Api (Ash Code         │   ◄── in-BEAM plugins
         │   Interface)  — shared service     │       and gRPC sidecar
         │   layer for HTTP AND plugins       │       bridge call this
         │                                    │       function catalog
         │                                    │       DIRECTLY — no HTTP
         │                                    │       round-trip.
         └──────────────┬─────────────────────┘
                        │ commands (actions) via Ash
                        ▼
         ┌────────────────────────────────────┐
         │       Core Domains                 │
         │  (Execution, Expressions, BPMN,    │
         │   Timers, Events)                  │
         └──────────────┬─────────────────────┘
                        │ :telemetry events (typed structs from
                        │ EvilEngine.Types.Event.*) + Phoenix.PubSub
                        ▼
         ┌────────────────────────────────────┐
         │    Peripheral Domains              │
         │  (Persistence, Telemetry, Plugins) │
         └────────────────────────────────────┘
```

**Why a shared service layer matters.** `EvilEngine.Api` is an Ash Code
Interface (`code_interface do ... end` on each Ash resource), which exposes
every Ash action as a regular Elixir function (e.g. `EvilEngine.Api.start_process_instance/1`,
plus planned additions like publish\_message, retry\_pi, purge\_process\_instances, …).
Every wire surface above
(REST controllers, Absinthe resolvers, and channel handlers in `api_web`)
is a **thin adapter** that decodes the
wire request and calls the matching `EvilEngine.Api.*` function. Plugins —
whether in-BEAM OTP apps (§9.2 mode 1) or gRPC sidecars reached through the
`peripheral_plugins` bridge (§9.2 mode 2) — call the **same functions
directly** rather than looping out to an HTTP/GraphQL endpoint and back.
This guarantees that validation, authorization policies, and audit hooks
(all defined inside the Ash action) run identically regardless of caller.
The only Core-level edges open to plugins are event-scoped (registering
EventSinks, Service Task handlers, timer sources, etc.) — for any
**command** a plugin issues, the entry point is `EvilEngine.Api`.

---

## 3. Runtime architecture

### 3.1 Process Instance Runtime

- Each live Process Instance is one **`:gen_statem` process** (`EvilEngine.Execution.ProcessInstance`) supervised by a `DynamicSupervisor` and registered in a `Registry` under its PI ID.
- State machine states mirror concept §Process Instance States plus two internal substates:
  - `init` → `:running` → `:finished | :fatal | :aborted | :error | :escalated` (currently implemented) | `:compensated` (Phase 5 — Compensation; see COMP-D4, COMP-D6)
  - Internal substates: `:ramping_up` (during Start/Resume/Retry), `:draining` (during graceful stop).
- Event handling per state is implemented as explicit handler callbacks — no catch-all `handle_info/2` lumping.
- Holds in memory: parsed BPMN AST reference, active tokens, dictionary of running FNI child PIDs, Data Object cache, pending timers/catch subscriptions, the full `Identity` of the initiator.

### 3.2 Flow Node Instance Runtime

- Each FNI is a separate process (either `Task` for short-lived ones, `GenServer`/`:gen_statem` for long-lived) supervised by a `Task.Supervisor` owned by the PI.
- `restart: :temporary` — FNI crash does not auto-restart; the PI handles the crash explicitly (state → `:fatal` on that FNI, PI decides: fail-fast, fire boundary, or compensate).
- **Isolation**: FNI process crash is caught at the PI level; other FNIs continue.

### 3.3 Event Bus

> Full specification: [`architecture/event-system.md`](./architecture/event-system.md)

The event bus has two complementary layers: an in-process PubSub for
intra-engine coordination and the `EngineEventBus` for public fan-out
to pluggable `EventSink`s. Four built-in sinks ship (console, telemetry,
websocket, database); plugin sinks register identically. See the architecture
doc for PubSub topics, dispatch semantics, the EventSink behaviour, and the
lifecycle fan-out model.

### 3.4 Timer Scheduler

- Single `GenServer` (`EvilEngine.Timers.Scheduler`) that owns an **ETS ordered set** keyed by `{fire_at_ms, ref}`.
- Wakes up via `Process.send_after/3` scheduled at the earliest entry's time.
- Persists pending timers to `engine_timers` table so they survive restart.
- Public API: `schedule(process_instance_id, flow_node_id, iso8601) :: ref()` / `cancel(ref)`.

### 3.5 Message/Signal/Escalation routing

> Full specification: [`architecture/routing.md`](./architecture/routing.md)

Messages are routed by `(message_name, correlation_value)` with
broadcast-within-key semantics; Signals are pure broadcast; Escalations
bubble along a scope chain. All three event types support a
pending-with-TTL hold to close the publish-before-register resume
race. See the architecture doc for the subscription registry, correlation
derivation, publish-side algorithm, pending TTL, resume behavior, and the
escalation scope-chain walker.

### 3.6 Lifecycle → Persistence → API fan-out

Every state transition inside core_execution calls `:telemetry.execute/3` with the
relevant event name and a typed `EvilEngine.Types.Event.*` payload (§2.1.1).
Event names include at least:

- `[:evil_engine, :process_instance, :state_change]` — PI transitions (`running → finished`, etc.)
- `[:evil_engine, :fni, :state_change]` — FNI transitions (`running → waiting`, etc.)
- `[:evil_engine, :data_object, :written]` — Data Object write. Emitted **after** the write transaction commits so subscribers never observe uncommitted values.
- `[:evil_engine, :message, :published]`, `[:evil_engine, :message, :arrived]` — Message lifecycle (§3.5)
- `[:evil_engine, :signal, :published]`, `[:evil_engine, :escalation, :raised]`, `[:evil_engine, :timer, :fired]` — other event lifecycles

Each `:telemetry.execute/3` is paired with exactly one `EngineEventBus.publish/1` of the same typed payload (§3.3.2). Consumers of these events fall into two disjoint categories:

**A. Kernel-state persistence** (always-on, transactionally coupled with the PI, not routed through the event bus):

- **`process_instances` / `flow_node_instances` / `messages` / `signals` / `escalations` / `data_objects` / `data_object_writes`** — written by `peripheral_persistence` as part of the PI's own transaction (or the message/signal publish transaction). These writes happen **before or alongside** `EngineEventBus.publish/1`, never after it, so the event payload references a DB row that is already durable. `data_object_writes` in particular is always-on regardless of observability sink configuration, because downstream write-audit reconstruction is a runtime debugger feature.

**B. Event-bus sinks** (routed through `EngineEventBus`, §3.3.2 — each sink toggled independently):

- **`console` sink** (default ON) — structured JSON to stdout via `logger_json`, filtered by `EVIL_LOG_MIN_SEVERITY`.
- **`telemetry` sink** (default ON, owned by `peripheral_telemetry`) — increments in-process `:telemetry` counters backing `/stats` (§11). Includes per-process-model write-count counters for Data Objects.
- **`websocket` sink** (default ON, owned by `api_web`) — broadcasts the typed event on the WebSocket channel for subscribed clients. Data Object writes push `%Event.DataObjectWritten{}` so live debuggers/UIs can render the new value without re-querying. `debug`/`verbose` severities excluded by default to avoid flooding long-lived Studio connections.
- **`database` sink** (default **OFF**, owned by `peripheral_persistence`) — persists the typed event as one `process_instance_events` row (§4.3). Filtered by severity threshold + event-type allow/deny list. Complementary to the always-on kernel tables: the BPMN flow view, sender↔receiver navigation, DO write history, message/signal/escalation delivery audit, and timer-fire history are all reconstructable without it (see §11.1). Enable via `EVIL_EVENT_SINK_DATABASE=on` when a flat, SQL-queryable log of every typed engine event is wanted (compliance audit, severity sweeps, plugin-emitted out-of-BPMN-flow events).
- **plugin sinks** — any number of `@behaviour EvilEngine.Plugin.EventSink` implementations registered on boot (§9.1). Example plugin targets: Datadog, Prometheus push-gateway, Kafka topic, custom S3 JSONL archive, a replica Postgres with different retention policy.

All sinks run **concurrently** under supervised `Task`s started from `EngineEventBus`. A crash in one sink never affects another sink, never affects kernel-state persistence, and never affects core_execution (see §3.3.2 for the `Event.SinkFailed` isolation model). `core_execution.publish/1` is always non-blocking — the hot path does not wait for sinks.

**Integration-test implication:** tests that assert audit-log rows (the `process_instance_events` assertions in §12.4.3 and the cross-PI escalation chain assertions in S15*, the DO crash-resume variants in §12.4.4, etc.) always enable the DB sink in their test config. The default-OFF posture is a production-default choice; test fixtures do not inherit it.

---

## 4. Data model (Postgres)

> Full specification: [`architecture/data-model.md`](./architecture/data-model.md)
>
> Visual diagram: [`Schema.md`](./Schema.md)

All tables are Ash resources (AshPostgres) with generated migrations, UUIDv7
identifiers, and `timestamptz` time columns. The schema spans catalog tables
(processes, process_versions), execution-state tables (process_instances,
flow_node_instances, gateway_pending_arrivals, data_objects), and
audit/communication tables (process_instance_events, data_object_writes,
messages, pending_messages, signals, pending_signals, escalations,
pending_escalations, compensations, engine_timers). Nine tables are
partitioned monthly. LZ4 JSONB compression is applied
to every heavy payload column. See the architecture doc for the full DDL,
index rationale, and the schema-to-requirement mapping.

---

## 5. Process Instance specification (fleshed out)

Resolves the `AGENT: Describe in detail the properties, lifecycle, the responsibilities and functions of a Process Instance` marker in concept §Process Instance Handler Semantics.

### 5.1 Properties (final list)

Locked-in from concept + additions:

| Property | Type | Source | Mutable? |
|---|---|---|---|
| `process_id` | text | BPMN | immutable |
| `process_name` | text | BPMN | immutable |
| `process_version` | text | BPMN `<evil:version>` (required, ) | immutable |
| `process_definition_info` | jsonb | deploy-time copy | immutable |
| `process_instance_id` | uuidv7 | engine-generated | immutable |
| `parent_process_instance_id` | uuid? | triggering parent | immutable |
| `business_key` | text? | user-supplied at start, inherited | immutable (inherited) |
| `triggerer_flow_node_instance_id` | uuid? | triggering FNI (parent-side) | immutable |
| `state` | enum | lifecycle | mutable (monotone-ish) |
| `started_at` / `finished_at` | timestamptz | lifecycle | set-once |
| `started_by` | Identity | JWT claim at start | immutable |
| `started_with_context` | jsonb | Start-request payload | immutable (readonly context); capped at `EVIL_TOKEN_MAX_BYTES` at start time |
| `process_version_id` | uuid FK -> `process_versions.id` | deploy-time pinning; AST resolved through `EvilEngine.BPMN.ModelCache.fetch/1` | immutable |
| `final_tokens` *(derived)* | `[jsonb]!` calc | joined from End-Event FNIs' `output_token` on query | derived — no persistent column. `null` for non-`finished` terminal states |

The **readonly process context** (concept §Process Context) is set once at start and can never be written to during execution — only read by FEEL (`context.*`) and by Flow Node Instances. Write-capable persistent state uses Data Objects only.

### 5.2 States — resolved

The original concept's state list stays intact. Final conflict resolution (original concept §Process Instance States):

1. `Fatal`
2. `Aborted`
3. `Compensated`
4. `Escalated`
5. `Error`
6. `Finished`
7. `Running`

**Rule**: transition to a higher-weight state always overrides a lower-weight pending transition, even if the lower-weight end was reached chronologically first, *unless* the lower-weight state has already been durably persisted (= event log entry committed).

### 5.3 Lifecycle events — final list

The original concept's list extended per `AGENT: Add more events as required`:

```
onStarted          — running state entered (preparation happens synchronously in init/1, no separate event)
onSuspended        — temporarily paused (ops intervention — v2)
onResuming         — after engine restart
onRetrying         — with re-entry FNI IDs
onFinished         — original concept
onFatality         — original concept
onAborted          — original concept
onEscalated        — original concept
onCompensated      — original concept
onError            — original concept
-- NEW:
onMessageReceived       — a published message was routed to this PI
onSignalReceived        — a signal was routed to this PI
onEscalationReceived    — an escalation was routed to this PI
onCompensationTriggered — compensation has been requested
onTimerArmed            — a timer was scheduled
onTimerFired            — a timer fired inside this PI
onDataObjectWritten     — a Data Object was written. Typed payload %Event.DataObjectWritten{}
                          from EvilEngine.Types.Event.* (§2.1.1):
                          {process_instance_id, flow_node_instance_id, data_object_id, write_id, previous_value,
                           value, created_at}. Emitted AFTER the write transaction
                          commits (§7 Data Objects). Every write is DOA-originated
                          (DOA-only path); the former `source` field has been
                          removed since it would always be `:data_output_association`.
                          Consumed by peripheral_persistence (already written, for its
                          idempotency check), api_web (live push to connected
                          clients), and peripheral_telemetry (counter increment on `/stats`).
onUserTaskCreated       — a User Task FNI entered waiting
onUserTaskFinished      — a User Task FNI completed
onBoundaryTriggered     — an attached Boundary Event fired
onTokenSplit / onTokenMerged — parallel/inclusive gateway operations
```

### 5.4 Access points — final list

The original concept's list extended per `AGENT: Add more access points as required`:

```
Start(processModelId, version?, startEventId?, payload?, businessKey?, identity)
Resume(processInstanceId, identity)
Retry(processInstanceId, reentryFlowNodeInstanceIds[], identity)
Restart(sourceProcessInstanceId, identity)     -- new PI, same inputs, same BPMN version
Abort(processInstanceId, reason, identity)
Compensate(processInstanceId, identity)        -- internal
PublishMessage(name, payload, correlation?, identity)
  -- `correlation` is the pre-computed correlation value (string or :none).
  -- When called from an Intermediate Throw or Message End handler, the handler
  --   evaluates its `<evil:correlationRetrievalExpression>` against the current token
  --   first and passes the result here. API publishes pass the caller-supplied
  --   value verbatim. `nil` is coerced to `:none`.
  -- See §3.5 for the full routing algorithm (broadcast-within-key,
  --   catch-wins-over-start, pending TTL).
PublishSignal(name, payload, identity)
PublishEscalation(code, name, payload, identity)
PublishCompensation(piId, flowNodeId?, identity)
-- NEW:
FinishUserTask(flowNodeInstanceId, result, identity)
CancelUserTask(flowNodeInstanceId, reason, identity)
FinishAsyncServiceTask(flowNodeInstanceId, result, identity)
  -- deliver an async Service Task plugin's result back to the engine. The
  --   FNI must be in `waiting` state with `type='serviceTask'` and `type_properties`
  --   carrying the async marker set when the handler returned {:async, flow_node_instance_id}.
  --   Treated identically to a synchronous {:ok, FlowNodeResult} return: the engine
  --   applies dataOutputAssociations, advances the token, emits Event.FlowNodeInstanceFinished.
  -- size-cap: `result` is checked against EVIL_TOKEN_MAX_BYTES.
FailAsyncServiceTask(flowNodeInstanceId, errorCode, errorMessage, identity)
  -- report failure of an async Service Task plugin's work. Treated identically
  --   to a synchronous {:error, reason} return: transitions FNI to `fatal` (per the
  --   element's error-mapping rules in §7). Retry is the plugin's responsibility.
DeleteProcessInstance(processInstanceId, identity)
  -- soft-delete a terminal PI. Gated by `delete_process_instance` claim
  --   (own/all). Running PIs are rejected with {:error, :pi_still_running}.
  --   Sets `deleted=true`, `deleted_at=now()`, `deleted_by=<identity>` on
  --   the `process_instances` row. Deleted PIs are excluded from list queries
  --   and GraphQL results but remain in the DB for retention/purge.
Snapshot(processInstanceId) -> PiSnapshot       -- read-only state dump
Query(processInstanceId, paths) -> map()         -- FEEL-evaluated ad-hoc read
```

All access points are:
- Guarded by `api_auth` against the caller's Identity.
- Auditable (the caller's identity is recorded on every invocation).
- Idempotent where the BPMN spec requires it (Abort on already-aborted PI is a no-op; Start with identical nonce is de-duplicated within a configurable window — optional).

### 5.5 Functions exposed to FNIs (PI → FNI contract)

Every Flow Node Instance running inside a PI can call back into the PI via an explicit, typed module (`EvilEngine.Execution.ProcessInstance.Facade`). Functions:

```
read_token(self_fni) -> Token
write_result(self_fni, result) -> :ok | {:error, :payload_too_large, %{size: pos_integer, limit: pos_integer}}
  -- Stores `result` into the FNI's output_token.
  -- size-cap: before storing, the facade measures the JSON-byte-size of the
  --   canonicalized `result` and compares against EVIL_TOKEN_MAX_BYTES (default
  --   65536 / 64 KiB). On overflow:
  --     * return {:error, :payload_too_large, %{size: N, limit: M}};
  --     * the calling FNI transitions to `fatal` with structured reason
  --       %{kind: :payload_too_large, field: :fni_output, size: N, limit: M};
  --     * standard fni.fatal telemetry + `Event.FlowNodeInstanceFinished{state: :fatal, ...}`
  --       are emitted through EngineEventBus → every active sink — no dedicated
  --       event type is introduced for cap violations ("sink-visible via
  --       existing FNI fatal signal").
read_data_object(name) -> Json | nil
  -- Reads from the PI's in-memory cache (§7 Data Objects). Never hits the DB.
  -- Returns nil (JSON null) if the Data Object is unset (has never been written).
  --
  -- There is no `write_data_object/2` on the facade in v1. All writes
  -- are driven by <bpmn:dataOutputAssociation> on the owning Flow Node; the engine
  -- materializes them in the post-finish commit described in §7 "Data Objects".
  -- Handlers that need to produce Data Object values do so by returning the
  -- appropriate fields on their FlowNodeResult — the DOA maps those fields into
  -- Data Objects atomically with the FNI completing. This keeps the FNI-attribution
  -- invariant ("one write ↔ one owning FNI") without exposing a second write
  -- path. See §16.4 ("Handler-API Data Object writes") for the rationale.
read_context_variable(path) -> Json | nil      -- readonly PI context
get_process_info() -> ProcessInfo
get_identity() -> Identity
evaluate_expression(feel_source, extra_bindings \\ %{}) -> {:ok, any} | {:error, reason}
publish_message(name, payload)
  -- Routes up; PI forwards to Core.Events.
  -- size-cap: `payload` measured against EVIL_TOKEN_MAX_BYTES at entry.
  --   Overflow → {:error, :payload_too_large, ...}; FNI transitions to `fatal`
  --   with structured reason %{kind: :payload_too_large, field: :message_payload,
  --   message_name: name, size: N, limit: M}. No messages row inserted.
publish_signal(name, payload)
  -- Same size-cap contract as publish_message.
publish_escalation(code, name, payload)
  -- Same size-cap contract as publish_message (applied BEFORE scope-chain walk).
  -- Overflow → FNI transitions to `fatal` via the :payload_too_large path; no
  -- escalation ever reaches the walker, no escalations row is inserted.
  -- Entry point for the scope-chain walker. The caller is the
  --   FNI that threw (Intermediate Throw / Escalation End / propagating Event
  --   Subprocess Start). The facade forwards to Core.Events.publish_escalation/1
  --   which owns the walk:
  --     1. Walk upward in the current PI; stop on the first matching boundary /
  --        event-subprocess-start.
  --     2. On reaching the PI root uncaught, if the PI has a
  --        ⟪parent_call_activity_flow_node_instance_id⟫, cross exactly one PI boundary into the
  --        parent PI and resume walking from the Call Activity FNI.
  --     3. Repeat until caught or until the root of the root PI is reached
  --        uncaught. Uncaught-at-root-of-root terminal semantics are decided
  --        by the throw element: Escalation End Event → PI (and every
  --        propagated-through ancestor PI) terminates `escalated`, intervening
  --        Call Activity FNIs → `interrupted`; Intermediate Throw → no-op for
  --        terminal state, PI keeps running (§3.5.7 step 5). Never `fatal`.
  --   In every uncaught-at-root-of-root case, emit exactly one
  --     [:evil_engine, :escalation, :uncaught] telemetry event + one warn log
  --     carrying the escalation code, throw-site FNI id, and the full
  --     ancestor-PI chain.
  -- Both interrupting and non-interrupting Escalation Boundary Events on Call
  --   Activities are supported and handled identically to their in-PI
  --   counterparts, except the interrupt cascades through the child PI chain.
register_catch(kind, matcher, callback)        -- PI stores the subscription
  -- For message catches/boundaries, `matcher` is %{message_name, expected_correlation_value}.
  -- The PI evaluates <evil:correlationKey> against its own state at call time and
  --   passes the result (or :none) as expected_correlation_value. A per-event
  --   <evil:correlationRetrievalExpression> override MAY be supplied via
  --   `matcher.extraction` (see §3.5.2); if absent, the message's stamped
  --   correlation_value is used directly.
  -- The facade forwards to EvilEngine.Events.Subscriptions.register/1 (§3.5.1),
  --   which also drains any in-TTL pending_messages that match (§3.5.4).
unregister_catch(ref)
arm_timer(iso8601) -> timer_ref
disarm_timer(timer_ref)
request_compensation(target_flow_node_id?)
report_state(state :: :active | :finished | :fatal | :aborted | :interrupted, output_token?)
spawn_child_pi(process_model_id, version?, start_event?, payload, business_key) -> pid
```

This module is the **only** way FNIs affect the PI. No direct state mutation from FNIs is allowed — reinforces "Process Instance controls the execution flow, *not* the Flow Node Instances themselves" (concept §Internal Architecture).

---

## 6. Flow Node Instance specification (fleshed out)

### 6.1 Properties (final list)

From concept + additions:

| Property | Type | Notes |
|---|---|---|
| `flow_node_instance_id` | uuidv7 | |
| `process_instance_id` | uuid | |
| `flow_node_id` | text | BPMN element id |
| `flow_node_type` | enum | see §7 for full list |
| `lane_name` | text? | denormalized from AST (`FlowNode.lane_id` → `Lane.name`). `NULL` = not in any lane. Immutable after creation. Used by the PI visibility filter ([`Authorization.md`](./architecture/authorization.md) §5) |
| `state` | enum | active/finished/fatal/aborted/interrupted |
| `started_at` / `finished_at` | timestamptz | |
| `previous_flow_node_instance_ids` | uuid[] | **array**, because parallel/inclusive joins have multiple predecessors |
| `triggerer_flow_node_instance_id` | uuid? | for catch events: the throwing FNI |
| `input_token` | jsonb | snapshot at start |
| `output_token` | jsonb? | snapshot at finish |
| `type_properties` | jsonb | per-type state (e.g. retry count, async-dispatch marker for <code>{:async, flow_node_instance_id}</code> Service Task returns ) |
| `error_info` | jsonb? | when state is fatal |

### 6.2 States — final

Stated in the original concept with one addition (`Waiting` promoted from lifecycle event to formal state):
`Active | Waiting | Finished | Fatal | Aborted | Interrupted`

### 6.3 Lifecycle events — final

The original concept's list extended:

```
onStarted      — original concept (preparation is synchronous in init/1, no separate onPreparing event)
onFinished     — original concept
onFatality     — original concept
onAborted      — original concept
onCompensated  — original concept
-- NEW:
onInterrupted       — boundary/terminate interrupted this FNI
onWaiting           — FNI is now waiting (on message, signal, timer, user input…)
onResumed           — FNI picked up after engine restart or Retry
onProgress          — optional: long-running FNIs can emit intermediate progress
```

### 6.4 Access points

From the original concept, no additions needed:
```
Start / Resume / Abort / Interrupt / Kill / Compensate / Continue
```

`Continue` is the generic handler for all interactive elements providing their completion data (User Task, Service Task, Catch Events, etc.). Each type implements its own validation against the data contract.

---

## 7. BPMN element coverage (per priority tier)

Resolves the big `AGENT:` marker in concept §BPMN Spec Coverage by Priority.

**General rules for every element**:
- Implemented as a module in `apps/core_execution/lib/evil_engine/execution/flow_nodes/<type>.ex` conforming to the `@behaviour EvilEngine.Execution.FlowNodeHandler`.
- Receives an `EvilEngine.BPMN.Model.FlowNode.t()` struct — never raw XML, never an untyped map. Element-specific attributes live under `flow_node.type_data`, which is one of the `EvilEngine.BPMN.Model.FlowNodeData.*` structs; handlers pattern-match on it. Any attribute referenced by a handler must be a declared field on the matching `FlowNodeData` struct.
- BPMN-standard attributes used first; `evil:` prefixed extensions added only where the spec leaves gaps. New extensions are added to the parser and the matching `FlowNodeData.*` struct in `core_bpmn` before any handler may read them.
- Every element publishes `:telemetry` events for `[:start, :finish | :error]` using typed payloads from `EvilEngine.Types.Event.*` (§2.1.1) — consumed by `peripheral_persistence` (audit log), `api_web` (live push via WebSocket sink), and `peripheral_telemetry` (`/stats` counters).

**Process-level `evil:` extensions** (declared on `<bpmn:process>`, parsed into `EvilEngine.BPMN.Model.Process`):
- `<evil:version>` — required, .
- `<evil:correlationKey>` — optional, / §3.5.2. FEEL over PI state. Evaluated every time a Message Catch / Boundary / Event-Subprocess-Start inside this process enters `waiting` — the result is cached on the subscription as the expected correlation value. Also evaluated against the incoming payload when a Message Start Event kicks off a new PI, to seed that PI's initial correlation value. Absent or evaluates to `null` → the subscription's expected value is `:none` and it only matches messages whose published `correlation_value` is `:none`.
- `<evil:linterRulesetScore>` — optional, one per ruleset, per §14.5. Read at deploy time only.

**Legend**:
- **Attr** = BPMN 2.0 spec attribute / element used
- **evil:** = custom extension in the `evil:` namespace
- **Handler behavior** = runtime semantics chosen by the engine

### Priority tier: Highest

#### Start Event (Untyped, normal process)

- **Attr**: `bpmn:startEvent` (no eventDefinition).
- **evil:** `<evil:payloadContract>` (JSON Schema, optional) — validates the start request payload.
- **Handler behavior**: Spawns the PI; immediately emits the process token; proceeds to outgoing sequence flow. Multiple untyped start events → any can start; each produces a separate PI.

#### End Event (Untyped, normal process)

- **Attr**: `bpmn:endEvent` (no eventDefinition).
- **Handler**: Consumes the incoming token. If PI has no remaining active tokens/FNIs, PI transitions to `finished`.

#### Untyped Task

- **Attr**: `bpmn:task`.
- **Handler**: Pure pass-through; token flows through unchanged. Runs virtually instantly. `onStarted` + `onFinished` are the only events emitted.

#### Untyped Intermediate Event

- **Attr**: `bpmn:intermediateThrowEvent` or `bpmn:intermediateCatchEvent` with no eventDefinition.
- **Handler**: Pass-through. Same semantics as untyped task but modeled as an event for BPMN purposes.

#### Manual Task

- **Attr**: `bpmn:manualTask`.
- **Handler**: Documentation-only. Engine treats it as pass-through (no user interaction is required by spec) unless `<evil:requireConfirmation>true</evil:requireConfirmation>` is set — in that case it behaves like a minimal User Task with no form fields, waiting for a `FinishUserTask` call.

#### User Task

- **Attr**: `bpmn:userTask`, `camunda:formFields` / standard `bpmn:extensionElements` for form fields.
- **evil:**
  - `<evil:assignees>…</evil:assignees>` — string or FEEL expression, comma-sep or array; compared against `Identity.id`, `Identity.roles`, `Identity.groups`.
  - `<evil:formFields>…</evil:formFields>` — Formkit-compatible schema (engine stores opaquely; concept's "unopinionated flow node execution" is preserved — the engine does *not* render).
  - `<evil:inputMapping source="…" target="…"/>` — FEEL-based input mapper (same structure as Call Activity). Transforms the incoming token before the task is presented to the user. Multiple mappings supported.
  - `<evil:outputMapping source="…" target="…"/>` — FEEL-based output mapper. Transforms the user's submission before result contract validation and downstream propagation.
  - `<evil:payloadContract>` — JSON Schema describing valid input data after input mapping. Violations are fatal (upstream data is broken, user cannot fix it).
  - `<evil:resultContract>` — JSON Schema describing valid `FinishUserTask` results after output mapping. Violations are retryable (422 returned, FNI stays `:waiting`).
  - `<evil:dueDate>` — ISO 8601, optional, surfaced in queries for pending User Tasks.
  - `<evil:priority>` — integer, optional.
- **Data pipeline** ():
  1. `token` → `in_mappings` → `payload_contract` → FNI enters `:waiting` (task presented to user)
  2. User submits result → `out_mappings` → `result_contract` → `PayloadCap` → downstream token
- **Error semantics** (): Input mapping failures and `payload_contract` violations transition the FNI to `Fatal`. Output mapping failures also transition to `Fatal`. `result_contract` violations return a 422 error to the caller and the FNI stays in `:waiting` (retryable — the user can correct their submission).
- **Handler**: FNI enters `active` → runs input pipeline → `waiting`. Publishes `onUserTaskCreated`. Waits for `FinishUserTask(id, result)` or `CancelUserTask(id, reason)`. On finish: runs output pipeline ().

#### Service Task

- **Attr**: `bpmn:serviceTask`, **`implementation`** (standard BPMN attribute) — e.g. `"http"`, `"custom"`, or a plugin-registered dispatch key. The legacy `"external"` mode has been removed; long-running asynchronous work is now expressed through the <code>{:async, flow_node_instance_id}</code> handler return shape below, not a separate implementation key.
- **evil:**
  - `<evil:inputMapping source="…" target="…"/>` — FEEL-based input mapper. Transforms the incoming token before payload contract validation and plugin dispatch. Multiple mappings supported.
  - `<evil:outputMapping source="…" target="…"/>` — FEEL-based output mapper. Transforms the plugin's result before result contract validation and downstream propagation.
  - `<evil:payloadContract>` — JSON Schema validated against the (optionally mapped) input before plugin dispatch.
  - `<evil:resultContract>` — JSON Schema validated against the (optionally mapped) plugin output.
- **Data pipeline** ():
  1. Synchronous: `token` → `in_mappings` → `payload_contract` → plugin `handle_enter` → `out_mappings` → `result_contract` → `PayloadCap` → downstream token
  2. Async: `token` → `in_mappings` → `payload_contract` → plugin `handle_enter` → park (`:waiting`). On completion: `result` → `out_mappings` → `result_contract` → `PayloadCap` → downstream token
- **Error semantics** (): All contract violations and FEEL evaluation failures transition the FNI to `Fatal` (service tasks have no interactive retry path).
- **Handler dispatch** (in order):
  1. If `implementation` is set and matches a plugin-registered handler → plugin runs.
  2. Else if `implementation="http"` → built-in `evil:http_service_task` handler runs (see §9.4).
  3. Else: deploy-time error — the BPMN is rejected.
- **Async-only return contract ()** — a Service Task handler (in-BEAM or sidecar) returns one of two shapes per `handle_enter` invocation:
  - <code>{:error, reason}</code> — synchronous failure during startup (missing config, validation, lookup). The engine transitions FNI to `fatal`.
  - <code>{:async, flow_node_instance_id}</code> — **park-and-callback path** for all Service Task work that the plugin will resolve later (HTTP webhooks, queue workers, sidecar schedulers, third-party APIs that return on their own clock). The FNI transitions to `waiting`, the engine stores `type_properties.async = true`, and the plugin keeps the FNI id (which is also returned to it as the dispatch result) for later callback. Plugin completes via `engine_facade.finish_async_service_task(flow_node_instance_id, result)` (treated as a synchronous `:ok` return — same DOA, same token advancement, same `Event.FlowNodeInstanceFinished{state: :finished}`) or `engine_facade.fail_async_service_task(flow_node_instance_id, error_code, error_message)` (treated as a synchronous `:error` return — transitions FNI to `fatal`, same `Event.FlowNodeInstanceFinished{state: :fatal}` semantics). On engine restart while FNI is parked, resume rehydrates the `waiting` FNI from the DB and emits `Event.PluginAsyncFlowNodeRehydrated{flow_node_instance_id, plugin_name}` so the plugin can re-register interest in this FNI from its own durable state — the engine never tries to re-dispatch `handle_enter` for an FNI that returned <code>{:async, _}</code> in a prior boot. The async marker (`type_properties.async = true`) survives restart; a partial JSONB index on `(flow_node_instance_id) WHERE state='waiting' AND type_properties->>'async' = 'true'` keeps lookup O(log n) at scale. **Plugin liveness signal:** the supervised plugin process (in-BEAM `GenServer` / sidecar gRPC stream) is the only liveness handle the engine needs — there is no lock to extend, no expiry timer; if the plugin crashes the supervisor restarts it and `Event.PluginAsyncFlowNodeRehydrated` re-arrives. Plugins requiring true durability for their internal queue ship that durability inside the plugin (e.g. a Kafka-consumer plugin uses Kafka's own commit semantics).

### Priority tier: High

#### Start Event (Message) / End Event (Message)

- **Attr**: `bpmn:messageEventDefinition` + `bpmn:message@name`.
- **evil:** `<evil:payloadContract>` for start-triggering messages. `<evil:correlationRetrievalExpression>` on the End Event, optional — FEEL over the outgoing token, stamps the published message's `correlation_value` (§3.5.2). `<evil:payload>` on the End Event — FEEL expression for the outgoing payload; default = current token.
- **Start handler**: Per §3.5.3 step 5 (catch-wins-over-start), the Start Event fires only when the inbound message found **zero** matching subscriptions in the registry. When it fires, **all** enabled, executable process versions with a matching Message Start Event are started — each with its own PI. For every such new PI, the process-level `<evil:correlationKey>` (if declared) is evaluated against the inbound payload and seeds that PI's first correlation value. Messages never start disabled processes.
- **End handler**: Publishes the message after finishing. Payload = FEEL evaluation of `<evil:payload>` or current token if unspecified. `correlation_value` = FEEL evaluation of `<evil:correlationRetrievalExpression>` over the outgoing payload, else `:none`. Then transitions PI to `finished`.

#### Start Event (Signal) / End Event (Signal)

- **Attr**: `bpmn:signalEventDefinition` + `bpmn:signal@name`.
- **Handler**: Identical to Message except signals are **broadcast**: one PublishSignal can start multiple PIs (any enabled process with matching signal start) AND wake any waiting catchers in any PI.

#### Data Objects — IMPLEMENTED

- **Attr**: `bpmn:dataObject`, `bpmn:dataObjectReference`, `bpmn:dataInputAssociation`, `bpmn:dataOutputAssociation`.
- **evil:** `<evil:valueContract>` — JSON Schema validated on every write (strict — violation is fatal to the causing FNI ). Evaluated against the written `value` before the write transaction commits; on validation failure nothing is written, no audit row is produced, and the FNI transitions to `fatal`.
- **Lifecycle**: Data Objects start **unset** (no seeded value) at PI start — no `data_objects` row exists until the first write materializes one. Reading an unset Data Object via `dataInputAssociation` or via the `read_data_object/1` facade yields `null`; authors who need a default must model an upstream Flow Node that writes it explicitly.
- **Single write path (DOA-only)**: `bpmn:dataOutputAssociation` on the owning Flow Node. After the Flow Node's `onFinished`, the engine evaluates each association expression against the FNI's FlowNodeResult and writes the computed value to the target Data Object. `flow_node_instance_id = <the Flow Node's FNI>`. There is no `write_data_object/2` facade function on the PI in v1; handlers produce Data Object values exclusively by returning the corresponding fields on their FlowNodeResult, which the DOA then projects. See §16.4 non-goal "Handler-API Data Object writes" for the rationale — the FNI-attribution invariant ("one write ↔ one owning FNI") is trivially enforced by DOA's 1:1 FNI→DO projection, so the prior `source` column on `data_object_writes` (which distinguished DOA vs handler_api) has been removed.
- **Write transaction** (one DB transaction per write — **kernel state, always transactional**): `UPSERT data_objects` (full row replacement with `{id, process_instance_id, data_object_id, flow_node_instance_id, value, created_at}`) + `INSERT data_object_writes` (same column set). Both rows commit atomically regardless of any sink configuration. After commit the engine emits `%EvilEngine.Types.Event.DataObjectWritten{}` on `EngineEventBus` with payload `{data_object_id, write_id, previous_value, value, created_at}` (`previous_value` is computed from the in-memory cache, not stored in DB); the `database` EventSink (when enabled) then writes the corresponding `process_instance_events` row asynchronously, and other sinks (console/websocket/plugin) fan out in parallel. If the transaction aborts, no partial effect is observable — the in-memory cache is rolled back to the pre-write value **and** no event reaches `EngineEventBus`, so sinks never see the aborted write.
- **In-memory cache**: every PI keeps a `%{data_object_id => value}` map in its `:gen_statem` state (§3.2). Reads hit the cache; writes update the cache **after** the DB transaction commits. This keeps the DB as the single source of truth even across mid-write crashes.
- **Resume rehydration** (+ §3.5.5 pattern): on PI resume, the cache is rebuilt via `SELECT data_object_id, value FROM data_objects WHERE process_instance_id = $1`. `data_object_writes` is **not** scanned during resume — it is audit-only. The resumed PI starts reading and writing from the exact same snapshot that was observable to any external reader immediately before the crash.
- **Overwrite-on-write semantics** are preserved (writes always succeed past contract validation and always overwrite whatever was there). The full trail of intermediate values is preserved in `data_object_writes`.
- **Scope note**: `bpmn:dataObject@id` is unique within a Process Model, so `(process_instance_id, data_object_id)` is a sufficient compound key even when Data Objects are declared inside Embedded Subprocesses. Embedded-subprocess-scoped cleanup (marking a Data Object as "out of scope" when its enclosing subprocess exits) is a non-goal for v1 — the row remains and keeps its last value; queries interested in scope can join against `flow_node_instances` and the BPMN model to derive it.

#### Exclusive Gateway (+ Default + Conditional Flows)

- **Attr**: `bpmn:exclusiveGateway`, `bpmn:sequenceFlow@default`, `bpmn:conditionExpression` with `language="https://www.omg.org/spec/DMN/20191111/FEEL/"`.
- **Handler**: Evaluate each outgoing `conditionExpression`; exactly one truthy enforced. Multiple truthy conditions are treated as a modeling error (deliberate divergence from BPMN 2.0 "first truthy wins" — silently picking one creates ambiguous, hard-to-debug behavior). If none truthy, take default. If neither exists, fatal error on the FNI. Mixed gateways (both split and join) rejected at runtime.

#### Call Activity

- **Attr**: `bpmn:callActivity`, `bpmn:calledElement`.
- **evil:**
  - `<evil:startEventId>` — target start event inside the called process, optional.
  - `<evil:inputMapping source="…" target="…"/>` — FEEL-based input mapper. Transforms the incoming token before passing it as the child PI's start payload. Multiple mappings supported.
  - `<evil:outputMapping source="…" target="…"/>` — FEEL-based output mapper. Transforms the child PI's aggregated result before it becomes the Call Activity FNI's output token.
- **Version resolution ()**: Call Activities are **never** version-pinned in v1. At spawn time, the engine resolves `bpmn:calledElement` to the **latest non-deleted version of the enabled process** with that key (`process_versions.deleted=false` on a `processes.enabled=true` row). The child PI records that resolved `process_version_id` (UUID) as part of its immutable state. Every subsequent Resume of that child PI — including after engine restart — picks up the exact version it started on, regardless of newer deploys or soft-deletes of that version. There is no `<evil:calledProcessVersion>` extension.
- **Data pipeline**: `token` → `in_mappings` → child PI start → child finishes → `[FinalToken]` aggregation → `out_mappings` → parent downstream token. FEEL evaluation failures in either mapping direction transition the parent FNI to `Fatal`.
- **Handler**: Spawns a child PI. Current FNI state = `waiting`. On child PI `onFinished`: collects **all** completed End-Event FNIs into a `[FinalToken]` array () — each carrying `{end_event_id, end_event_name, payload}`. The Call Activity's output mapping FEEL expressions can cherry-pick, merge, or reshape the aggregated result. If no output mapping is present, the full array becomes the Call Activity FNI's output token. On child PI `onError` / `onEscalated` / `onFatality`: propagates to the matching boundary event if one is attached, else treats as FNI fatal.

#### Intermediate Catch Event (Message / Signal)

- **evil:** (Message only) `<evil:correlationRetrievalExpression>` — optional per-event override of the process-level `<evil:correlationKey>` (§3.5.2). FEEL over PI state, used when this specific catch wants to correlate on a different key than the process default. `<evil:eventMapping>` — FEEL expression for merging the inbound payload into the token. Signal catches have no correlation knobs.
- **Handler (Message)**: Evaluates its effective correlation key (per-event `<evil:correlationRetrievalExpression>` if set, else process-level `<evil:correlationKey>`, else `:none`) against current PI state. Registers a subscription in the shared registry (§3.5.1) with `(message_name, expected_correlation_value, flow_node_instance_id)`. `register/1` simultaneously drains any in-TTL `pending_messages` that match (§3.5.4). Enters `waiting`. On matching event received: proceeds with event payload merged into token via `<evil:eventMapping>`.
- **Handler (Signal)**: Registers a broadcast-style listener on `"engine:signals"` for the signal name; no correlation. On publish: every listener fires.

#### Intermediate Throw Event (Message / Signal)

- **Attr**: `bpmn:intermediateThrowEvent` + `bpmn:messageEventDefinition` or `signalEventDefinition`.
- **evil:** `<evil:payload>` (JSON or FEEL), default = current token. (Message only) `<evil:correlationRetrievalExpression>` — optional; FEEL over the outgoing token. Result is stamped onto `messages.correlation_value` at publish time (§3.5.2). Absent → `correlation_value = :none`. Signal throws have no correlation knobs.
- **Handler**: Evaluates `<evil:payload>` and (for messages) `<evil:correlationRetrievalExpression>` against the current token, then calls `PublishMessage` / `PublishSignal` via PI Facade → `Core.Events` → routing (§3.5.3 for messages, §3.5.6 for signals). Proceeds immediately; does not wait for delivery.

#### Boundary Event (Message / Signal / Error / Timer — interrupting & non-interrupting where applicable)

- **Attr**: `bpmn:boundaryEvent@attachedToRef`, `bpmn:boundaryEvent@cancelActivity` (true=interrupting, false=non-interrupting).
- **evil:** (Message-boundary only) `<evil:correlationRetrievalExpression>` — optional per-event override of the process-level `<evil:correlationKey>` (§3.5.2), identical semantics to Intermediate Catch.
- **Handler**: At `onStarted` of the attached activity, the boundary subscribes. Message-boundary subscriptions go into the **same** registry as Intermediate Catch subscriptions — routing is identical, they only differ in what happens when they fire. On matching event:
  - Interrupting: sends `Interrupt` to the attached FNI, then starts downstream flow from the boundary.
  - Non-interrupting: spawns a sibling branch from the boundary while attached FNI continues.
- Error boundary uses `<evil:errorCode>` and/or `<evil:errorMessage>` to match; both present = AND.
- Signal boundary: no correlation — fires on any matching signal.
- Timer boundary: no correlation — the scheduler holds the reference; §7 Timer section covers ISO 8601 parsing.

### Priority tier: Medium

#### Parallel Gateway

- **Attr**: `bpmn:parallelGateway`.
- **Handler (split)**: Produces one token on each outgoing flow.
- **Handler (join)**: Waits until every incoming sequence flow has delivered exactly one token; merges into one output token. Merge strategy = "last-wins per key" + `<evil:mergeStrategy>` for override (future extension).

#### Start Event (Timer)

- **Attr**: `bpmn:timerEventDefinition` + one of `timeDate`, `timeDuration`, `timeCycle`, all in **ISO 8601**.
- **Handler**: Per , ALL timer start events auto-fire. Cycle = recurring (`R/.../P…`); each firing spawns a new PI. Date = single shot at that time. Duration = relative to engine-deploy-time of the process version.

#### End Event (Terminate / Escalation)

- **Terminate**: Immediately interrupts **all** active FNIs in the same containing scope (Process or Embedded Subprocess). PI → `finished` unless a higher-weight end state already reached.
- **Escalation**: Returns `{:escalation_end, escalation_info, FlowNodeResult}` (D1 — no centralized walker; see `docs/architecture/routing.md` §3.5.7). Propagation follows the existing parent-chain message-passing architecture. The PI interrupts siblings (`:interrupted`), transitions to `:escalated`, and notifies the parent handler Task. The PI's final state is `:escalated` whenever an Escalation End Event fires without a matching catch at or above this PI's scope. **Not retryable.** Uncaught at root-of-root emits `[:evil_engine, :escalation, :uncaught]` telemetry. Never `fatal`.

#### Multi Instance & Loops

- **Attr**: `bpmn:multiInstanceLoopCharacteristics` (parallel/sequential flag), `bpmn:loopCharacteristics` for standard loops.
- **evil:**
  - `<evil:loopBreakCondition>` — FEEL expression (replaces Studio's `engine.setLoopBreakCondition`).
  - `<evil:loopInterval>` — ISO 8601 duration between iterations (replaces `engine.setTimeoutBetweenLoopIntervals`).
  - `<evil:maxIterations>` — safeguard cap (replaces `engine.maxLoopIterations`).
  - `<evil:inputCollection>` — FEEL expression returning array.
  - `<evil:outputCollection>` — FEEL expression to produce output.
- **Handler**: Implements parallel MI (all iterations spawn as concurrent child FNIs) and sequential MI (one-at-a-time).
- During iteration, the FEEL context gains a `loop` overlay binding (`loop.index`, `loop.total`, `loop.completed`, `loop.results`) — see §8.1.

#### Intermediate Catch Event (Conditional / Timer)

- **Conditional**: `<bpmn:conditionExpression>` evaluated as FEEL; scope = current PI only (concept §Conditional Boundary Event). Evaluated whenever any Data Object / Token changes + on a configurable polling interval (default: evaluated on every PI state change).
- **Timer**: Same ISO 8601 rules.

#### Intermediate Throw (Escalation)

- Returns `{:escalation_throw, escalation_info, FlowNodeResult}` (D1). Does NOT end the PI. The token continues past the throw on its outgoing sequence flow. Propagation follows the parent-chain message-passing architecture (§3.5.7). Legal placements: inside an Embedded Subprocess, on the main Process body, or inside a called Process that is itself invoked by a parent Call Activity — anywhere an upward scope chain can produce a catcher.
- **Uncaught at root-of-root is a no-op for terminal state.** The token has already continued past the throw; there is no End-Event semantic to carry. The PI keeps running and its final state is whatever normal downstream flow eventually produces (possibly `finished`, possibly `escalated` via a later Escalation End Event, possibly something else). Ancestor PIs are never touched by an uncaught Intermediate Throw. The walker still emits `[:evil_engine, :escalation, :uncaught]` + `warn` log for observability.

#### Boundary Event (Error / Escalation / Conditional)

- Error boundary: matches by code + message.
- Escalation boundary: matches by code. Attachable to Embedded Subprocess, Call Activity, and Task (per BPMN 2.0 Table 10.89). On a **Call Activity** the boundary catches escalations propagated **from the child PI** — this is the cross-PI hop in the scope-chain walker. Interrupting → cancel the child PI (and transitive descendants) + Call Activity FNI, then route the token out of the boundary; non-interrupting → child PI keeps running, parent spawns a parallel boundary-flow token. Matching semantics and registration are identical on Subprocess and Call Activity boundaries — only the "what to cancel on interrupt" cascade differs.
- Conditional boundary: FEEL expression; non-interrupting fires **at most once** per activity lifetime (Studio help says so; engine honours it).

#### Event-Based Gateway

- **Attr**: `bpmn:eventBasedGateway`.
- **Handler**: After the gateway, the first event (message/signal/timer/conditional catch) to fire wins; others are cancelled. Implements by registering all successor catches and racing them.

#### Embedded Subprocess

- **Attr**: `bpmn:subProcess` without `triggeredByEvent`.
- **Handler**: Contained flow nodes run as a logical sub-scope inside the same PI. Boundary events attach to the subprocess. Terminate End inside the subprocess interrupts only the subprocess scope.

#### Event Subprocess

- **Attr**: `bpmn:subProcess@triggeredByEvent="true"`.
- **Handler**: Registered as a listener on the containing scope. When a matching start event (message/signal/error/escalation/timer/conditional/compensation) fires, the event subprocess starts. Interrupting start → the containing scope is interrupted. All listed start event types are supported.

### Priority tier: Low

#### Inclusive Gateway — **IMPLEMENTED**

- **Attr**: `bpmn:inclusiveGateway`.
- **Handler (split)**: Evaluates **all** outgoing condition expressions; every truthy one produces a token, plus any unconditional non-default flows. If zero truthy and default exists, takes default. If zero truthy and no default, FNI fatal `:no_matching_condition`.
- **Handler (join)**: Dead-path elimination via deploy-time backward reachability analysis (`InclusiveJoinAnalysis`) and runtime evaluation (`InclusiveJoinEvaluator`). Join fires when all reachable paths have arrived and no active FNIs exist upstream of un-arrived paths. Implemented without database polling — the PI's `maybe_finish_or_continue` hook re-evaluates parked inclusive joins after every FNI state change.
- **Implementation**: See `docs/architecture/execution.md` §Inclusive Gateway and `.cursor/plans/inclusive_gateway_5e973a1a.plan.md` for the full specification.

#### Business Rule Task

- **Attr**: `bpmn:businessRuleTask`.
- **evil:** `<evil:decisionRef>` — DMN decision id. `<evil:dmnEngine>` — optional plugin key.
- **Handler**: Default implementation dispatches to an external DMN engine via HTTP (same mechanism as `evil:http_service_task`). Plugin can override.

#### Script Task — **IMPLEMENTED**

- **Attr**: `bpmn:scriptTask`.
- **Standard BPMN 2.0 properties:**
  - `scriptFormat` — attribute on the element (e.g., `"feel"`). Stored for BPMN fidelity, passed through to plugins via `flow_node.type_data.script_format`, but not enforced by the engine.
  - `<script>` — standard child element containing the inline script body.
- **evil:**
  - `<evil:scriptRef>` — extension element referencing a plugin-registered named script key. **Takes precedence over inline script.**
  - `<evil:inputMapping>`, `<evil:outputMapping>` — FEEL-based data transformation (same semantics as ServiceTask/UserTask).
  - `<evil:payloadContract>`, `<evil:resultContract>` — JSON Schema validation (same semantics as ServiceTask/UserTask).
- **Handler** (`FlowNodes.ScriptTask`): Per 1. Run input pipeline: `in_mappings` (FEEL) → `payload_contract` (JSON Schema).
  2. If `<evil:scriptRef>` is set and the named script is registered, dispatch to it. If not registered, transition FNI to `fatal`.
  3. Else if `<script>` is set, evaluate as FEEL with standard context.
  4. Else transition FNI to `fatal` (deploy-time validator also catches this).
  5. Run output pipeline: `out_mappings` (FEEL) → `result_contract` (JSON Schema) → PayloadCap.
- **Dispatch**: `ScriptDispatch` behaviour (mirrors `ServiceTaskDispatch`). `ScriptRegistryDispatch` implements it via Plugin Registry `:named_script` capabilities. `NamedScript` behaviour defines `handle_enter(flow_node, payload, context)`.
- **Always synchronous** — no `{:async, ref}` return. Plugins must return immediately.
- **No JavaScript / Python / Groovy in core.** Plugins that want foreign scripting bring their own runtime under `<evil:scriptRef>`.

#### Compensation Events

> Verified against OMG BPMN 2.0 §10.6 (Compensation) + Camunda 7/8 + Flowable. See decisions COMP-D1 through COMP-D8.
>
> Compensation is a general-purpose "undo completed work" mechanism, decoupled from whatever triggers it. The engine never auto-triggers compensation on fatal/error/escalation/abort — the modeler wires the trigger explicitly. Transaction + Cancel are a documented follow-up (COMP-D1).

- **Compensation Intermediate Throw**: Triggers compensation for completed activities with a compensation handler in the current scope. `activityRef` present → single activity; absent → broadcast to all, reverse completion order (LIFO). Synchronous: the throw FNI parks in `:waiting`, dispatches handler activities one at a time, then continues on its outgoing flow (COMP-D2). Handlers receive a snapshot of the host activity's output token.
- **Compensation End**: Same trigger/handler mechanics as the throw, then ends only the current path (consumes its token like a None End — NOT a Terminate). Does not interrupt parallel branches (COMP-D4). When the PI quiesces with `compensation_end_reached` and no stronger terminal, PI state = `:compensated`.
- **Compensation Boundary**: A passive registration carrier on an activity. Activates on host successful completion (not on start); `cancelActivity` does not apply. References exactly one handler activity via a directed `<bpmn:association>` (parsed from the BPMN XML). The handler activity is an `isForCompensation` activity with no incoming/outgoing sequence flows, dispatched only when a compensation throw/end fires.
- **Compensation Start (event subprocess only)**: A `triggeredByEvent` subprocess whose start event is Compensation. Consumes a thrown compensation for its scope and runs its inner flow (which may itself throw compensation). Registered as the scope's compensation handler. Deploy-time validator enforces this position (COMP-D5). See also ESP-D14.

#### Cancel Events (only inside Transaction Subprocess)

**Implemented in Phase 5 (TX-D1–TX-D9). See `AGENTS.md` §Transaction Subprocess + Cancel Events for full reference.**

- **Transaction Subprocess** (`bpmn:transaction`): Parsed as `:sub_process` with `is_transaction: true`. Dispatched to `FlowNodes.TransactionSubProcess` handler (TX-D1). Three outcomes: Success (normal subprocess finish), Cancel (Cancel End → LIFO compensation → `:cancelled` child PI → Cancel Boundary fires on shell), Hazard (uncaught error → fatal, no compensation — TX-D7). No nested transactions in v1 (TX-D5).
- **Cancel End Event**: Only legal inside a Transaction Subprocess (validator rule `:cancel_end_outside_transaction`). Returns `{:cancel, result}` to the child PI. Triggers automatic LIFO compensation of all completed compensable activities via `CompensationOrchestrator` before transitioning to `:cancelled` (TX-D3).
- **Cancel Boundary Event**: Only legal on a Transaction Subprocess shell (validator rule `:cancel_boundary_not_on_transaction`). Reactive (Error-model): not pre-spawned as a subscription; matched by `BoundaryResolver.find_matching_cancel_boundary/2` after the child PI reports `:cancelled` (TX-D4). Always interrupting; at most one per Transaction.
- **PI state `:cancelled`**: New terminal state for Transaction child PIs (TX-D2). Not retryable (TX-D9). Parent process continues via Cancel Boundary outgoing flow.
- **Retry restrictions** (TX-D8): (a) No retry checkpoint inside a cancelled transaction scope — `retry_checkpoint_inside_transaction`. (b) No retry of any PI with a transaction ancestor — `retry_inside_transaction_scope`. Both enforced in `validate_retriable_state` and `execute_retry_reset`.

#### Data Stores

- **Attr**: `bpmn:dataStore`, `bpmn:dataStoreReference`.
- **Handler**: Placeholder in v1 (pass-through, logged but not persisted). Full implementation is a plugin concern — plugins register a `DataStoreAdapter` by store-id.

#### Complex Gateway

- **Attr**: `bpmn:complexGateway@activationCondition`.
- **evil:** `<evil:activationCondition>` — FEEL returning boolean, evaluated on each incoming token arrival.
- **Handler**: Waits until activation condition becomes true, then emits tokens on outgoing flows. Subsequent incoming tokens gated by the condition again.

### Elements present in Studio but not in concept's priority list

All of these are in-scope. Assigned to priorities below:

| Element | Assigned tier | Rationale |
|---|---|---|
| **Send Task** | High | Semantically a simpler Service Task with built-in message throw — piggy-backs on Service Task infra |
| **Receive Task** | High | Semantically equivalent to Intermediate Message Catch Event at task level |
| **Link Intermediate Throw** | Low | Documentation/diagram concern; at runtime it's a direct "jump" to the matching Link Catch in the same process. Implement as in-memory goto |
| **Link Intermediate Catch** | Low | Counterpart to Link Throw |
| **Cancel End Event** | Low | **Implemented** — Phase 5 (TX-D3). See §Cancel Events above. |
| **Cancel Boundary Event** | Low | **Implemented** — Phase 5 (TX-D4). See §Cancel Events above. |
| **Transaction Subprocess** | Low | **Implemented** — Phase 5 (TX-D1). See §Cancel Events above. |
| **Text Annotation** | — | Parser-only, ignored at runtime (still surfaced in the deployed model via GraphQL) |
| **Group** | — | Same as Text Annotation |
| **Message Flow** | — | Collaboration-level visualization only; at runtime, throw/catch events do the real routing. Engine parses and stores for query/visualization purposes |
| **Conditional Start Event (plain processes)** | Low | Studio marks it "Currently not supported"; engine implements per BPMN spec when we reach tier Low |

### Compensation registry mechanics

> See decisions COMP-D2, COMP-D3, COMP-D7, COMP-D8.

The PI maintains an in-memory `compensation_registry` — a list of `{completed_fni_id, flow_node_id, handler_activity_id, token_snapshot, completion_order}` entries. An entry is pushed in `do_handle_fni_ok` whenever a just-finished activity has a resolvable Compensation Boundary whose `<bpmn:association>` points to an `isForCompensation` handler activity. The handler activity's token snapshot captures the host's output token at completion time (per BPMN §10.6: handlers run with the activity's completion data).

**Ordering:** entries are ordered by a monotonically increasing `compensation_completion_counter` kept in PI state. On resume, completion order is re-derived from persisted `finished_at` timestamps then FNI UUIDv7 ordering (COMP-D3).

**Resolution:** `CompensationResolver` (pure module) resolves `activityRef` → single registry entry, or absent `activityRef` → all entries in reverse completion order. `CompensationOrchestrator` (pure module, sibling of `BoundaryOrchestrator`) builds the ordered dispatch plan — queue, cursor, `{target, token, prev_ids}` descriptors. Neither module spawns FNIs; the PI executes the plan via `dispatch_flow_node_instance/4` (COMP-D7).

**Resume-safe cursor:** the throw FNI persists its ordered target list + cursor in `type_properties`. On resume, a `:waiting` compensate-throw FNI rebuilds its run and continues from the next pending target (already-completed handler FNIs are `:finished` in the DB).

**Subprocess / CA scope (v1):** embedded subprocesses and call activities are compensated as atomic units via a compensation boundary on the shell + a parent-scope handler. No cross-PI recursion into child PI internals (COMP-D8). BPMN's deeper rule — recurse into completed embedded-subprocess scopes — is a documented follow-up; call-activity non-propagation is permanent per spec.

---

## 8. Expression engine (FEEL)

> Full specification: [`architecture/expressions.md`](./architecture/expressions.md)

The engine ships a deliberately lean FEEL context with exactly seven root
bindings (`token`, `this`, `context`, `dataObjects`, `process`,
`processInstance`, `identity`) plus a `loop.*` overlay for MI/standard-loop
iterations. No `token.history`. Expressions are precompiled at deploy time;
the runtime hot path is bind + evaluate only.

**Library decision (Phase 0, Item 13): Rust NIF via dsntk + Rustler.**
The `dsntk` crates (`dsntk-feel-parser` 0.3, `dsntk-feel-evaluator` 0.3)
provide full DMN FEEL 1.3 grammar coverage with parse/evaluate separation.
Expressions are compiled at deploy time into an opaque `ResourceArc` held
on the Elixir side; runtime evaluation is native-speed Rust with no parsing
overhead. See the architecture doc for the full decision rationale, type
bridge, unary-test wrapping, and module layout.

---

## 9. Plugin system & SDKs

> Full specification: [`architecture/plugins.md`](./architecture/plugins.md)

The engine uses a hybrid plugin model: in-BEAM OTP-app plugins for
maximum performance and gRPC sidecar plugins for language-agnostic
extensibility. Both tiers feed a single Plugin Registry, making every
downstream consumer (Service Task dispatch, EngineEventBus fan-out, API
extension routing) oblivious to the plugin's origin. See the architecture
doc for plugin categories (8 behaviours), lifecycle phases (on_load /
on_ready), the engine_facade contract, failure isolation and quarantine
semantics, and SDK packages.

---

## 10. API design

> Full specification: [`architecture/api.md`](./architecture/api.md)

The API has three wire surfaces: REST (trigger-style, under `/api/v1/`),
GraphQL (AshGraphql for persistence resources + compile-time-derived Process
Model graph ), and WebSocket (Phoenix Channels for live subscriptions).
JWT bearer required by default. Payload cap enforced at every boundary. See the architecture doc for the REST endpoint table, GraphQL schema
(queries, mutations, subscriptions, finalTokens calculation), Process Model
graph shape, WebSocket topics, OpenAPI/SDL, and the API-vs-Core boundary rule.

---

## 11. Observability

> Full specification: [`architecture/observability.md`](./architecture/observability.md)

v1 observability covers: structured JSON logs (console sink),
`/stats` JSON snapshot endpoint, live WebSocket push, and Prometheus
`/metrics` (via PromEx). No OpenTelemetry or distributed tracing in core.
Plugin sinks extend the surface to external systems (Datadog, Kafka, etc.)
without touching core. See the architecture doc for sink defaults, the
debugger reconstruction model (always-on kernel tables vs. optional DB sink),
the `/stats` JSON shape, and the admin HTML dashboard.

---

## 12. Testing strategy

> Full specification: [`architecture/testing.md`](./architecture/testing.md)

Six test layers: per-handler unit tests, property-based tests (stream_data +
Concuerror), a BPMN conformance corpus (.bpmn + YAML spec), integration tests
against real Postgres (20+ named scenarios including crash-resume variants,
payload-cap rejection, and token-storage shape assertions), k6 load tests
targeting 10k concurrent PIs, and CI enforcement (format, credo, dialyzer,
coverage gate ≥ 85 %, sobelow, deps.audit). See the architecture doc for the
full scenario matrix, assertion framework, and infrastructure setup.

---

## 13. Security

> Full specification: [`architecture/security.md`](./architecture/security.md)

JWT auth via Joken + JOSE (HS256 / RS256 / ES256, JWKS with
caching), pluggable via `@behaviour EvilEngine.Plugin.AuthProvider`.
Default-deny authorization model (see authorization.md).
JSON Schema 2020-12 input validation on all inbound payloads. Sidecar
plugins OS-isolated; in-BEAM plugins run inside the trust boundary with
privileged identity. TLS is a reverse-proxy concern. See the architecture
doc for the full threat model, per-surface security controls, and explicit
non-goals.

---

## 14. Packaging & ops

> Shipping and deployment: [`architecture/shipping.md`](./architecture/shipping.md)
> Configuration and runtime behavior: [`architecture/configuration.md`](./architecture/configuration.md)

Docker on debian:12-slim with `mix release`; docker-compose (engine +
postgres only in v1). Configuration via env vars (`EVIL_*`) with
`runtime.exs` and optional `/etc/evil-engine/engine.toml`. The full env
vars table (~50 entries) is in the configuration doc. Also covered: the
linter-score deploy gate, zero-downtime deploy options, and the
two-pass RetentionRunner (PI-scoped + engine-audit-scoped
housekeeping with monthly partitioning).

---

## 15. Phases, priorities & order

The full phased roll-out plan — Phase 0 (Foundation) through Phase 7
(Studio adaptation), with per-phase task lists, exit criteria, and the
phase-priorities summary table — has been extracted into its own document
so this plan stays focused on **what** to build while the phase doc owns
**in what order** to build it.

> See [`ImplementationPhases.md`](./ImplementationPhases.md) for the
> authoritative working plan used by coding agents and contributors.

All section references (`§N`, `§N.M`) in that
document point back into this plan; this plan, in turn, defers all
roll-out ordering to [`ImplementationPhases.md`](./ImplementationPhases.md).

---

## 16. Open items, defaults, and risks

### 16.1 Defaulted decisions

All batch-3 items have been resolved by the user in a follow-up round. **There are no
agent-defaulted decisions left in this plan.**

### 16.2 Open technical questions (to be answered during phases)

1. **FEEL library maturity** — resolved at Phase 0 end when `feel_ex` (or chosen lib) is evaluated against DMN FEEL TCK; if fails, subset implementation kicks in.
2. **Inclusive-gateway deploy-time analysis** — the BPMN spec allows constructs that are statically ambiguous for inclusive joins. Phase 4 will define which constructs are accepted and which are rejected at deploy time.
3. **Compensation ordering across subprocesses nested inside call activities** — the spec defers to implementation; we will fix a deterministic order ("nearest first, then outwards") in Phase 3.
4. **Data Contract referencing** — inline (CDATA in BPMN) vs external URI (fetched at deploy time). Phase 1 will pick one; the other can be added later.
5. **UUIDv7 availability** — Postgres 17 has native `uuidv7()`; on Postgres 16 we generate client-side. Phase 0 confirms deployment target.

### 16.3 Risks and mitigations

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| `feel_ex` insufficient → we own a FEEL implementation | Medium | High (effort) | Start FEEL-subset impl early in Phase 0; keep it compatible with a later lib swap |
| Ash does not expose the performance characteristics the engine needs | Low | High | Ash is used only for the API / read-model / persistence layer. Core uses plain OTP. Can degrade to bare Ecto without touching Core |
| Postgres becomes bottleneck at 10 k concurrent PIs | Medium | High | Partial indexes + JSONB GIN + connection pool tuning in Phase 5; ability to shard by `process_version_id` if needed |
| Plugin sidecar latency hurts Service Task throughput | Medium | Medium | Default HTTP handler is in-BEAM; sidecar plugin is opt-in for Service Tasks with heavier work anyway |
| BPMN spec corners (e.g., "terminate end event" in subprocess containing call activity) | High | Medium | Per-corner-case ADR (architecture decision record) committed to `docs/adrs/` before implementation |
| Hot-code-upgrade regressions | Medium | High | Phase 5 includes rehearsal. Blue/green is the always-available fallback |
| 29–40 week estimate is wildly wrong | High | Low (plan-level) | Phase 1 is a forcing-function checkpoint; re-estimate at end of Phase 1 |

### 16.4 Explicit non-goals for v1

- Multi-tenant process isolation at engine level (one engine = one tenant boundary; multi-tenancy is a deployment concern via multiple engines or a plugin).
- Built-in DMN engine (delegated to external DMN service or plugin).
- Full SPA admin UI.
- ~~**Prometheus `/metrics` endpoint.**~~ *Resolved ahead of schedule.* The engine now exposes a Prometheus-format `/metrics` endpoint via PromEx. The endpoint is documented in the OpenAPI spec.
- **OpenTelemetry export** — logs, metrics, and distributed traces via OTLP are all deferred.
- ~~**Pluggable authentication** (`AuthProvider` behaviour, OIDC/mTLS/etc.). JWT-only in v1.~~ *Resolved.* Auth is now pluggable via `@behaviour EvilEngine.Plugin.AuthProvider`. What remains a non-goal is **pluggable claim resolution** — a `ClaimResolver` behaviour that lets providers override how the engine evaluates individual claims (e.g. `has_claim?(identity, "deploy_bpmn")` backed by LDAP lookups, graph queries, or request-context-dependent logic instead of flat `Identity.claims` map reads). In the Level 1 model, providers own the full translation from their native identity system to the engine's claim dictionary inside `verify_and_resolve/1` — all claims must be materialized upfront at authentication time and placed into `Identity.claims`. This is sufficient when the identity backend can resolve all relevant claims in a single pass (JWT decode, OIDC userinfo call, single graph query). It becomes limiting if: (a) claim evaluation depends on request context not available at auth time (e.g. "can this user deploy to *this specific* process?"), (b) claims are expensive to compute and most requests only need a subset (lazy evaluation), or (c) the identity backend requires per-claim round-trips that should not all run on every request. If customers report these patterns, v2 should introduce a `ClaimResolver` behaviour with a `resolve_claim(identity, claim_key, context)` callback, and migrate the engine's claim-check sites (Ash policies, controller checks, channel checks) to dispatch through it.
- **Plugin-tier authorization.** In v1, plugins run with a privileged `plugin:<name>` identity that bypasses all engine claim checks ([`Authorization.md`](./architecture/authorization.md) §7). There is no per-plugin claim set, no per-plugin allow/deny for individual `EvilEngine.Api.*` actions, and no operator-configurable plugin permission model. Plugins are inside the trust boundary by definition (the operator loaded them into the release or into the sidecar directory). If multi-tenant deployments demand per-plugin capability scoping, it becomes a v2 story alongside the tenant-isolation model.
- **Call Activity version pinning** (`<evil:calledProcessVersion>`). Call Activities always resolve to the latest enabled version at spawn time.
- **Multi-property BPMN 2.0 correlation** (Option C). Each Message catch / boundary / start correlates on exactly **one** value derived from a single FEEL expression. `bpmn:correlationKey` / `bpmn:correlationProperty` / `bpmn:correlationPropertyRetrievalExpression` / `bpmn:correlationSubscription` are not parsed; only the `<evil:correlationKey>` / `<evil:correlationRetrievalExpression>` extensions are.
- **Durable `message_subscriptions` table.** Subscriptions live only in memory and are rebuilt by each PI on resume (§3.5.5). There is no per-subscription row in the database.
- **Cross-cluster / multi-node message routing.** Routing is per-node; when the engine clusters, a future design will address cross-node delivery. For v1, messages published on one node reach only subscriptions on that same node; single-node deployment is expected.
- **External / API-level Data Object write endpoint.** There is no `PUT /process-instances/{id}/data-objects/{name}` in v1. All writes originate from a Flow Node's execution via `dataOutputAssociation` (this is now the **only** write path; see non-goal "Handler-API Data Object writes" below). External observers can only **read** Data Objects (via GraphQL); writing from outside a PI would bypass the FNI-attribution invariant.
- **Handler-API Data Object writes.** There is no `write_data_object/2` function on the PI Facade in v1. All Data Object writes originate from `bpmn:dataOutputAssociation` on a Flow Node — handlers produce DO values exclusively by returning the corresponding fields on their FlowNodeResult, which the DOA then projects at FNI-commit time. The prior two-write-path model (DOA + handler-API) added surface area without a clear BPMN-spec justification (DOA is what BPMN defines; the facade function was an ergonomic shortcut for mid-execution progress writes and streaming aggregators). Removing it tightens the FNI-attribution invariant — one write ↔ one owning FNI, trivially — and drops the `source` column from `data_object_writes`. Use cases the facade was meant to serve (progress/checkpoint DOs, streaming aggregators) are covered equivalently in v1 by modeling the Flow Node as a sequence of small Flow Nodes each with their own DOA, or by using token-passing through a parallel monitoring branch. v2 may revive a narrower handler-facing write path if the load-test data shows real demand.
- **Default-ON DB event sink.** The `database` EventSink is default-OFF — a fresh engine install writes `process_instance_events` rows only after the operator explicitly sets `EVIL_EVENT_SINK_DATABASE=on`. Operators running external observability (Datadog, Loki, Kafka, etc.) typically leave it off and register plugin sinks instead. Debugger BPMN-flow reconstruction does **not** require the DB sink (see §11.1): `flow_node_instances.triggerer_flow_node_instance_id`, `process_instances.triggerer_flow_node_instance_id` / `parent_process_instance_id`, and the always-on `messages` / `signals` / `escalations` / `data_object_writes` / `engine_timers` tables already carry the full sender↔receiver trail for every BPMN-element-sourced event, live or historical. The DB sink is instead the integration point for a flat, SQL-queryable engine event log (compliance audit, severity sweeps, plugin-emitted events that have no BPMN source element).
- **Event replay / backfill after enabling the DB sink.** If events were emitted while the DB sink was off, those rows are permanently absent from `process_instance_events`. The engine keeps no shadow in-memory buffer for retroactive persistence. Operators who want historical-event coverage must turn the DB sink on before the events they care about happen, or capture events through a different sink.
- **At-least-once delivery guarantees on sinks.** `EngineEventBus` is **at-most-once** per sink. Sinks that need stronger guarantees (Kafka with `acks=all`, for example) must implement buffering + retry inside their own `handle_event/2`. The engine exposes no queueing / DLQ / ACK protocol in v1.
- **`Event.SinkFailed` auto-recovery.** A crashing sink is isolated (the other sinks keep running) and emits `Event.SinkFailed` for observability, but the engine does not retry the failed event into that sink, does not auto-disable persistently-failing sinks, and does not escalate sink failures to `/health`.
- **Automatic archival to external storage.** The `RetentionRunner` deletes purged PIs locally. Shipping purged data to S3 / GCS / cold-storage Postgres before deletion is delegated to plugin sinks subscribing to `Event.RetentionPurged`; the engine ships no built-in archival adapter.
- **Continuous partition-automation.** `process_instance_events` and `data_object_writes` are partitioned by month, but v1 uses a boot-time `mix evil.partitions.ensure` (looking `EVIL_PARTITION_AHEAD_MONTHS` ahead) rather than a `pg_partman`-style background worker. Operators whose engine never restarts for many months must schedule an external `mix` invocation or accept eventual partition-miss on month rollover (the engine will then create the missing partition lazily — correct but slower on the first write of that month).
- **Partition-drop archival in v1.** The partitioning shape makes future `DETACH PARTITION` + `DROP PARTITION` archival cheap, but v1 `RetentionRunner` uses row-by-row transactional deletes so that the `Event.RetentionPurged` event can be emitted per PI, preserving audit-sink fidelity. Partition-drop archival becomes viable once a user accepts coarse-granularity "entire month X was purged" semantics.
- **Per-PI retention overrides.** Retention is per-terminal-state max-age, engine-globally. There is no `<evil:retainForever>` extension, no API to pin a specific PI against purge, and no tag-based policy. Operators who need long-term retention for a subset of PIs register a sink plugin that ships those PIs' data to external long-term storage before the retention runner purges them.
- **Auto-enabled retention defaults.** Every `EVIL_RETENTION_*_DAYS` env var is unset by default; a fresh engine installation never deletes anything until the operator explicitly sets at least one. This prevents silent mass-deletion on the day a policy would first kick in.
- **Catalog-row retention.** `processes` and `process_versions` are never touched by retention policies or manual purge. Their lifecycle remains governed by soft-delete. The engine cannot tell whether a running PI elsewhere in the cluster still depends on a soft-deleted version, so catalog rows are retained indefinitely for safety.
- **Event-level retention within a PI.** In v1 a PI's `process_instance_events` rows live as long as the PI row does. There is no "keep the PI but drop events older than 7 days" policy — that would require per-PI partial-retention tracking the engine does not support.
- **Content-addressed blob store for large payloads.** A `payload_blobs(hash, bytes, refcount)` table with write-path SHA-256 + upsert and read-path JOIN was considered for v1 to eliminate within-PI / cross-PI JSONB duplication. Deferred post-v1 on complexity-vs-payoff grounds: the write-path hash+upsert contention, read-path JOIN, and GC (refcount or mark-and-sweep) add non-trivial operational surface area for a payoff that is dominated by within-PI dedup (cross-PI dedup requires bitwise-identical payloads, which identity/trace fields usually break). Phase 5 load tests decide whether to revisit.
- **`flow_node_instances.output_token` elimination.** `output_token` is a persistence shadow of the next FNI's `input_token` for typical transitions, and a true kernel artifact only when a gateway or transform sits between two FNIs. Dropping it would require a join-heavy "effective output" projection and break the current FNI-local debugging shape. Deferred post-v1; revisit only if Phase 5 load tests show `output_token` is a dominant storage cost.
- **Cross-PI token deduplication.** The assumption "1000 PIs carrying the same 20 KiB webshop order stored once" only holds when tokens are bitwise-identical after canonicalization. Real-world PIs carry identity, correlation, and trace fields that break cross-PI hash-equality; cross-PI dedup is an observed minority of total JSONB volume. Any future blob-store design must justify itself primarily on within-PI dedup, not cross-PI.
- **Per-process / per-endpoint payload-cap overrides.** `EVIL_TOKEN_MAX_BYTES` is engine-global. There is no `<evil:tokenMaxBytes>` extension, no per-endpoint override, and no per-caller override. Workloads with radically different legitimate payload sizes run on separate engine deployments or raise the global cap.
- **Per-table retention granularity for engine-audit tables.** One knob — `EVIL_RETENTION_ENGINE_AUDIT_DAYS` — covers all six engine-audit tables (`messages`, `pending_messages`, `signals`, `escalations`, `compensations`, terminal-state `engine_timers`). There is no `EVIL_RETENTION_MESSAGES_DAYS` / `EVIL_RETENTION_SIGNALS_DAYS` / etc. Operators who genuinely need asymmetric per-table retention (e.g. "keep messages for 1 year, signals for 30 days") register a plugin sink subscribing to `Event.EngineAuditPurged` to ship deleted rows to external storage with custom per-table retention rules there.
- **Manual purge mutation for engine-audit tables.** The PI-scoped `purgeProcessInstances` mutation has no engine-audit equivalent in v1. `purgeEngineAudit(olderThan, tables, dryRun, batchSize)` was considered and deferred on surface-area grounds — operators wanting ad-hoc engine-audit cleanup set `EVIL_RETENTION_ENGINE_AUDIT_DAYS` temporarily low or run direct SQL under the admin DB role. Revisit post-v1 if operational demand for one-off selective engine-audit purges materializes.
- **PI-cascade deletion of engine-audit rows.** When a PI is purged (by retention or manual), the corresponding `messages` / `signals` / `escalations` / `compensations` rows that *happened to reference* that PI via their `correlations[]` / `origin` JSONB are **not** deleted with it. The relation is by JSONB content, not by foreign key, and broadcast / cross-PI semantics make "which PI owns this row?" ambiguous anyway. Engine-audit rows age out on their own clock retention or persist until manually cleaned up. This is intentional — a published message is an engine-wide event, and deleting its audit record because one of its 5 recipients was purged would misrepresent history.
- **Partition-drop archival for engine-audit tables.** Same stance as for `process_instance_events` / `data_object_writes` — the partitioning shape makes v2 `DETACH`+`DROP`-based archival cheap, but v1 uses row-by-row `DELETE` inside the `RetentionRunner` so that `Event.EngineAuditPurged` can be emitted with accurate per-table row counts.
- **Cross-PI linkage of `messages.correlations[]` to FNIs.** The `correlations` array stores `{process_instance_id, flow_node_instance_id, delivered_at}` entries. After a PI is purged, the `process_instance_id` / `flow_node_instance_id` values in any surviving `messages` rows become dangling references (pointing at rows that no longer exist). This is accepted as a documented audit artifact — the `messages` row is still an honest record of "this message was delivered to PI X at time T"; consumers joining these IDs against `process_instances` / `flow_node_instances` must handle missing rows gracefully.

---

## Appendix A — Original product concept `AGENT:` / `TODO:` markers, resolved

| Marker in the original product concept | Resolution in this plan |
|---|---|
| "Based on the decided Tech Stack describe which type of schema/data contract is most suitable" | §1 / §4 — JSON Schema 2020-12 |
| "Make Recommendation based on stated requirements" (Tech Stack) | §1 — Elixir + Ash + Postgres, as justified in chat and §1 |
| "Add more events as required" (PI lifecycle events) | §5.3 — extended list |
| "Add more access points as required" (PI handler) | §5.4 — extended list |
| "Describe in detail the properties, lifecycle, the responsibilities and functions of a Process Instance" | §5 + §3.1 + §3.5 |
| "Describe in detail how each of the listed Flow Nodes is going to be implemented" | §7, per-element |
| "Include named lists of all properties and extension / custom properties used by each element" | §7 per-element sub-tables |
| "Check for elements not listed here" | §7 end-of-section table (Send/Receive/Link/Cancel/Transaction/TextAnnotation/Group/MessageFlow) |

## Appendix B — Glossary

The full glossary — covering both the BPMN-level terminology originally
introduced in the original product concept's glossary and every
engine-implementation term defined in earlier revisions of this appendix — has
been extracted into its own document to keep this plan focused.

> **See [`Glossary.md`](./Glossary.md) for every term definition.** That file
> is the single source of truth for all engine vocabulary; this plan links out
> rather than re-inlining the definitions.

Glossary topics include, among others: Identity, Data Contract, Access Point,
PI Facade, EngineEventBus, EventSink, Retention Policy, Manual Purge, Plugin
Host, Seeding Directory, Latest Version, Soft-delete, Linter Ruleset Score,
Linter Gate, Published Language, Parsed Process Model AST, Model Cache,
Message Correlation, Correlation Key, Correlation Retrieval Expression,
Correlation Value, Pending Message, Pending Signal, Pending Escalation, Data
Object Snapshot, Data Object Write, Escalation Scope Chain, Cross-PI
Escalation, Process Model Graph, Moddle Descriptor, Engine SDK Parser
Re-Export, Token Cap, `gateway_pending_arrivals`, `finalTokens`, LZ4 JSONB
compression, Engine-Level Audit Tables, Engine-Audit Retention,
Delete-on-Transition, `Event.EngineAuditPurged`.

To add a new term, edit [`Glossary.md`](./Glossary.md) directly. Do not
re-inline definitions here.
<!-- Former inline entries moved to Glossary.md as part of the docs split
(Architecture.md / Schema.md / Glossary.md / ImplementationPhases.md). -->

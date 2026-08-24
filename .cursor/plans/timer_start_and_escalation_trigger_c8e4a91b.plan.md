---
title: Timer Start persistence, dead-table drop, no restart route, REST escalation trigger
date: 2026-08-24
status: PENDING APPROVAL
---

# Timer Start persistence and escalation trigger

> **For agentic workers:** Execute workstreams in order. Do **not** create git commits (repo policy: the developer commits). After each workstream that touches `.ex` / `.exs`, run the Engine verification pipeline from the project root (`mix compile --warnings-as-errors`, `mix credo --strict`, then the relevant tests). Start the PostgreSQL test container before any test command. After TypeScript changes, build/test the affected `packages/js/*` package. After Studio changes, follow the Studio build rule (`npm run build` / `lint:fix` / `format` in `studio/`).

**Goal:** Persist cycle Timer Start schedules across engine restart; delete the dead `escalations` / `compensations` / `engine_timers` audit-table spec and the unused `POST .../restart` route; ship a REST (and facade) escalation trigger so the Studio debugger can inject escalations the same way it injects messages and signals.

**Architecture:** Timer Start already has a persistence behaviour and a boot reload hook; only the Postgres adapter and table are missing. Escalation runtime already matches waiters (pre-spawned boundary FNIs + reactive ESP starts); the new API delivers a code to those waiters. It does not walk the parent chain, does not pending-buffer, and does not create an `escalations` table.

**Tech Stack:** Elixir/OTP umbrella, Ash/AshPostgres, Phoenix REST, TypeScript SDK/client, Bifrost Forge World debugger overlays.

## Global constraints

- Project name: **ThomasTheDaemonEngine** (never "Evil Engine" in new copy). Studio: **Bifrost Forge World**.
- No abbreviations in new identifiers.
- GraphQL stays **query-only**. Commands stay on REST + plugin facade.
- Single-migration policy: edit `apps/peripheral_persistence/priv/repo/migrations/20260501110314_create_initial_schema.exs` in place. Do **not** add a new migration file.
- Test DB: `(docker inspect --format='{{.State.Running}}' evil-engine-postgres-test 2>/dev/null | grep -q true) || (docker start evil-engine-postgres-test 2>/dev/null || bash scripts/create-test-db.sh) && docker exec evil-engine-postgres-test pg_isready -U evil_engine && MIX_ENV=test mix ecto.migrate`
- After editing the initial migration, reset the test DB: `MIX_ENV=test mix ecto.reset` then `MIX_ENV=test mix ecto.migrate`.
- User commits; agents never `git commit` / `git push`.
- Do not implement Phase 7 RetentionRunner, soak/load, sidecar, or GraphQL mutations.

---

## Locked resolutions (from the user, 2026-08-24)

| Item | Resolution |
|------|------------|
| 1. Timer Start Postgres persistence | **Fix.** Real gap. Ship the Ash adapter and a table. |
| 2. `escalations` / `compensations` tables | **Drop entirely** from spec, schema docs, retention Pass B, and `Event.EngineAuditPurged`. Not deferred. |
| 2b. `engine_timers` | **Part of item 1, not the old audit table.** PI-scoped timers stay in FNI `type_properties` + Scheduler ETS. The new table is operational (`timer_start_schedules`) and matches `EvilEngine.Timers.Persistence`. Delete the `engine_timers` audit-table spec. |
| 3. `POST /process-instances/{id}/restart` | **Drop entirely.** `PUT .../retry` is sufficient. |
| 4. REST escalation trigger | **Ship.** Studio debugger must be able to trigger escalations via API, analogous to messages and signals. |

### Derived design (not a user fork)

**TIM-D1 — table name `timer_start_schedules`.** The old `engine_timers` DDL mixed PI-scoped catch/boundary timers (already persisted on the FNI) with deploy-scoped cycle Timer Starts. Creating that hybrid table would duplicate FNI state. The behaviour in `apps/core_timers/lib/evil_engine/timers/persistence.ex` already defines the cycle-start record shape; the Ash resource maps 1:1 onto it.

**ESC-API-D1 — named engine-wide waiter delivery, not a BPMN throw.** Handbook rule: escalation travels *upward* from a throw; a parent cannot push into a child. This API is a **debugger/operator inject**, the same class as `POST /messages/{name}/trigger` and `POST /timer-events/{id}/trigger`.

- Route: `POST /escalations/{escalation_code}/trigger` (path param, like messages/signals). The old `POST /triggers/escalations` is not revived.
- Claim: existing boolean `trigger_escalation` via `Validation.check_claim/3` (not `none\|all`).
- Body: empty or `{}`. Escalations carry no payload (like signals). No `processInstanceId` filter in v1 (same as messages).
- Semantics: for every **running** PI, deliver to matching **waiting catchers** in that PI:
  1. Escalation Event Subprocess start (existing `EspScope.resolve_escalation_catch/2`).
  2. Waiting Escalation Boundary FNIs whose code matches (`EscalationResolver` specificity: specific code beats catch-all). Fire through the existing `BoundaryOrchestrator.handle_boundary_catch/5` path (do not invent a second finish path).
- **Do not** `notify_parent` / walk the parent chain (the parent PI is scanned on its own).
- **Do not** transition a PI to `:escalated` when nothing matched (no waiter → skip that PI).
- **Do not** insert pending rows (escalation D1 stands).
- **Do not** create an `escalations` audit table. Observability remains `Event.EscalationRaised` on EngineEventBus (`throwType: "api_trigger"`).
- Response (camelCase): `{escalationCode, deliveries: [{processInstanceId, flowNodeInstanceId}], pending: false}`. No `startedProcessInstanceIds` (there is no top-level Escalation Start Event).
- Catch-all waiters match any triggered code (existing resolver). Path param must be non-blank; 422 `escalation_code_blank` otherwise. Studio overlay on a catch-all boundary still sends a non-blank code (any unused code matches only catch-alls plus other catch-alls).

**API-D1 — no restart command.** Delete every "specified, not implemented" `POST /process-instances/{id}/restart` row. Retry stays `PUT /process-instances/{id}/retry`. Prose that says "retry/restart" as a synonym for retry may stay; a distinct restart *route* must not.

---

## Out of scope

- Phase 7 RetentionRunner implementation (docs in this plan only *stop lying* about dropped tables).
- Persisting PI-scoped catch/boundary timers in SQL (already crash-safe via FNI `type_properties`).
- Pending-escalation cache (D1).
- GraphQL mutation for escalation trigger or timer schedules.
- Changing `trigger_message` / `trigger_signal` from `none\|all` to boolean (or the reverse).
- Compensation REST trigger.
- Clustering / Horde.

---

## File map

### Create

| Path | Role |
|------|------|
| `apps/peripheral_persistence/lib/evil_engine/persistence/resources/timer_start_schedule.ex` | Ash resource for `timer_start_schedules` |
| `apps/peripheral_persistence/lib/evil_engine/persistence/timer_start_schedule_adapter.ex` | `@behaviour EvilEngine.Timers.Persistence` |
| `apps/peripheral_persistence/test/evil_engine/persistence/timer_start_schedule_adapter_test.exs` | Adapter unit tests (sandbox) |
| `apps/api_web/lib/evil_engine_web/http/controllers/escalation_controller.ex` | REST trigger |
| `apps/api_web/test/evil_engine_web/http/controllers/escalation_controller_test.exs` | HTTP + claim tests |
| `apps/engine_sdk/lib/evil_engine/engine_facade/escalations.ex` | `facade.escalations.publish/1` |
| `test/integration/execution/timer_start_persistence_test.exs` | Deploy → kill ETS → reload → still fires |
| `test/integration/execution/escalation_trigger_test.exs` | REST inject into waiting boundary + ESP + auth |
| `packages/js/sdk/src/` (types for `EscalationTriggerResult`) | Extend `types/trigger.ts` |
| Studio: `studio/src/modules/engine-debugger/overlays/TriggerEscalationEventLink.tsx` | Overlay, mirrors message/signal |

### Modify (Engine)

| Path | Change |
|------|--------|
| `apps/peripheral_persistence/priv/repo/migrations/20260501110314_create_initial_schema.exs` | Create `timer_start_schedules` + indexes; update `@moduledoc` Contains list and `down/0` |
| `apps/peripheral_persistence/lib/evil_engine/persistence/api.ex` | Register the new resource |
| `apps/peripheral_persistence/lib/evil_engine/persistence/release.ex` | Stop mentioning specified-not-migrated audit tables |
| `config/config.exs` | `:core_timers, :persistence_module` → `EvilEngine.Persistence.TimerStartScheduleAdapter` |
| `config/test.exs` | Keep `Persistence.NoOp` (core_timers unit tests) |
| `test/support/execution_case.ex` | `Application.put_env(:core_timers, :persistence_module, TimerStartScheduleAdapter)` in setup; restore NoOp on exit |
| `apps/core_timers/lib/evil_engine/timers/persistence.ex` | Moduledoc: adapter **is** implemented; NoOp is test-only |
| `apps/api_web/lib/evil_engine_web/http/router.ex` | `post "/escalations/:escalation_code/trigger"` |
| `apps/api_web/priv/openapi/spec.yaml` | New operation; no restart path |
| `apps/api_facade/lib/evil_engine/api.ex` | `trigger_escalation/3` (or `publish_escalation/3`) |
| `apps/core_execution/lib/evil_engine/execution.ex` + `process_instance.ex` | Inject/waiter-fire entry |
| `apps/core_types/lib/evil_engine/types/event.ex` | `throw_type` allows `:api_trigger` on `EscalationRaised` |
| `apps/engine_sdk/lib/evil_engine/engine_facade.ex` | `escalations` namespace |
| `apps/peripheral_plugins/lib/evil_engine/plugins/loader.ex` | Wire `skip_claims: true` |
| `packages/js/sdk/src/types/trigger.ts`, `errors/`, `plugin/engine-facade.ts`, `index.ts` | Types + facade |
| `packages/js/client/src/rest/event-client.ts`, tests, `test/support/test-engine.ts` | `triggerEscalation`; mint `trigger_escalation: true` |
| Docs listed in Workstream 3 |

### Modify (Studio)

| Path | Change |
|------|--------|
| `studio/src/modules/engine-core/commands/CommandContract.ts` | `triggerEscalation` |
| `studio/src/modules/engine-core/commands/registerEventCommands.ts` | `client.events.triggerEscalation(code)` |
| `studio/src/modules/engine-debugger/overlays/OverlayFactory.ts` | Overlay on active escalation catch (boundary) |
| `studio/src/modules/engine-debugger/initializers/initializeCommands.ts` | `engine.debugger.triggerEscalationEvent` |
| `studio/src/modules/engine-debugger/overlays/index.ts` | Export |

---

## Workstream 1 — Timer Start Postgres adapter

**Pre-condition:** `EvilEngine.Timers.Persistence` callbacks and `StartEventManager` are unchanged in contract. `Persistence.Application` already calls `StartEventManager.reload_start_schedules/0` after Repo start. Production config currently points at `NoOp` (`config/config.exs`).

### Schema

Add unpartitioned table `timer_start_schedules` to the initial migration (new section after catalog / execution, not in `EvilEngine.Persistence.Partitions`):

| Column | Type | Notes |
|--------|------|--------|
| `id` | uuid PK | `uuid_generate_v7()` |
| `process_version_id` | uuid NOT NULL | FK `process_versions(id)` ON DELETE CASCADE |
| `process_model_id` | text NOT NULL | BPMN process id (query convenience; not a FK) |
| `flow_node_id` | text NOT NULL | Timer Start Event id |
| `kind` | text NOT NULL | `"cycle"` (date/duration starts are PI-scoped and must not be inserted) |
| `iso_spec` | text NOT NULL | Literal ISO 8601 cycle |
| `enabled` | boolean NOT NULL default true | |
| `next_fire_at` | timestamptz NULL | nil when exhausted |
| `last_triggered_at` | timestamptz NULL | |
| `cycle_total` | integer NULL | nil = infinite |
| `cycle_remaining` | integer NULL | nil = infinite |
| `scheduler_ref` | text NULL | Opaque Scheduler timer ref |
| `inserted_at` / `updated_at` | timestamptz | Ash timestamps |

Indexes:

- UNIQUE `(process_version_id, flow_node_id)`
- `(enabled, next_fire_at)` for `list_armed_schedules`
- `(process_version_id)` already covered by unique prefix; keep if the unique is not used for version deletes

Check: `kind = 'cycle'`.

`down/0`: `drop table(:timer_start_schedules)`.

This table is **operational**, not engine-audit. Retention Pass B must **not** DELETE it. Soft-delete of a process version already calls `StartEventManager.unregister_timer_starts/1`, which deletes rows. Hard delete of `process_versions` cascades.

### Ash resource + adapter

Mirror `MessagePersistenceAdapter`: `authorize?: false`, `PersistenceRetry.with_retry/3`.

Map Ash records ↔ `schedule_record()` maps expected by `StartEventManager` (string ids, atom-less `kind` as string `"cycle"`). `create_schedule/1` generates id if omitted. `list_all_schedules/1` honours `process_version_id:` filter. `list_armed_schedules/0` = `enabled == true AND next_fire_at != nil`, sorted by `next_fire_at`.

No `child_spec/1` on the adapter (it is not a process). `Timers.Application.persistence_child/0` already skips modules without `child_spec/1`.

### Config wiring

- `config/config.exs`: `:core_timers, persistence_module: EvilEngine.Persistence.TimerStartScheduleAdapter`
- `config/test.exs`: keep `NoOp` so `apps/core_timers` unit tests stay in-memory
- `test/support/execution_case.ex`: switch to the Ash adapter for umbrella integration tests (same pattern as `ExecutionAdapter`)

`peripheral_persistence` already calls `reload_start_schedules/0` at boot. After this workstream that call loads real rows.

Add `{:core_timers, in_umbrella: true}` to `apps/peripheral_persistence/mix.exs` deps if the adapter compile requires an explicit dep (it currently reaches `StartEventManager` only transitively via `core_execution`).

### Tests

Adapter (sandbox):

- create / get / update / delete-for-version
- `list_armed_schedules` omits disabled and exhausted (`next_fire_at` nil)
- unique `(process_version_id, flow_node_id)` conflict → `{:error, _}`
- FK: unknown `process_version_id` fails

Integration (`test/integration/execution/timer_start_persistence_test.exs`):

1. HTTP-deploy a process with a cycle Timer Start (`timeCycle`, short interval e.g. `R/PT1S` or a test-friendly cycle).
2. Assert a `timer_start_schedules` row exists (`enabled`, `kind = cycle`, `next_fire_at` set).
3. Cancel Scheduler entries for that version **without** deleting DB rows (simulate BEAM restart: ETS gone, Postgres intact).
4. Call `StartEventManager.reload_start_schedules/0`.
5. Assert a new PI is started when the cycle fires (existing `TimerStartListener` path).
6. Soft-delete the version → row gone, no further PIs.

Keep existing `start_event_manager_test.exs` on NoOp.

### Docs in this workstream

- `docs/architecture/timers.md` — adapter implemented; production module; boot reload is real
- `docs/architecture/common-pitfalls.md` §P69 — rewrite: the mistake is now "pointing production at NoOp"; correct approach is the Ash adapter
- `docs/architecture/data-model.md` / `docs/Schema.md` — add `timer_start_schedules`; remove `engine_timers` spec block and ER edges to PI/FNI
- `docs/ImplementationPlan.md` §3.4 — persist to `timer_start_schedules`, not `engine_timers`
- `docs/ImplementationPhases.md` Phase 3 items 1–2 — note Postgres adapter shipped (keep DONE)
- Phase 7 item 4 Pass A/B — delete "specified not migrated `engine_timers`"; say Timer Start rows are operational and deleted on undeploy/unregister only

- [ ] **1.1** Add table + Ash resource + adapter + config + ExecutionCase env
- [ ] **1.2** Adapter tests + integration restart test (DB running)
- [ ] **1.3** `mix compile --warnings-as-errors && mix credo --strict` + the new tests
- [ ] **1.4** Timer/data-model/pitfall/plan docs for the adapter (do not yet do the full dead-table sweep; that is WS3)

---

## Workstream 2 — REST + facade escalation trigger

**Pre-condition:** Escalation Boundary FNIs park in `:waiting` (`EscalationBoundaryEvent`). Throws today go ESP → parent passthrough → `ChildLifecycle` / `BoundaryOrchestrator`. This workstream adds an **external** entry that only hits waiters in each scanned PI.

### Core

Add `EvilEngine.Execution.trigger_escalation/2` (`escalation_code`, optional `escalation_name`) that:

1. Enumerates running PI pids (`DynamicSupervisor.which_children` / existing helper used by stats).
2. `:gen_statem.call` each with `{:trigger_escalation, escalation_info}`.
3. Concatenates `{process_instance_id, flow_node_instance_id}` deliveries.

PI `running` handler (keep the module split: put matching in a small helper next to `BoundaryOrchestrator` / `EspScope` if `process_instance.ex` would grow):

1. `EspScope.resolve_escalation_catch` → `execute_esp_action` if `{:ok, action}`; record the ESP shell FNI id as a delivery.
2. For each waiting FNI whose flow node is an Escalation Boundary matching the code (reuse `EscalationResolver` on the host activity, same specificity as throw): invoke the **existing** boundary-catch orchestration (`handle_boundary_catch`) so interrupting vs non-interrupting host cancel stays identical to a real throw from inside that host.
3. Reply `{ :ok, deliveries }`. Empty list is success.

`EscalationRaised.throw_type`: add `:api_trigger` (wire camelCase `apiTrigger`). Emit once per successful catch fire (not once per HTTP call).

No payload cap on the trigger body (empty). Path code is a short string; reject blank / oversize (e.g. > 256 chars) with 422.

### API / HTTP / OpenAPI

`EvilEngine.Api.trigger_escalation(escalation_code, identity, opts)`:

- `Validation.check_claim(identity, "trigger_escalation", opts)`
- Delegate to `Execution.trigger_escalation/2`

`EscalationController.publish/2` mirrors `SignalController` (403, 500 rescue, camelCase body). 422 for blank code.

Router: authenticated scope, next to message/signal trigger.

OpenAPI: add the operation. Do **not** add `/process-instances/{id}/restart`.

### Facade / SDK / client

- `EngineFacade.Escalations` with `publish: (escalation_code -> publish_result())`, wired in `Loader` with `skip_claims: true`.
- TS `FacadeEscalations.publish(escalationCode)` on `EngineFacade`.
- `EventClient.triggerEscalation(code)` → `POST /escalations/${encodeURIComponent(code)}/trigger`.
- `EscalationTriggerResult` in `trigger.ts`; add to `TriggerResult` union.
- Client unit tests + error mapper (403 `forbidden` already mapped).
- `test-engine.ts` default admin claims: `trigger_escalation: true`.
- Mint-token Mix task default claims: add `trigger_escalation: true` next to message/signal.

### Tests

HTTP:

- 403 without claim; 200 with `trigger_escalation: true`; `zeeky_boogie_doog` bypass
- 422 blank code
- Unknown code, no waiters → 200 `{deliveries: [], pending: false}` (like a signal with no subscribers, but never `pending: true`)

Integration (reuse existing fixtures where possible):

- Waiting interrupting escalation boundary on a Call Activity / embedded subprocess host: trigger code → boundary path taken, host interrupted (same assertions as C95-style tests, but the throw is HTTP not BPMN).
- Non-interrupting boundary: host still running, parallel path started (C96 analogue).
- ESP escalation start: trigger code → ESP child spawned (`EventSubprocessTriggered` / `SubProcessChildStarted.isEventSubprocess`).
- Two running PIs with the same code: **both** receive (engine-wide, like signals).
- Specific code does not fire a different-code boundary; catch-all boundary **does** fire for a named trigger when no specific match exists in that candidate set (existing resolver law).

Conformance: one YAML spec is enough if integration covers the matrix; do not skip HTTP.

### Docs in this workstream

- `docs/architecture/api.md` §10.1 — implemented route; delete `POST /triggers/escalations` "specified" row
- `docs/architecture/authorization.md` §6.4 — claim enforced; route live
- `docs/architecture/security.md` — trigger claim is no longer vacuous
- `docs/guides/handbook/escalation-events.md` — new "Triggering from the API / debugger" section: inject into waiting catchers; does not replace a modeled throw; does not pending; does not escalate unmatched PIs
- `docs/guides/plugins/engine-facade.md` — `escalations.publish`
- `AGENTS.md` — REST table + facade bullet
- `docs/ImplementationPhases.md` Phase 3 item 6 — add escalation trigger as a follow-on shipped with this plan (keep historical DONE text; one sentence)
- `docs/ImplementationPlan.md` §0 — `ESC-API-D1`

- [ ] **2.1** Core inject + Api + controller + router + OpenAPI
- [ ] **2.2** Facade + TS SDK/client + mint-token/test-engine claims
- [ ] **2.3** HTTP + integration tests (DB running)
- [ ] **2.4** `mix compile --warnings-as-errors && mix credo --strict` + tests; SDK/client unit tests
- [ ] **2.5** API/auth/handbook/facade docs for the live route

---

## Workstream 3 — Drop dead documentation artefacts

Do this **after** WS1 so `timer_start_schedules` exists to point at, and **after** WS2 so escalation trigger docs are not describing a hole.

**Drop completely** (spec, ER, retention, event union, glossary):

- Table `escalations`
- Table `compensations`
- Table `engine_timers` (replaced by `timer_start_schedules` for Timer Start only)
- Table `pending_escalations` leftover mermaid in `docs/Schema.md` (already dropped in runtime; delete the diagram node)
- Route `POST /process-instances/{id}/restart`
- Auth row that treats Restart as a distinct command
- `Event.EngineAuditPurged.table` union members `:escalations | :compensations | :engine_timers`
- `publish_escalation/3` mentions in `PayloadCap` moduledoc and `docs/architecture/testing.md` CAP-PUBLISH that imply a walker + `escalations` row. PayloadCap is not used on this trigger (no payload). Update those sentences to the live waiter-delivery API.

**Keep:**

- Escalation **runtime** (handlers, `:escalated` PI state, `EscalationRaised` event)
- Compensation **runtime** (`compensation_registry`, events)
- `PUT /process-instances/{id}/retry`
- Claim `trigger_escalation` (now used)
- Phrase "retry/restart" in Phase 2 item 15 **only** as historical name of the retry feature — optional tidy: rename heading prose to "retry" where it would confuse

Files to sweep (search `escalations` / `compensations` / `engine_timers` / `/restart` / `POST /triggers/escalations`):

- `docs/architecture/data-model.md`
- `docs/architecture/configuration.md` (Pass B, partition tables, Studio debugger views)
- `docs/architecture/routing.md` (resume bullet `engine_timers WHERE state='armed'` → FNI `type_properties` + `timer_start_schedules` for cycle starts)
- `docs/architecture/event-system.md` (`engine:escalations` PubSub topic if it is a lie; kernel tables list)
- `docs/architecture/observability.md`
- `docs/architecture/testing.md`
- `docs/architecture/api.md` (restart row)
- `docs/architecture/authorization.md` (restart row)
- `docs/Schema.md`
- `docs/Glossary.md` (Engine-Level Audit Tables)
- `docs/ImplementationPlan.md` (§3.4, §4.3, §11.1 debugger trail, §14.6 six-table list)
- `docs/ImplementationPhases.md` Phase 1 item 14 deferred-audit list; Phase 7 item 4
- `docs/Architecture.md` if it still lists those tables
- `apps/peripheral_persistence/lib/evil_engine/persistence/release.ex`
- `apps/core_execution/lib/evil_engine/execution/payload_cap.ex` moduledoc
- `apps/core_types` `EngineAuditPurged` if the atom union is compiled

Add `docs/ImplementationPlan.md` §0 rows: **TIM-D1**, **DOC-D1** (drop audit tables), **API-D1** (no restart).

Phase 7 item 4 Pass B list becomes exactly the tables that exist: `messages`, `pending_messages`, `signals`, `pending_signals`. No "until they exist" hedges for dropped tables.

- [ ] **3.1** Repo-wide search and delete/replace the artefacts above
- [ ] **3.2** §0 decision rows
- [ ] **3.3** Spot-check: no remaining "specified, not migrated" for those three tables; no remaining restart route

---

## Workstream 4 — Studio debugger overlay

Repo: **Bifrost Forge World** (`BFW-Studio`).

Mirror `TriggerSignalEventLink` / `OverlayFactory` signal branch:

- Show overlay when the selected FNI is an **active** Escalation **Boundary** (catch), same `isCatchEvent && eventType === Escalation` pattern.
- Resolve escalation **code** (not only name) via existing `getEscalationCode`.
- Command: `engine.debugger.triggerEscalationEvent` → `ENGINE_COMMANDS.triggerEscalation` → `connection.client.events.triggerEscalation(escalationCode)`.
- Do **not** pass `processInstanceId` (engine-wide, like message/signal).

ESP start overlay: only if the debugger already treats ESP start FNIs as selectable catch events; do not invent a new selection model. HTTP trigger still fires ESP waiters engine-side even without an overlay.

Update Studio architecture docs only if overlay registration is documented (`docs/architecture/` per Studio rules).

Browser-verify: debugger on a running PI with a waiting escalation boundary; click trigger; boundary path runs. If the Studio app cannot be started in this environment, say so and rely on Engine integration tests.

- [ ] **4.1** Command contract + `registerEventCommands` + overlay + OverlayFactory
- [ ] **4.2** Studio `npm run build` / `lint:fix` / `format` in `studio/` (and SDK if the Studio package consumes local engine client)

---

## Verification

Before presenting completion:

1. Test DB one-liner + `MIX_ENV=test mix ecto.reset` (schema changed).
2. `mix compile --warnings-as-errors`
3. `mix credo --strict`
4. `mix test` (unit) + targeted integration files above + `MIX_ENV=test mix run test/integration_runner.exs` (or `mix quality` if time allows)
5. `pnpm` unit tests in `packages/js/sdk` and `packages/js/client`
6. OpenAPI vs `router.ex`: new escalation route present; restart absent
7. ripgrep: `engine_timers`, `POST /process-instances/.*/restart`, `compensations` table, `create table(:escalations` must not remain as live spec (historical D1 sentences about *dropping* `pending_escalations` may stay)

### Definition of Done

- Engine restart after deploying a cycle Timer Start still creates PIs without re-deploy.
- No docs or Phase 7 text treat `escalations` / `compensations` / `engine_timers` as upcoming tables.
- No restart REST route in docs or router.
- `POST /escalations/{code}/trigger` + `EventClient.triggerEscalation` + `facade.escalations.publish` work; Studio overlay calls the client.
- GraphQL unchanged (query-only).

---

## Execution note

`do exe` / Agent implementation of this file is approval of the locked resolutions above. If ESC-API-D1 should instead be FNI-scoped (`POST /escalation-events/{id}/trigger` like timers) or require `processInstanceId`, stop and amend before Workstream 2.

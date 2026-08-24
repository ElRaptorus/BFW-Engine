---
title: Post-review remediation (non-Phase-7)
date: 2026-08-24
status: PENDING APPROVAL
---

# Post-review remediation

> **For agentic workers:** Execute workstreams in order. Do **not** create git commits (repo policy: the developer commits). After each workstream that touches `.ex` / `.exs`, run the Engine verification pipeline from the project root (`mix compile --warnings-as-errors`, `mix credo --strict`, then the relevant tests). Start the PostgreSQL test container before any test command.

**Goal:** Close every architectural-review finding that is *not* already scheduled as Phase 7 work; bring the TypeScript SDK and client into full sync with the live Engine REST / GraphQL / WebSocket / plugin-facade surfaces; and correct the Phase 7 retention *plan* where it contradicts GraphQL-is-readonly and dropped pending-escalation tables.

**Architecture:** Docs and contracts first where the review found lies; then small runtime/API/plugin wiring that is already specified; then two contained scale/SoC fixes. Do not implement RetentionRunner, soak/chaos/load reporters, sidecar, Python/Node cookbooks, or clustering.

**Tech Stack:** Elixir/OTP umbrella, Ash/Phoenix, Ecto dual pool, TypeScript SDK/client, architecture docs under `docs/`.

## Global constraints

- Project name: **ThomasTheDaemonEngine** (never "Evil Engine" in new copy).
- No abbreviations in new identifiers.
- GraphQL is **strictly read-only**. Commands stay on REST (and the plugin facade).
- Sidecar host stays deferred (PLUG-D1).
- Do not implement Phase 7 items 1–8, 10–11 (load/soak/chaos/LZ4 gate/message back-pressure/zero-downtime/RetentionRunner/cookbook remainder/v1.0.0).
- Test DB: `(docker inspect --format='{{.State.Running}}' evil-engine-postgres-test 2>/dev/null | grep -q true) || (docker start evil-engine-postgres-test 2>/dev/null || bash scripts/create-test-db.sh) && docker exec evil-engine-postgres-test pg_isready -U evil_engine && MIX_ENV=test mix ecto.migrate`
- User commits; agents never `git commit` / `git push`.

---

## Design notes (review feedback, not Phase 7 work)

### Resume vs `EVIL_MAX_CONCURRENT_PIS`

The review called resume-bypassing-the-cap a hole. **It is not.** A PI tree must come back as a whole: parent Call Activity / SubProcess / Transaction / Ad-hoc shells plus children. Applying the cap mid-resume would leave a parent running and a child unresumed (or the reverse) — that is a corrupted tree, which is worse than temporary oversubscription.

What already exists is the right model:

1. Public `start_process_instance` is the only admission gate (`Execution.start_process_instance/1` soft pre-check).
2. `ResumeRunner` ignores the cap and brings every persisted `:running` PI back.
3. After boot, new starts hit the cap again. The oversubscribed set drains by natural completion.

**Do not** queue leftover PIs for “later resume.” **Do not** put `max_children` on the DynamicSupervisor (it would also block resume). **Do** document the trade-off (execution.md currently *lies*: it says `max_children` comes from the env var; `application.ex` hardcodes `:infinity`).

Optional, small, worth doing in Workstream D: if after resume `count_active() > configured_limit()`, publish `EngineOverloaded` so operators see the oversubscription instead of discovering it via 503s on the next start.

### One `:gen_statem` per PI

Keep it. The alternatives (shared worker pool, Camunda-style job poller, process-less DB tokens) throw away per-PI crash isolation, linked FNI Tasks, and the wait-mailbox model. Clustering (post-v1 Horde) still wants one process per PI, just relocated.

Not in this plan: `:hibernate` on long-wait PIs (user-task / message / timer parks). That is a later memory optimization, not a model change.

### Default pools: 100 write / 50 read

Current production defaults (`20` / `10`) are Ecto tutorial numbers. A 2:1 write:read ratio matches the dual-pool rationale in `docs/architecture/persistence.md`.

| Env | Write (`EVIL_DB_POOL_SIZE`) | Read (`EVIL_DB_READ_POOL_SIZE`) |
|-----|----------------------------:|--------------------------------:|
| Production default (`runtime.exs`) | **100** | **50** |
| `config/dev.exs` | keep 10 / 5 (local) | |
| `config/test.exs` | keep `schedulers_online() * 2` (Sandbox) | |

Postgres default `max_connections` is 100. **100 + 50 already exceeds that.** Docker compose and ops docs must set `max_connections ≥ 200` (150 pools + superuser reserve + healthchecks). Formula to document: `max_connections >= (write + read) * engine_nodes + 20`.

### PersistenceAdapter — **demoted this pass (user decision 2026-08-24)**

The stub (`persist(changeset, state)`) does **not** match `EvilEngine.Execution.Persistence` (20+ typed callbacks). Replacing AshPostgres is a second database engine, not a small remediation. **Do not implement** a facade PersistenceAdapter in this plan. Treat it like TimerSource: registration may remain, runtime ignores it, guides say **not in v1**. A later dedicated plan can choose observer-chain vs full `Execution.Persistence` replacement.

In-tree swap of the execution adapter via `:core_execution, :persistence_adapter` config stays as it is today (tests already use NoOp).

### TimerSource / MonitoringPanel / DataStoreAdapter

- **DataStoreAdapter:** DataStores are a v1 no-op. Demote to reserved / not wired. Do not implement.
- **TimerSource:** would replace ISO-8601 evaluation for custom timer dialects. Core timers already parse date/duration/cycle. Demote.
- **MonitoringPanel:** fragments for the empty `/admin/` HTML stub. Demote until there is a real admin UI.
- **PersistenceAdapter (plugin facade):** demote this pass (see decision above). Not the same as `EvilEngine.Execution.Persistence`.

Registration functions may remain (no-op + docs “not in v1”) so existing example compile does not break; guides must stop implying they run.

---

## Out of scope (Phase 7)

Do **not** implement in this plan:

1. Load-test JSON reporter, 10k rich workload, LZ4 vs PGLZ gate
2. Zero-downtime / hot-code-upgrade
3. Message-publish back-pressure
4. `RetentionRunner` GenServer, `Event.RetentionPurged`, partition-pruning soaks
5. Payload-cap chaos / 72h soak / SIGKILL resume suite
6. Python/Node Service Task cookbooks, SSE sink example, per-example CI
7. v1.0.0 release artefacts
8. Clustering
9. Full `process_instance.ex` god-module extraction beyond the two SoC items below

**Do** rewrite Phase 7 item 4 so purge is **REST + CLI**, not a GraphQL mutation, and drop `pending_escalations` from Pass B.

---

## File map

| Area | Primary files |
|------|----------------|
| Ad-hoc sandbox flake | `test/integration/adhoc_subprocess_test.exs`, `test/support/db_assertions.ex`, `test/support/execution_case.ex` (as needed) |
| GraphQL readonly + API docs | `docs/architecture/api.md`, `docs/guides/api/graphql-reference.md`, `docs/guides/getting-started/*.md`, `docs/guides/api/rest-reference.md` |
| Resume/cap docs | `docs/architecture/execution.md`, `docs/architecture/common-pitfalls.md`, `apps/core_execution/lib/evil_engine/execution/application.ex` (comment only unless Workstream D event) |
| Pools | `config/runtime.exs`, `docker-compose.yml`, `docs/architecture/persistence.md`, `docs/guides/operations/database.md`, `docs/architecture/configuration.md` |
| RestApiExtension | `apps/api_web/lib/evil_engine_web/http/router.ex`, new plug, `apps/peripheral_plugins/.../registry.ex`, example + tests |
| PersistenceAdapter demote | `apps/engine_sdk/lib/evil_engine/plugin/persistence_adapter.ex`, `docs/guides/plugins/persistence-adapter.md` |
| Facade gaps | `apps/engine_sdk/lib/evil_engine/engine_facade/processes.ex`, loader, new timer-schedules namespace or `EngineFacade.Timers` |
| TS client + SDK sync | `packages/js/client/src/rest/`, `packages/js/client/src/errors/error-mapper.ts`, `packages/js/sdk/src/errors/`, `packages/js/sdk/src/plugin/engine-facade.ts`, `packages/js/sdk/src/events/engine-events.ts`, `packages/js/sdk/src/types/enums.ts` |
| Stub demote | `docs/architecture/plugins.md`, `docs/guides/plugins/other-behaviours.md`, engine_sdk `@moduledoc`s, matching TS plugin handler JSDoc |
| Subscription index | `apps/core_events/lib/evil_engine/events/message_subscriptions.ex`, `signal_subscriptions.ex` |
| SoC | `apps/core_execution/lib/evil_engine/execution/process_instance.ex`, `process_instance/compensation_orchestrator.ex` |
| Retention plan only | `docs/ImplementationPhases.md` §Phase 7 item 4, `docs/architecture/api.md` purge section, `docs/Glossary.md` |
| Coverage ratchet | each `apps/*/mix.exs` `test_coverage.threshold`, `coveralls.json` — **after** quality is green |
| Auth / DatabaseSink leftovers | `docs/ImplementationPhases.md` Phase 2 §11, `docs/guides/api/authentication.md`, `ImplementationPlan.md` §16.4, `apps/peripheral_persistence/mix.exs` |

---

## Workstream 0 — Unblock `mix quality`

**Why:** One integration failure aborted conformance and coverage. Nothing else in this plan is trustworthy until this is green.

- [ ] Reproduce: start test DB, run `mix test test/integration/adhoc_subprocess_test.exs --only line:479` (or the named test). Confirm `DBConnection.OwnershipError` on `assert_pi_state!(parent_pi_id, "finished")` after `wait_for_process_instance/2`.
- [ ] Root cause: the FEEL completion path finishes the parent PI from an FNI Task / child PI that is **not** allowed on the sandbox. The test process then queries Ash after the owner has crashed or the checkout was never `allow`ed. Compare with the passing sibling `"trivial true completion condition completes immediately"` (same file, ~line 493).
- [ ] Fix in the **engine path** if a Task is querying the Repo without `Ecto.Adapters.SQL.Sandbox.allow/2` (or `caller:`). If the race is test-only, fix `wait_for_process_instance` / `assert_pi_state!` to retry on `OwnershipError` the same way `with_sandbox_retry/2` already retries other errors — **prefer allowing the writer process**, not swallowing the error.
- [ ] Re-run the whole describe `"FEEL completion condition (Gap 1)"` then `mix quality`. Must exit 0.

**Done when:** `mix quality` exits 0 on this workspace.

---

## Workstream A — Documentation truth-pass

GraphQL mutations were never a product ambition. Fix the record.

### A1. GraphQL is read-only

- [ ] `docs/architecture/api.md`: delete or rewrite §10.2.1 mutation/subscription listings (`startProcessInstance`, `finishUserTask`, live subscriptions). State explicitly: GraphQL is query-only; all commands are REST; real-time is Phoenix Channels. Payload-cap paragraphs that mention GraphQL mutations must talk about REST + facade only.
- [ ] Move `purgeProcessInstances` out of GraphQL: see Workstream G (Phase 7 plan). In `api.md` now, mark purge as **planned REST**, not a live GraphQL field.
- [ ] Confirm `docs/guides/api/graphql-reference.md` already says no mutations; add a one-line pointer from `api.md`.
- [ ] Grep `docs/` and `AGENTS.md` for `startProcessInstance(` (GraphQL), `subscription {`, `purgeProcessInstances` and fix stragglers.

### A2. Getting-started and handbook

- [ ] `docs/guides/getting-started/overview.md`: fix the dependency arrow (**Peripheral depends on Core; API depends on both; Core never depends on Peripheral**). Expand the element-support list to match `AGENTS.md` (Complex Gateway, MI, standard loops, ad-hoc, transaction, compensation, ESP, escalation, conditional). Remove “GraphQL subscriptions” from the capability list.
- [ ] `docs/guides/getting-started/concepts.md`: PI states must include `:error`, `:compensated`, `:escalated`, `:cancelled`. `evil:assignees` is a **FEEL** expression, not comma-separated. Drop or mark MonitoringPanel / TimerSource / DataStoreAdapter as not in v1.
- [ ] `docs/guides/handbook/user-tasks.md`: replace invalid assignees examples with FEEL (`["clerk_role", "manager_role"]` or `identity.groups`).
- [ ] `docs/guides/handbook/timer-events.md`: `PUT /timer-schedules/:id/enable` and `.../disable`, not `PUT /timer-schedules/:id`.
- [ ] `docs/guides/operations/troubleshooting.md`: result-contract mismatch on User Task is **HTTP 422, FNI stays waiting**, not FNI fatal.
- [ ] README handbook TOC: add ad-hoc, multi-instance, standard loops, transactions.

### A3. REST reference completeness

- [ ] `docs/guides/api/rest-reference.md`: document the live groups already in `router.ex` — decisions (full set), PI retry, timer-schedules, timer-events trigger, messages, signals, ad-hoc. Do not invent GraphQL writes. Point at OpenAPI for schemas.

### A4. Stale leftovers

- [ ] Auth: Phase 2 item 11 and `docs/guides/api/authentication.md` — **first-writer wins**, matching `ProviderRegistry` and `AGENTS.md`.
- [ ] Strip DatabaseSink / `EVIL_EVENT_SINK_DATABASE` as a live sink from `docs/ImplementationPlan.md` §16.4, `apps/peripheral_persistence/mix.exs`, and any “four sinks” lists. `GET /info` field `event_sink_database` may remain `false` if the key is still serialized; document it as residual / always false, or drop it in the same pass if cheap.
- [ ] `docs/architecture/execution.md` DynamicSupervisor paragraph: `max_children` is `:infinity`; the cap is a **soft pre-check on new starts**; **resume bypasses the cap by design** (tree consistency). Add a `common-pitfalls.md` entry.
- [ ] `docs/architecture/security.md` A10: the builtin `implementation="http"` Service Task **does** make outbound HTTP from deployed `evil:httpUrl`. SSRF is an operator-trust / plugin-trust issue, not “engine never dials out.”
- [ ] Phase 5 items 6–7 in `ImplementationPhases.md`: mark **DONE**; `{id}` is the **child process instance id**.
- [ ] `docs/architecture/index.md` / leftover “Evil Engine” titles: use ThomasTheDaemonEngine on newly edited headings only (no drive-by rename of the whole tree).

**Done when:** a grep for GraphQL `startProcessInstance` / “last one wins” / “DatabaseSink” as shipped finds no false claims.

---

## Workstream B — Pool defaults 100 / 50

- [ ] `config/runtime.exs`: `EVIL_DB_POOL_SIZE` default **100**, `EVIL_DB_READ_POOL_SIZE` default **50**. Leave `dev.exs` and `test.exs` unchanged.
- [ ] `docker-compose.yml` postgres: `command: postgres -c max_connections=200` (or equivalent `POSTGRES_*` if you add a mounted `postgresql.conf`). Engine service does not need to set the pool env vars if runtime defaults match.
- [ ] Docs: `docs/architecture/persistence.md`, `docs/architecture/configuration.md`, `docs/guides/operations/database.md`, `docs/guides/operations/backpressure.md`, `docs/architecture/security.md` (Ecto pool row). Include the `max_connections >= (write + read) * nodes + 20` formula.
- [ ] `scripts/create-test-db.sh` / test container: **do not** raise the test pool; Sandbox is per-test.

**Done when:** a boot with no pool env vars logs/configures 100/50; test suite still uses `test.exs` sizes.

---

## Workstream C — Plugin capabilities

### C1. Demote stubs

- [ ] Rewrite `@moduledoc` on `TimerSource`, `MonitoringPanel`, `DataStoreAdapter`, **and** `PersistenceAdapter` (plugin behaviour): **not implemented in v1**; registration is accepted and ignored at runtime (or returns `{:error, :not_implemented}` — pick one and use it everywhere; prefer **accepted + unused** to avoid breaking loaders that already call register).
- [ ] `docs/architecture/plugins.md` table, `docs/guides/plugins/other-behaviours.md`, `getting-started.md`, `docs/guides/plugins/persistence-adapter.md`: “Reserved / not in v1.” DataStores remain a parser no-op. Do not imply write-through or Postgres replacement.
- [ ] TypeScript stub types are demoted in Workstream D4 (same wording: accepted, unused, not in v1). Do not delete the TS interfaces — keep them so existing sketches compile.

### C2. RestApiExtension — actually mount

Specified in `docs/architecture/authorization.md` §7.2: JWT resolved, Identity passed, **no engine claim policy**.

- [ ] Add `EvilEngineWeb.Http.Plugs.PluginExtensionPlug` (name may vary; no abbreviations). At the **end** of the `:authenticated` scope in `router.ex`, `match :*, "/*path", PluginExtensionController, :dispatch` (or a plug that does not steal `/api`, `/admin`, `/health`).
- [ ] Dispatch: strip path, look up `Registry` by prefix (longest-prefix match). Reserved prefixes (`/processes`, `/decisions`, `/process-instances`, `/user-tasks`, `/timer-schedules`, `/timer-events`, `/messages`, `/signals`, `/adhoc-subprocesses`, `/stats`, `/api`, `/admin`) → 404 as today; **reject registration** of those prefixes at `register_rest_api_extension` time (`{:error, :reserved_prefix}`).
- [ ] Call the plugin router/controller with `conn` that already has `conn.assigns.identity` (or equivalent from `Auth.Plug`). Do not run `deploy_bpmn` etc.
- [ ] The behaviour today has `router_module/0` while the facade registers `(prefix, handler)`. **Canonical v1:** the registered `handler` is a Plug (`call/2`) or a Phoenix router. Align the behaviour with the facade; drop the unused callback or implement it as `def router_module, do: __MODULE__`.
- [ ] Tests: a test plugin registers `/echo-ext`, `GET /echo-ext/ping` with a valid JWT returns 200; missing JWT 401; prefix `/processes` registration conflicts; engine routes still win.
- [ ] Example: small in-tree plugin under `examples/plugins/lifecycle_and_api/` or new `examples/plugins/rest_api_extension/echo/`.
- [ ] Update `docs/guides/plugins/api-extension.md` — delete “stub / Phase 4.”
- [ ] OpenAPI: plugin routes are **not** in `spec.yaml` (unknown at spec-author time). Document that in the guide.

### C3. PersistenceAdapter — not this pass

Covered by C1. No runtime wrapper, no `after_persist`, no facade swap of `Execution.Persistence`.

**Done when:** a plugin can mount a JWT-gated extra route; TimerSource / MonitoringPanel / DataStoreAdapter / plugin PersistenceAdapter are documented as unused.

---

## Workstream D — Facade, TS SDK/client full sync, resume overload signal

Bring `@elraptorus/daemonengine_sdk` and `@elraptorus/daemonengine_client` into full sync with the live Engine. REST PI **reads** stay GraphQL-only (intentional). Dev-only routes (`GET /openapi`, GraphiQL, Swagger UI) stay omitted.

### D1. EngineFacade gaps (Elixir)

`EvilEngine.Api` already has `list_processes/1`, `undeploy_process/3`, `trigger_timer_event/3`. Wire them.

- [ ] `EngineFacade.Processes`: add `list` and `undeploy` (skip_claims, plugin identity), matching existing enable/disable style in `loader.ex` `build_processes_namespace/1`.
- [ ] Add `EngineFacade.Timers` (or extend an existing namespace): `trigger_event/1` → `Api.trigger_timer_event/3`. Timer-schedule list/enable/disable go through `StartEventManager` today (controller does not use Api). **Minimum:** trigger. **If cheap:** also wrap schedule list/enable/disable behind Api first so the facade does not call `core_timers` from the loader (dependency: plugins → api_facade, not core_timers). Prefer adding thin `EvilEngine.Api` functions for schedules if missing.
- [ ] Tests in `apps/peripheral_plugins/test/.../loader_test.exs` (or facade tests): list/undeploy/trigger_timer closures are not `noop`.

### D2. TypeScript REST client — timer schedules

- [ ] New `packages/js/client/src/rest/timer-schedule-client.ts`: `GET /timer-schedules`, `GET /timer-schedules/:id`, `PUT .../enable`, `PUT .../disable`. Export from `index.ts` and `DaemonEngineClient`.
- [ ] SDK type `TimerSchedule` (or equivalent) for the JSON shape the controller returns. Barrel-export from `packages/js/sdk/src/index.ts`.
- [ ] Unit tests in client `test/unit`. Do not run live integration unless an engine is up.

### D3. Resume oversubscription observability

- [ ] After `ResumeRunner.resume_all/0`, if a finite cap is configured and `count_active() > limit`, publish `%Event.EngineOverloaded{...}` (same shape as the poller). Do not refuse remaining resumes.
- [ ] Document in execution.md next to the cap bypass.

### D4. TypeScript SDK ↔ Engine full sync

The original review caught timer-schedules and four error codes. A second pass found the rest of this list. All of it belongs in this plan (not Phase 7).

#### D4a. `EngineFacade` TypeScript contract = Elixir `EngineFacade`

File: `packages/js/sdk/src/plugin/engine-facade.ts` (export via `plugin/index.ts` and `sdk/src/index.ts`).

Today the TS interface is missing namespaces and methods that Elixir already has or that D1 adds.

- [ ] Add `FacadeDecisions` mirroring `apps/engine_sdk/lib/evil_engine/engine_facade/decisions.ex`: `list`, `get`, `getLatestVersion`, `validate`, `deploy`, `evaluate`, `evaluateByVersion`, `evaluateService`, `getVersions`, `getXml`, `enable`, `disable`, `deleteVersion`, `undeploy`. Add `decisions: FacadeDecisions` on `EngineFacade`.
- [ ] `FacadeProcesses`: add `list` and `undeploy` to match D1.
- [ ] Add `FacadeTimers` (or a `triggerTimer` on a timers namespace) matching D1’s `trigger_event`. If D1 also wraps schedule list/enable/disable, add those methods here too.
- [ ] Rewrite the module comment. Delete “the facade is fully implemented” and “gRPC sidecar contract will be a 1:1 projection.” State: this interface mirrors the **in-BEAM** Elixir `EngineFacade`; sidecar host is deferred (PLUG-D1); stub capabilities are accepted and unused (see D4c).

#### D4b. Error mapper completeness

Every `error` string the HTTP layer actually emits must have an `error-mapper.ts` `case`. Status fallbacks must cover 400 and 409 (today only 401 / 403 / 404 / 422 / 500 / 503).

**Dedicated SDK classes** (same pattern as the transaction retry twins — `instanceof` must work):

| Engine `error` | HTTP | New / existing class |
|----------------|------|----------------------|
| `retry_checkpoint_inside_adhoc_subprocess` | 422 | new, twin of `RetryCheckpointInsideTransactionError` |
| `retry_inside_adhoc_subprocess` | 422 | new, twin of `RetryInsideTransactionScopeError` (today wrongly mapped to generic `ValidationError`) |
| `not_a_timer_event` | 422 | new |
| `dispatch_failed` | 500 | new (still also 500-fallback to `InternalEngineError` when the body has no code) |
| `conflict` | 409 | new `ConflictError` (timer not triggerable, and any other 409) |
| `bad_request` | 400 | new `BadRequestError` |
| `no_matching_condition` | 422 | new, or explicit `ValidationError` mapping — **prefer dedicated** so callers can branch |
| `no_decisions` | 422 | same rule as `no_matching_condition` |

- [ ] Add the classes under `packages/js/sdk/src/errors/`, export from `errors/index.ts` and `sdk/src/index.ts`.
- [ ] Wire every row in `packages/js/client/src/errors/error-mapper.ts` `mapByErrorCode`.
- [ ] `mapByStatusCode`: **400** → `BadRequestError`; **409** → `ConflictError`. Leave 422 → `ValidationError` as the generic fallback for unmapped 422 codes.
- [ ] Keep existing ad-hoc mappings (`not_adhoc_subprocess`, `adhoc_activity_not_found`, `adhoc_already_completing`, `adhoc_sequential_busy`, `adhoc_not_active`) as they are unless a dedicated class already exists.
- [ ] Unit tests in `packages/js/client/test/unit/error-mapper.test.ts` and `packages/js/sdk/test/unit/errors.test.ts` for each new class + the 400/409 fallbacks.
- [ ] Do **not** invent classes for codes the engine does not emit. `metrics_disabled` is 404 and `EngineClient.metrics()` already treats 404 as `null`.

#### D4c. Stub plugin capabilities in the SDK (match Workstream C)

Keep the types so sketches compile. Mark them unused.

- [ ] JSDoc on `TimerSourceHandler`, `MonitoringPanelHandler`, `DataStoreAdapterHandler`, `PersistenceAdapterHandler`: **not implemented in v1**; `register*` is accepted and ignored (same policy as C1).
- [ ] `PluginCapabilityType` enum may keep the values (introspection `/stats` can still list a registration). Comments must say reserved / not in v1.
- [ ] `docs/guides/plugins/*` already updated in C1; SDK README plugin section must not imply these handlers run.

#### D4d. Unpublished event types

- [ ] `TimerArmed` and `TimerCancelled` in `packages/js/sdk/src/events/engine-events.ts`: JSDoc **reserved — the engine classifies these for dispatch but does not currently publish them**. Keep them in the `EngineEvent` union so adding publish later is non-breaking.
- [ ] Do not remove them from the barrel export.

**Done when:** plugins can list/undeploy/trigger timers; TS client covers timer-schedules; TS `EngineFacade` has `decisions` + D1 methods; every live REST error code in the table above has a dedicated class and mapper case; 400/409 have status fallbacks; stub capabilities and unpublished timer events are labelled; SDK + client unit tests green; over-cap resume is visible on the event bus.

---

## Workstream E — Subscription unregister by process instance

Today `unregister_all_for_process_instance/1` does `:ets.tab2list/1` in `message_subscriptions.ex` and `signal_subscriptions.ex`.

- [ ] Add a bag (or set) index table `{process_instance_id, key}` written on register, deleted on unregister.
- [ ] `unregister_all_for_process_instance/1` iterates the index only.
- [ ] Existing register/lookup/pending-drain tests plus a unit test that unregister of one PI does not scan unrelated keys (assert index size / or that a second PI’s subscription remains).

**Done when:** mass PI finish is O(subscriptions of that PI), not O(all subscriptions).

---

## Workstream F — PI / FNI SoC (contained)

Do **not** split all 4,635 lines. Two leaks from the review:

### F1. `finish_async` is Service-Task-only (keep the capability check)

Catch events, timers, joins, Call Activity, etc. **do** park in `:waiting` via `{:async, id, continuation}`. That is expected. `handle_fni_async/3` stamps `async: true` on **every** such park, so the flag means “async return shape,” not “a plugin may call `finish_async_service_task`.”

`validate_async_waiting_entry/1` gates **only** the plugin-callback API (`finish_async_service_task` / `fail_async_service_task`). Only `ServiceTask` implements `handle_complete/4` for that path. **Do not** replace the `:service_task` check with the `async` flag — a waiting Message Catch already has `async: true` and would then crash in `complete_waiting_fni`.

- [ ] Keep a Service-Task capability check. Rename/comment it so it reads as “this API is Service-Task-only,” not “waiting is Service-Task-only.” Optional: introduce a distinct `plugin_callback` marker later; **not required** this pass.
- [ ] File: `apps/core_execution/lib/evil_engine/execution/process_instance.ex` around `validate_async_waiting_entry/1`. Add a comment. No behaviour change unless a test is missing that `finish_async` on a catch event returns `{:error, :fni_not_service_task}`.

### F2. Compensation runtime out of the PI

- [ ] Move spawn/persist/advance currently in `process_instance.ex` (`start_compensation_run`, `dispatch_compensation_handler_fni`, …) into `process_instance/compensation_orchestrator.ex` (today 82 lines, plan-only). The PI keeps `:gen_statem` casts and `execute_*` thin wrappers (same pattern as `execute_esp_action/2`).
- [ ] No behaviour change. Existing compensation integration/conformance tests must pass.

JoinOrchestrator / MiIterationOrchestrator / AdHocMode FEEL move: **not this plan**.

**Done when:** `validate_async_waiting_entry` still rejects non-service-task FNIs (commented as a plugin-callback gate); compensation runtime lives in `CompensationOrchestrator`; compensation tests green.

---

## Workstream G — Phase 7 retention **plan** (no implementation)

User: RetentionRunner is Phase 7; only fix the plan if it is incomplete or faulty.

Faults to fix **in docs only**:

- [ ] `docs/ImplementationPhases.md` item 4: **purge is REST** (`POST` or `DELETE` under process-instances, claim `purge_audit_data`) plus CLI hitting REST. **Not** `purgeProcessInstances` GraphQL.
- [ ] Pass B table list: remove `pending_escalations` (escalation D1 dropped the pending cache). Keep messages/signals pending tables that actually exist.
- [ ] `docs/architecture/api.md` / `docs/Glossary.md`: stop describing a live GraphQL purge field; describe planned REST.
- [ ] `apps/peripheral_persistence/mix.exs` and `persistence.ex` moduledoc: do not claim RetentionRunner ships today.
- [ ] Leave the GenServer, events, and tests to Phase 7 execute.

**Done when:** Phase 7 item 4 is implementable without contradicting GraphQL-readonly or inventing `pending_escalations`.

---

## Workstream H — Coverage ratchet (after quality is green)

Phase 0 floors are still in several `mix.exs` files. After Workstream 0:

- [ ] Read the `mix quality` / coveralls report.
- [ ] Raise each app’s `test_coverage.threshold` to **min(current observed − 1%, phase target)** so CI cannot slip, without requiring 90% overnight if the observed number is 82%.
- [ ] Global `coveralls.json` `minimum_coverage`: keep **80** unless the report is already ≥85; the ≥85 floor stays a Phase 7 / v1.0 gate.
- [ ] Apps at 0 with real code (`api_web`, `core_timers`, `peripheral_persistence`, `api_facade`): set a floor from the report (at least 50 if coverage is high; do not set 0 if the app has tests).

**Done when:** thresholds match post-Phase-5 reality and `mix quality` still passes.

---

## Verification

After all workstreams:

1. Test DB one-liner
2. `mix quality` (must exit 0)
3. `cd packages/js/sdk && pnpm run build && pnpm exec vitest run test/unit`
4. `cd packages/js/client && pnpm run build && pnpm exec vitest run test/unit`
5. Architecture docs touched in this plan still listed in `docs/architecture/index.md`

---

## Execution order

0 → A (docs can parallelize with 0 after the flake is understood) → B → C (RestApiExtension only; other capabilities demoted) → D (Elixir facade + TS full sync; D4 after D1 so TS types match wired closures) → E → F → G (can run anytime) → H last.

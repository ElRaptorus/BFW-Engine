---
title: Phase 7 LZ4 / payload-cap / resume-crash test scenarios
date: 2026-09-06
status: PENDING APPROVAL
---

# Phase 7 LZ4, payload-cap, and resume-crash test scenarios

> **For agentic workers:** Execute this plan task-by-task in the Engine repo. Do not git commit. After Engine code changes, start the test DB one-liner then run `mix quality`. Load/hardening tests are opt-in (`mix test.load.hardening`) and are **not** part of `mix quality`.

**Goal:** Close ImplementationPhases.md Phase 7 items 4, 5, and 7 with tests that match the written assertions, without putting multi-hour work into `mix quality` or GitHub `load-bench.yml`.

**Architecture:** Split into two layers. Layer A is small-N correctness (CAP-\* / SHAPE-\* / RESUME-\*) that runs under `mix quality`. Layer B is opt-in load/chaos (`@tag :hardening`, new `mix test.load.hardening`) that measures LZ4 vs PGLZ, drives a 5 % oversize mix, and crash-kills PI supervisors then resumes. Reuse `LoadHelpers`, `BenchmarkReporter`, `ExecutionCase`, and existing fixtures; do not change E8/E10–E12.

**Tech Stack:** ExUnit, `EvilEngine.ExecutionCase`, Ecto/`[:evil_engine, :db, :query]` telemetry, Postgres `ALTER … SET COMPRESSION`, HTTP REST + GraphQL via `ExecutionCase` helpers.

## Global Constraints

- Project name is ThomasTheDaemonEngine; env vars are `TDE_*` (CFG-D1). Do not reintroduce `EVIL_`.
- Load tests use a real pool: `TDE_LOAD_TEST_POOL=1` must be set **before** Mix loads `config/test.exs` (P89).
- Test DB: `evil-engine-postgres-test` on port 5543; start it before any DB-touching command.
- Do not put `@tag :hardening` tests into `mix quality`, `mix test.full`, or `.github/workflows/load-bench.yml`.
- Do not mutate E8/E9/E10–E12 workload ids or ceilings.
- Do not auto-edit `config/runtime.exs` to flip `TDE_JSONB_COMPRESSION` from a test. The 10 % gate fails the hardening suite; a human flips the default after reading the report.
- JSONB compression is applied at **migrate** time (`CreateInitialSchema.jsonb_compression/0`). Changing the env var on a running test DB does nothing until columns are `ALTER`ed and rewritten.
- In-process crash analog is `LoadHelpers.terminate_all_process_instances/0` (DynamicSupervisor kill), then `ResumeRunner.resume_all/0`. Same pattern as `test/integration/execution/resume_test.exs`. Do not Docker-kill the engine container from ExUnit.
- BPMN fixtures must include DI, `evil:version`, and a default pool/lane (`AGENTS.md`).
- Git commits are created by the developer, never by the agent.

## Locked design (no further product input required)

| Topic | Choice | Why |
|---|---|---|
| Suite split | Layer A in `mix quality`; Layer B `@tag :hardening` excluded from `mix test.load` by default | E8 already ~3–10 min; 2×10k + 10 min chaos would blow GH `load-bench` (120 min) |
| 10k dual compression run | Default `TDE_LOAD_COMPRESSION_COUNT=10000`; override to `1000` while iterating | Spec asks for the Phase 6 10k mixed fixture; env keeps local iteration cheap |
| 5-level Call Activity | New fixture chain; **100 trees** in Layer B crash/compression extra shape, not 10k | 10k five-deep trees = 50k PIs; E12 already covers 1-level CA at 10k |
| Oversize chaos duration | Default 600 s via `TDE_LOAD_CHAOS_SECONDS`; smoke `30` | Spec says 10 minutes; env avoids a 10-minute inner loop on every local tweak |
| LZ4 vs PGLZ | Same VM: run lz4, `ALTER SET COMPRESSION pglz` + rewrite, run again | `TDE_JSONB_COMPRESSION` only affects new migrations; no second cluster |
| 10 % gate | Fail the hardening test if any named p50/p95 is >10 % slower on LZ4 than PGLZ | Spec’s “flip default before release” stays a human follow-up |
| Crash | Kill PI children, leave BEAM + Postgres up, resume | Matches existing resume integration; true OS SIGKILL is out of ExUnit’s reach |

## What already exists (do not rebuild)

| Spec fragment | Current coverage |
|---|---|
| Item 4 “Phase 6 load test 10k mixed” | `test/load/execution_load_test.exs` E8 (`exec_10000_mixed_standard`) — **1-level** Call Activity, not 5-level |
| Large payloads | E9: 1k linear at 1 / 16 / ~64 KiB |
| Resume throughput | `test/load/resume_load_test.exs` L1–L8 — seeds waiting FNIs; does **not** assert `input_token` round-trip |
| GraphQL under load | `test/load/pool_pressure_test.exs` — queries omit `inputToken` / `outputToken` |
| CAP-PI-START-CONTEXT | `test/integration/start_endpoint_test.exs` “B7” HTTP 413 |
| CAP-TRIGGER-MSG | `test/integration/execution/message_events_test.exs` HTTP 413 |
| CAP-WRITE-RESULT (NoOp adapter) | `apps/core_execution/test/evil_engine/execution/payload_cap_enforcement_test.exs` |
| CAP-WRITE-DO (unit) | `apps/core_execution/test/evil_engine/execution/data_object_writer_test.exs` |
| Resume User Task | `test/integration/execution/resume_test.exs` I1 — does **not** assert `input_token` equality |
| Resume mid-join 2/3 | `test/integration/execution/parallel_gateway_test.exs` 11a |
| Ash-level no `active_tokens` / no `final_token` | `apps/peripheral_persistence/test/evil_engine/persistence_test.exs` — **not** `information_schema` |
| DB query telemetry | `[:evil_engine, :db, :query]` with `measurements.query_time_ms` and `metadata.source` |

**Gaps this plan fills:** persisted CAP-\* matrix (write_result / DOA / publish / finish / exactly-at-limit / configurable min), SQL-level SHAPE-\* including `attcompression`, `input_token` resume assertion, 5-level CA fixture, LZ4 vs PGLZ measurement + 10 % gate, 5 % oversize chaos under load, scaled crash+resume with join + nested CA.

## File map

| File | Role |
|---|---|
| `test/support/payload_cap_fixtures.ex` | `mint_payload/1`, `oversize_payload/0`, canonical JSON byte size helper |
| `test/integration/execution/payload_cap_boundaries_test.exs` | Layer A CAP-\* with real persistence |
| `apps/peripheral_persistence/test/evil_engine/persistence/schema_shape_test.exs` | Layer A SHAPE-\* against `information_schema` / `pg_attribute` |
| `test/integration/execution/resume_test.exs` | Add `input_token` equality on I1 |
| `config/runtime.exs` | Refuse boot when `TDE_TOKEN_MAX_BYTES < 1024` instead of silent `max/2` clamp |
| `test/fixtures/bpmns/call_activity_depth_5_*.bpmn` | Five-process Call Activity chain; leaf parks on a User Task |
| `test/fixtures/bpmns/cap_script_oversize.bpmn` | Script Task that can return an oversize result (or use existing script + plugin) |
| `test/fixtures/bpmns/cap_doa_oversize.bpmn` | Service/script with `dataOutputAssociation` to `order_payload` |
| `test/fixtures/bpmns/cap_send_oversize.bpmn` | Send Task / throw that publishes a message |
| `test/support/load_helpers.ex` | Per-source query-time collector; JSONB ALTER+rewrite helper |
| `test/load/jsonb_compression_load_test.exs` | Item 4 |
| `test/load/payload_cap_chaos_load_test.exs` | Item 5 under load |
| `test/load/resume_crash_load_test.exs` | Item 7 at scale |
| `test/load_runner.exs` + `mix.exs` | `TDE_LOAD_HARDENING` + `mix test.load.hardening` |
| `docs/architecture/testing.md` §12.4.6–12.5 | Record aliases, tags, workload ids, gate rule |
| `docs/ImplementationPhases.md` items 4, 5, 7 | Mark DONE with pointers when work lands |
| `docs/guides/operations/database.md` | Operator table for LZ4 vs PGLZ (empty until first hardening run) |

---

### Task 1: Shared payload helpers + boot-time minimum

**Files:**
- Create: `test/support/payload_cap_fixtures.ex`
- Modify: `config/runtime.exs` (token_max_bytes assignment)
- Modify: `apps/core_execution/lib/evil_engine/execution/application.ex` **only if** boot check belongs in the OTP app rather than Mix config (prefer `runtime.exs` raise — it already raises on missing JWT)

**Interfaces:**
- Produces: `EvilEngine.Test.PayloadCapFixtures.mint_payload/1` → `map()`, `oversize_payload/0` → `map()`, `json_byte_size/1` → `non_neg_integer()`
- `mint_payload(n)` must produce a map whose `Jason.encode!/1` byte size is **exactly** `n` (pad a `"blob"` string; adjust for JSON quotes). Cap tests are meaningless if size is approximate.

- [ ] **Step 1: Add helpers**

```elixir
defmodule EvilEngine.Test.PayloadCapFixtures do
  @default_limit 65_536

  def json_byte_size(term), do: byte_size(Jason.encode!(term))

  def mint_payload(target_bytes) when is_integer(target_bytes) and target_bytes > 16 do
    # Build %{"blob" => padding} then shrink/grow padding until encode size == target.
    # Fail with a clear raise if the target is too small for the envelope.
  end

  def oversize_payload, do: mint_payload(@default_limit + 1)
  def exactly_at_limit_payload, do: mint_payload(@default_limit)
end
```

- [ ] **Step 2: Unit-check the helper** in `apps/core_execution/test/evil_engine/execution/payload_cap_test.exs` (or a tiny test next to the helper): `json_byte_size(mint_payload(1024)) == 1024`, same for `65536` and `65537`.

- [ ] **Step 3: Replace silent clamp in `runtime.exs`**

Today:

```elixir
token_max_bytes: max(Env.get_int("TDE_TOKEN_MAX_BYTES", 65_536), 1024),
```

Required (testing.md CAP-CONFIGURABLE): if the env is set and `< 1024`, **raise** with `minimum_required: 1024` in the message. If unset, keep default `65_536`. Do not clamp `512` up to `1024`.

- [ ] **Step 4: Prove the raise** with a small Mix env test or a documented `runtime.exs` parse test. If a dedicated boot test is too heavy, an `EvilEngine.Config.Env` wrapper is overkill — a one-function `EvilEngine.Config.TokenMaxBytes.parse/1` in `config/runtime.exs`’s existing `Env` module (or a tiny `apps/core_execution` function called from runtime) is enough. Prefer extracting `parse_token_max_bytes/1` so unit tests can call it without booting Phoenix.

```elixir
def parse_token_max_bytes(raw, default \\ 65_536) do
  # nil/"" → default
  # integer < 1024 → raise with minimum_required: 1024
  # else → integer
end
```

- [ ] **Step 5: Run** `mix test apps/core_execution/test/evil_engine/execution/payload_cap_test.exs` (plus the parse test). Expected: pass.

---

### Task 2: Layer A — CAP-\* integration with real persistence

**Files:**
- Create: `test/integration/execution/payload_cap_boundaries_test.exs`
- Create fixtures under `test/fixtures/bpmns/`:
  - `cap_doa_oversize.bpmn` — Service Task `implementation="echo"` (or script) with `dataOutputAssociation` → Data Object `order_payload` (include DataObject + DataObjectReference + DI)
  - `cap_send_oversize.bpmn` — Send Task or Message Intermediate Throw with a global `bpmn:message`; oversize comes from the **start payload / mapping**, not from a REST trigger (REST trigger is already covered)
- Reuse: `user_task_simple.bpmn`, `linear_start_end.bpmn`, existing message-start fixture from `message_events_test.exs`

**Interfaces:**
- Consumes: `PayloadCapFixtures`
- Uses: `http_deploy`, `http_start`, `http_finish_user_task`, `http_trigger_message`, `wait_for_process_instance`, Ash reads on `FlowNodeInstance` / `ProcessInstance` / `Message`

Assertions (from `docs/architecture/testing.md` §12.4.6). Field atoms must match **code**, not the stale spec wording:

| Scenario | Actual field atom today |
|---|---|
| FNI output | `:fni_output` (`fni_lifecycle.ex`) |
| DOA | `:data_object_value` (`data_object_writer.ex`) — spec text says `:data_object`; **do not rename** unless a separate task; assert `:data_object_value` and add `data_object_id` in details if missing is cheap — only add `data_object_id` if it is a one-line `Map.put` in `check_payload_cap/1` |
| Start / REST payload | `:payload` (plug) / `:start_payload` (PI init) |
| User Task finish | `:result` or `"result"` depending on plug field |

- [ ] **Step 1: CAP-WRITE-RESULT (persisted)** — Script/Service Task completes with `oversize_payload()`. Assert facade/PI path: FNI `state == "fatal"`, PI `state == "fatal"`, no downstream FNI row, no dedicated `PayloadTooLarge` engine event (scan collector). Prefer the existing echo/async plugin + `finish_async` with an oversize map if that is shorter than a new Script Task fixture.

- [ ] **Step 2: CAP-WRITE-DO** — Complete the DOA activity with oversize `outputs.order_payload`. Assert: zero `data_objects` / `data_object_writes` rows for that PI; no `Event.DataObjectWritten` on the collector; FNI fatal. Contract validation (if any) runs **before** cap — keep the fixture contract-free so the cap is the failing check.

- [ ] **Step 3: CAP-PUBLISH-MSG** — Throw/Send with oversize payload. Assert: `SELECT count(*) FROM messages` unchanged; FNI fatal. Do **not** call REST trigger here (already in `message_events_test.exs`).

- [ ] **Step 4: CAP-TASK-FINISH** — Start `UserTaskSimple`, `PUT` finish with `oversize_payload()` as `result`. Assert HTTP **413**; FNI still `waiting` (or `active` if that is what the park state is — match `poll_fni_state`); PI still `running`.

- [ ] **Step 5: CAP-EXACTLY-AT-LIMIT** — Repeat write_result, DOA, publish, start, trigger, finish with `mint_payload(65536)`. All succeed. Then one `mint_payload(65537)` on a **new** call still 413/fatal. Cap is per-call, not sticky.

- [ ] **Step 6: CAP-PI-START / CAP-TRIGGER** — Do **not** duplicate B7 / message_events 413 tests. Add a one-line comment in the new file pointing at those tests so the matrix is discoverable.

- [ ] **Step 7: CAP-CONFIGURABLE (Application env, not a second BEAM)** — `Application.put_env(:core_execution, :token_max_bytes, 131_072)` in a tagged test, mint 65537 (must succeed) and 131073 (must fail), restore env in `on_exit`. The `< 1024` boot raise is Task 1’s unit test, not this file.

- [ ] **Step 8: Run** (after test DB one-liner):

```bash
mix test test/integration/execution/payload_cap_boundaries_test.exs
```

Expected: pass. Then `mix quality` at the end of Layer A (after Task 3), not after every fixture tweak.

---

### Task 3: Layer A — SQL SHAPE-\* and resume `input_token`

**Files:**
- Create: `apps/peripheral_persistence/test/evil_engine/persistence/schema_shape_test.exs`
- Modify: `test/integration/execution/resume_test.exs` I1
- Reuse: `parallel_gateway_test.exs` 11a already covers RESUME-GATEWAY-PENDING — add a comment in `resume_test.exs` pointing at it (item 7(b) at integration scale)

- [ ] **Step 1: SHAPE-NO-FINAL-TOKEN-COLUMN / SHAPE-NO-ACTIVE-TOKENS-TABLE** via SQL:

```sql
SELECT column_name FROM information_schema.columns
 WHERE table_name = 'process_instances' AND column_name = 'final_token';
-- assert empty

SELECT table_name FROM information_schema.tables
 WHERE table_schema = 'public' AND table_name = 'active_tokens';
-- assert empty
```

Use `Repo.query!`. Keep the existing Ash-level guards in `persistence_test.exs`.

- [ ] **Step 2: SHAPE-GATEWAY-PENDING-EXISTS** — `information_schema.columns` for `gateway_pending_arrivals` includes `arrived_payload`, `source_branch_sequence_flow_id`, `gateway_flow_node_instance_id`. Unique index name `gateway_pending_arrivals_unique_branch_arrival_index` already asserted in Ash tests.

- [ ] **Step 3: SHAPE-LZ4-APPLIED** — query `pg_attribute.attcompression` for every pair in `CreateInitialSchema`’s `@lz4_columns` and `@lz4_columns_partitioned`. Empty tables still report the column compression setting. Default test DB is `lz4`. Do not fail if an operator ran migrate with `TDE_JSONB_COMPRESSION=pglz`; assert the value equals `Application.get_env(:peripheral_persistence, :retention, [])[:jsonb_compression] || "lz4"`.

- [ ] **Step 4: I1 `input_token` round-trip** — before `terminate_process_instance`, read `ut_fni.input_token` from Ash. After `ResumeRunner.resume_all()`, reload the same FNI id. Assert maps equal. This is item 7(a) at N=1.

- [ ] **Step 5: Run** `mix test apps/peripheral_persistence/test/evil_engine/persistence/schema_shape_test.exs test/integration/execution/resume_test.exs`. Then full `mix quality` (test DB one-liner first).

---

### Task 4: Five-level Call Activity fixture

**Files:**
- Create: `test/fixtures/bpmns/call_activity_depth_5_leaf.bpmn` (process id `CallActivityDepth5Leaf`) — Start → User Task → End
- Create: `call_activity_depth_5_l4.bpmn` … `call_activity_depth_5_l1.bpmn` — each is Start → Call Activity (`calledElement` = next id) → End
- Root process id: `CallActivityDepth5`

Five files (not one XML with five processes) matches how `call_activity_basic.bpmn` + `call_activity_child.bpmn` are deployed today (`http_deploy` both). Deploy order: leaf first, then l4 → l1.

- [ ] **Step 1: Write BPMN** with DI, `evil:version`, collaboration + `Lane_default`. User Task on the **leaf** so crash tests can park the whole tree.

- [ ] **Step 2: Smoke** a single integration test in `test/integration/execution/call_activity_resume_test.exs` (or a 20-line addition): deploy five files, start root, wait for a waiting user task on the **leaf child PI**, finish it, assert root `finished`. `CompletionCounter`-style counting is load-only; here use `wait_for_process_instance` on the root id.

- [ ] **Step 3: Run** that one test. Expected: pass.

---

### Task 5: LoadHelpers — per-source latency + JSONB rewrite

**Files:**
- Modify: `test/support/load_helpers.ex`
- Modify: `test/support/load_helpers` tests if any (`test/load/benchmark_reporter_test.exs` is the reporter; add `test/load/load_helpers_compression_test.exs` only if rewrite SQL needs a lock — optional)

**Interfaces:**
- Produces:
  - `start_source_query_collector/0` → handle
  - `source_latencies_ms/2` — `(handle, source_table)` → `%{p50: float, p95: float, count: non_neg_integer}` from `measurements.query_time_ms` where `metadata.source == source_table`
  - `stop_source_query_collector/1`
  - `set_jsonb_compression!/1` — `"lz4"` \| `"pglz"`: `ALTER TABLE … ALTER COLUMN … SET COMPRESSION …` for the same column lists as the migration, then `UPDATE table SET col = col` for each JSONB column so TOAST rewrites
  - `jsonb_payload_bytes/0` — `SUM(pg_column_size(col))` over those columns (storage KPI)

Attach to `[:evil_engine, :db, :query]` (already has `source` and `query_time_ms`). Detach in `on_exit` (P88).

Column list: copy from `CreateInitialSchema` `@lz4_columns` + `@lz4_columns_partitioned`. Do not query partitioned parent only — `UPDATE` the parent table name Postgres uses for writes (`messages`, `data_object_writes`, etc.).

- [ ] **Step 1: Implement collector + ALTER helper.**
- [ ] **Step 2: Manual check** in `iex -S mix` is unnecessary; a 10-row seed in an existing persistence test that calls `set_jsonb_compression!("pglz")` then asserts `attcompression` is enough, then restore `lz4` in `on_exit`. Put that restore assertion in `schema_shape_test.exs` **or** keep ALTER exclusive to Layer B so `mix quality` never flips compression mid-suite. **Lock: ALTER only in Layer B files.** Quality tests must leave the DB at migrate-default lz4.

---

### Task 6: Item 4 — LZ4 vs PGLZ load gate

**Files:**
- Create: `test/load/jsonb_compression_load_test.exs`
- Modify: `test/load_runner.exs`, `mix.exs` (aliases) — can land in Task 8 with the other hardening files; if this file is added first, tag `@tag :hardening` so default `mix test.load` excludes it **before** the alias exists (runner must exclude `:hardening` the same way it excludes `:durability`)

**Workload:** Reuse E8’s four shapes (linear, parallel gateway, MI script, Call Activity basic) + E9-style `~60_000` byte start payload on the linear slice so JSONB is not tiny. Count = `String.to_integer(System.get_env("TDE_LOAD_COMPRESSION_COUNT") || "10000")`. Also deploy Task 4’s five-deep chain and start `min(100, count)` roots (`roots_only: true`) so 5-level is present without 50k PIs.

**Metric mapping (spec → collector):**

| Spec operation | How to measure |
|---|---|
| `write_result` | `query_time_ms` where `source == "flow_node_instances"` (updates of `output_token` / `input_token`) |
| DOA writes | `source == "data_object_writes"` (and `data_objects` if both fire) |
| `publish_message` | `source == "messages"` |
| FNI `input_token` reads during resume | After the execution wave: `terminate_all_process_instances`, `ResumeRunner.resume_all`, collect `flow_node_instances` **SELECT** `query_time_ms` during that window only (separate collector start/stop) |
| GraphQL `processInstances { flowNodeInstances { inputToken outputToken } }` | `:timer.tc` around `http_graphql/1` — **median of ≥20 queries** after data exists; do not use pool_pressure’s token-less query |

- [ ] **Step 1: Run once under current lz4.** Record p50/p95 per metric + `jsonb_payload_bytes/0` via `LoadHelpers.measure/3` ids:
  - `jsonb_lz4_exec`
  - `jsonb_lz4_resume_input_token`
  - `jsonb_lz4_graphql_tokens`
- [ ] **Step 2: `set_jsonb_compression!("pglz")`, rewrite, repeat** with ids `jsonb_pglz_*`.
- [ ] **Step 3: Restore `set_jsonb_compression!("lz4")` in `on_exit`.**
- [ ] **Step 4: Gate** — for each metric, if `lz4_p50 > pglz_p50 * 1.10` **or** `lz4_p95 > pglz_p95 * 1.10`, `flunk` with the pair of numbers. Skip the fail when sample `count < 30` (empty DOA table if mixed slice lucked into no DO writes — then **force** the DOA fixture into the mixed set so count is never zero). Include `cap_doa_oversize.bpmn` **happy path** (small DO write) in the mixed deploy list so `data_object_writes` has samples.
- [ ] **Step 5: Print** `[BENCH] jsonb_gate lz4_vs_pglz storage_bytes lz4=… pglz=…` (storage is informational; do not fail on “less reduction than 10–20 %”).
- [ ] **Step 6: Document** in `docs/guides/operations/database.md` a placeholder table “fill from the latest `mix test.load.hardening` JSON”. Do not invent numbers.

---

### Task 7: Item 5 — payload-cap load & chaos

**Files:**
- Create: `test/load/payload_cap_chaos_load_test.exs`

This is **not** a substitute for Task 2. Task 2 proves (a)(b)(c) at N=1. This file proves they still hold when 5 % of a sustained mix is oversize, and that memory does not climb.

- [ ] **Step 1: Duration** `chaos_seconds = String.to_integer(System.get_env("TDE_LOAD_CHAOS_SECONDS") || "600")`. Timeout = chaos_seconds * 1000 + 120_000.
- [ ] **Step 2: Loop** until elapsed ≥ chaos_seconds, targeting ~50 mixed HTTP ops/s (same order of magnitude as testing.md CAP-MEMORY-BEHAVIOR). Each op is one of: start linear (at-limit payload), start linear (oversize → 413), trigger message (at-limit / oversize), finish user task (at-limit / oversize). **5 %** of ops are oversize (`rem(index, 20) == 0` is 5 %).
- [ ] **Step 3: After each oversize start/trigger:** assert status 413 and that `messages` / `process_instances` counts did not increase (snapshot counts before/after that call).
- [ ] **Step 4: Memory** — sample `:erlang.memory()[:total]` every 5 s. Assert last sample ≤ first sample after warmup (drop first 15 s) + 32 MB (testing.md said ±5 MB at 50 rps / 30 s; 10 min needs more slack — **32 MB**, not 5 MB). Also assert `LoadHelpers.count_registered_process_instances()` stays bounded (no leak of fatal-start attempts).
- [ ] **Step 5: At-limit ops must 201/204.** Oversize must never create a `messages` row (item 5(c) under load).

Workload id: `payload_cap_chaos_5pct`.

---

### Task 8: Item 7 — resume-after-crash at scale + Mix alias

**Files:**
- Create: `test/load/resume_crash_load_test.exs`
- Modify: `test/load_runner.exs`
- Modify: `mix.exs` (`cli.preferred_envs`, `aliases`, `run_load_hardening_tests/1`)
- Modify: `docs/architecture/testing.md` §12.5
- Modify: `docs/ImplementationPhases.md` items 4, 5, 7 when the suite is green

**Crash procedure (per PI cohort):**

1. Deploy: `user_task_simple`, `parallel_gateway_three_user_tasks`, `call_activity_depth_5_*`.
2. Start N=200 user-task PIs, N=50 three-branch PIs (finish 2 of 3 user tasks so `gateway_pending_arrivals` has 2 rows each), N=100 five-deep roots (parked on leaf User Task).
3. Snapshot: map of `{fni_id → input_token}` for every `state in ("active","waiting")` FNI; count of `gateway_pending_arrivals`.
4. `LoadHelpers.terminate_all_process_instances()`. Assert registry empty. Postgres rows still `running` / `waiting`.
5. `ResumeRunner.resume_all()`. Assert resumed count == number of running PIs (roots + children for CA trees).
6. Assert every snapshotted FNI `input_token` equals the reloaded row (item 7(a)).
7. Assert `gateway_pending_arrivals` count unchanged and each three-branch PI still has 2 rows; finish the third user task; PI finishes (item 7(b) at scale).
8. `Repo.query!("SELECT to_regclass('public.active_tokens')")` is `nil`. After resume, `:sys.get_state` on a PI **must not** be used if it is fragile — instead grep in-memory by asserting the process dictionary / state via existing public getters only. If there is no public “active tokens” list (there should not be), the SQL check plus “resume works” is item 7(c). Do **not** invent an `active_tokens` field on `ProcessInstance.State`.

Workload ids: `resume_crash_user_task_200`, `resume_crash_parallel_join_50`, `resume_crash_ca_depth5_100`.

- [ ] **Step 1: Write the test.** `@tag :hardening`, `@tag timeout:` large enough for start+kill+resume+drain.
- [ ] **Step 2: Runner flags** — mirror durability:

```elixir
hardening_mode = System.get_env("TDE_LOAD_HARDENING")
# unset → exclude :hardening (and existing :durability rules)
# "1"/"true" → only :hardening
# "all" → include hardening with the default load suite
```

`mix test.load` must keep working unchanged (exclude both `:durability` and `:hardening`).

- [ ] **Step 3: `mix.exs`**

```elixir
"test.load.hardening": :test,  # preferred_envs
"test.load.hardening": &run_load_hardening_tests/1,

defp run_load_hardening_tests(args) do
  run_load_suite(args, %{"TDE_LOAD_HARDENING" => "1"})
end
```

- [ ] **Step 4: Docs** — `testing.md` §12.5 table for hardening; ImplementationPhases items 4/5/7 marked DONE with file pointers after a successful local `mix test.load.hardening` (duration env may be `TDE_LOAD_CHAOS_SECONDS=30` for the first green, then one full 600 s run before calling item 5 done).
- [ ] **Step 5: Run** (test DB one-liner, `TDE_LOAD_TEST_POOL=1` via the Mix alias):

```bash
TDE_LOAD_COMPRESSION_COUNT=1000 TDE_LOAD_CHAOS_SECONDS=30 mix test.load.hardening
```

Expected: pass. Then one full run:

```bash
mix test.load.hardening
```

If the 10 % LZ4 gate fails: **do not** silently switch the default. Record numbers in `docs/guides/operations/database.md` and stop for a human decision on `TDE_JSONB_COMPRESSION`.

- [ ] **Step 6: `mix quality`** after Layer A + any `runtime.exs` / production code changes. Hardening files do not need to be inside `mix quality`.

---

## Definition of Done

- Layer A CAP-\* / SHAPE-\* / I1 `input_token` green under `mix quality`.
- `TDE_TOKEN_MAX_BYTES=512` cannot boot (raise), default 65536 unchanged.
- `mix test.load` still excludes hardening (and durability).
- `mix test.load.hardening` runs items 4, 5, 7; writes JSON via existing `LoadRunnerReport`.
- GitHub `load-bench.yml` unchanged.
- ImplementationPhases.md items 4, 5, 7 checked off only after a full hardening run, not after the 30 s smoke.

## Risks

| Risk | Mitigation |
|---|---|
| `ALTER COMPRESSION` + rewrite on a dirty test DB is slow or deadlocks | TRUNCATE runtime tables first (ExecutionCase already truncates on load pool); rewrite only JSONB columns |
| `flow_node_instances` query_time mixes reads and writes | Resume window uses a dedicated collector; GraphQL is wall-clock of the HTTP call |
| 10 % gate flakes on GH | Hardening is not on GH; local/workstation only |
| 5-level deploy order | Leaf first; `http_deploy` each file |
| Chaos 5 MB RSS bound is unrealistic at 10 min | 32 MB after 15 s warmup |
| Silent `max(bytes, 1024)` hid invalid ops config | Explicit raise (Task 1) |

## Spec coverage check

| Phase 7 line | Task |
|---|---|
| 4 LZ4 vs PGLZ p50/p95 for write_result, DOA, publish, resume reads, GraphQL tokens; 10 % gate; 10k mixed; 5-level present; up to 64 KiB | 4, 5, 6 |
| 5(a) at-limit success | 2 step 5 + 7 |
| 5(b) oversize facade/fatal/no DB write | 2 steps 1–3 + 7 |
| 5(c) REST message trigger 413, no `messages` row | existing `message_events_test` + 7 |
| 5 5 % oversize for 10 min, flat memory | 7 |
| 7(a) active/waiting `input_token` intact | 3 + 8 |
| 7(b) `gateway_pending_arrivals` re-arm join | existing 11a + 8 |
| 7(c) no `active_tokens` table / in-memory | 3 SQL + 8 |

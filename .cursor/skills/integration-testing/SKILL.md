# Integration Testing Skill

> **Use when**: writing integration tests, adding test scenarios, extending test fixtures,
> or debugging test failures in the Engine project.

## MANDATORY: Start the Test Database First

**Before doing ANYTHING else in this skill, run this one-liner to ensure the DB is up:**

```bash
(docker inspect --format='{{.State.Running}}' bfw-engine-postgres-test 2>/dev/null | grep -q true) || (docker start bfw-engine-postgres-test 2>/dev/null || bash scripts/create-test-db.sh) && docker exec bfw-engine-postgres-test pg_isready -U bfw_engine && MIX_ENV=test mix ecto.migrate
```

**This is not optional. Do not skip this. Do not defer this.**

If the one-liner fails, run the steps individually:

```bash
# Check if container exists and is running
docker inspect --format='{{.State.Running}}' bfw-engine-postgres-test 2>/dev/null

# If output is "true" → container is running, skip to migration step
# If output is "false" → start it:
docker start bfw-engine-postgres-test

# If error or empty → create it from scratch:
bash scripts/create-test-db.sh

# Verify readiness (retry up to 3 times with 2s sleep between attempts)
docker exec bfw-engine-postgres-test pg_isready -U bfw_engine

# Run pending migrations
MIX_ENV=test mix ecto.migrate
```

**If you skip this step and later report "tests deferred because DB is not running", you have violated this skill's contract and the project's build rules.**

## For Parent Agents Delegating to Subagents

When launching a subagent to run integration tests, you MUST include this instruction in the Task prompt:

> Before running any tests, ensure the PostgreSQL test container is running:
> `(docker inspect --format='{{.State.Running}}' bfw-engine-postgres-test 2>/dev/null | grep -q true) || (docker start bfw-engine-postgres-test 2>/dev/null || bash scripts/create-test-db.sh) && docker exec bfw-engine-postgres-test pg_isready -U bfw_engine && MIX_ENV=test mix ecto.migrate`

Subagents do not inherit workspace rules. The parent agent is responsible for including DB startup instructions in the subagent's prompt.

---

## Overview

Integration tests exercise the full engine stack end-to-end. They verify that all
layers — GenServers, event bus, plugin registry, HTTP routes, JWT auth — work
together as a whole.

Architecture reference: [`docs/architecture/testing.md`](../../../docs/architecture/testing.md)

---

## Full-Stack Integration Tests (Project Root)

Full-stack integration tests live at the **project root**, not inside any
individual umbrella app. They test the engine as a black box.

### Directory layout

```
test/
├── integration_runner.exs          # ExUnit bootstrap script
├── support/
│   ├── integration_case.ex         # Shared CaseTemplate
│   └── test_sinks.ex               # IntegrationSink, CrashSink, FakePlugin
├── fixtures/
│   ├── bpmns/                      # BPMN fixture files for element tests
│   │   ├── call_activity_simple.bpmn
│   │   ├── start_event_message_correlated.bpmn
│   │   └── ...
│   └── plugins/                    # Sidecar plugin fixtures (Phase 4)
│       ├── elixir-echo/
│       ├── python-echo/
│       └── ...
└── integration/
    ├── health_info_stats_test.exs  # Public probes and authenticated telemetry
    ├── event_bus_wiring_test.exs   # Event bus → sink pipeline, crash isolation
    ├── plugin_registry_test.exs    # Plugin registration, conflict, quarantine
    └── auth_pipeline_test.exs      # JWT auth through real HTTP pipeline
```

### Prerequisites

Umbrella-level integration tests require a running PostgreSQL Docker container.
**Before running any integration test**, follow the `ensure-test-db` skill to
verify the container is running and ready. It is NOT acceptable to skip tests
because PostgreSQL is unavailable — agents MUST start the container.

Quick reference (full procedure in the `ensure-test-db` skill):

```bash
# Check container status
docker inspect --format='{{.State.Running}}' bfw-engine-postgres-test 2>/dev/null

# First-time setup (creates container + runs migrations)
bash scripts/create-test-db.sh

# Start an existing stopped container
docker start bfw-engine-postgres-test

# Verify readiness
docker exec bfw-engine-postgres-test pg_isready -U bfw_engine

# Run pending migrations after schema changes
MIX_ENV=test mix ecto.migrate
```

### Running integration tests

```bash
# Via mix alias (recommended)
mix test.integration

# Direct invocation
MIX_ENV=test mix run test/integration_runner.exs

# Full quality gate (compile + credo + unit + integration)
mix quality
```

### IntegrationCase CaseTemplate

`BfwEngine.IntegrationCase` provides:

- **State reset** between tests via `EngineEventBus.reset_state()` and
  `Registry.reset_state()` — no process restarts, no supervisor budget exhaustion.
- **JWT helpers**: `sign_jwt/1`, `conn_with_auth/3`
- **Router helper**: `route/1` sends a conn through the real HTTP router
- **Config override**: `with_config/4` temporarily swaps an app env key

```elixir
defmodule BfwEngine.Integration.MyTest do
  use BfwEngine.IntegrationCase, async: false

  test "authenticated route returns 200" do
    with_config(:api_auth, :auth_disabled, false, fn ->
      conn = conn_with_auth(:get, "/stats", %{"sub" => "user-1"})
      assert route(conn).status == 200
    end)
  end
end
```

### Adding a new integration test

1. Create `test/integration/<feature>_test.exs`
2. `use BfwEngine.IntegrationCase, async: false`
3. Cover:
   - **Happy path** (valid auth, valid data)
   - **Auth rejection** (expired/wrong-secret/missing token)
   - **Malformed input** (garbage headers, oversize payloads, empty strings)
   - **Crash isolation** (one component failing must not break others)
4. Run `mix test.integration` to verify

### Test sinks and fake modules

Test support modules in `test/support/test_sinks.ex`:

| Module | Purpose |
|--------|---------|
| `BfwEngine.Test.IntegrationSink` | Forwards events to `test_pid` for `assert_receive` |
| `BfwEngine.Test.IntegrationCrashSink` | Deliberately crashes on every event (for isolation tests) |
| `BfwEngine.Test.FakePlugin` | Minimal `BfwEngine.Plugin` behaviour implementation |

Register sinks with the event bus using the 3-arity API:

```elixir
:ok = EngineEventBus.register_sink("test:observer", IntegrationSink, test_pid: self())
```

---

## Per-App Unit and Domain Tests

Each umbrella app has its own `test/` directory for domain-specific tests.

### CaseTemplate reference

| Template | Module | Use when… | Sets up |
|----------|--------|-----------|---------|
| `DataCase` | `BfwEngine.DataCase` | Ash resources, Ecto queries | Ecto sandbox |
| `ConnCase` | `BfwEngine.ConnCase` | REST, GraphQL, task completions | Ecto sandbox + Phoenix endpoint |
| `EngineCase` | `BfwEngine.EngineCase` | Full round-trip: deploy → start → assert | Ecto sandbox + Phoenix + all engine GenServers |

### Per-app test directory layout

```
apps/<app>/test/
├── test_helper.exs
├── support/
│   └── *.ex              # App-specific test helpers
└── <domain>_test.exs     # Unit tests
```

---

## AuthHelper (per-app)

`apps/api_auth/test/support/auth_helper.ex` and `apps/api_web/test/support/auth_helper.ex`
mint JWTs for per-app tests.

For integration tests, use `BfwEngine.IntegrationCase.sign_jwt/1` instead.

---

## BPMN Element Integration Tests

**Every BPMN element integration test MUST run against an actual BPMN file.**
Tests never construct process models in code — they deploy a real `.bpmn` file
on the engine and execute it end-to-end, simulating real-life execution.

### Fixture location

BPMN fixture files live at `test/fixtures/bpmns/` (project root).

### File naming convention

Name each `.bpmn` file based on **the element under test** and **the scenario**:

```
test/fixtures/bpmns/
├── start_event_message_correlated.bpmn
├── call_activity_simple.bpmn
├── call_activity_multi_instance_sequential.bpmn
├── exclusive_gateway_default_branch.bpmn
├── parallel_gateway_fan_out_join.bpmn
├── boundary_timer_interrupting.bpmn
├── complex_parallel_task_chain.bpmn
└── ...
```

Pattern: `<element>_<scenario_variant>.bpmn`

| Element | Example filename |
|---------|-----------------|
| Start Event (message, correlated) | `start_event_message_correlated.bpmn` |
| Call Activity (basic) | `call_activity_simple.bpmn` |
| Call Activity (sequential MI) | `call_activity_multi_instance_sequential.bpmn` |
| Parallel Gateway (complex chain) | `complex_parallel_task_chain.bpmn` |

### Multiple processes per BPMN

To avoid a flood of files, a single `.bpmn` file MAY contain **multiple
`<bpmn:process>` definitions**, each covering a specific test case for the same
element/scenario family. For example, `call_activity_multi_instance_sequential.bpmn`
could contain processes for:

- Sequential MI Call Activity — happy path (valid config, all iterations succeed)
- Sequential MI Call Activity — called process crashes, **no** error boundary
- Sequential MI Call Activity — called process crashes, error boundary catches
- Sequential MI Call Activity — called process triggers an escalation, **no** escalation boundary
- Sequential MI Call Activity — called process triggers an escalation, escalation boundary catches

Each process is independently deployable and targeted by a specific test case.
The test picks the process by key (e.g. `"ca_seq_mi_happy"`,
`"ca_seq_mi_crash_no_boundary"`, etc.).

For complex flow-node chains that don't map to a single element, name the file
based on what the test attempts to verify:

- `complex_parallel_task_chain.bpmn` — parallel gateways spawning many paths
  with sub-forks, additional parallel gateways, and mixed element combinations

### BPMN validity rules

Every fixture `.bpmn` file MUST:

1. Be **valid BPMN 2.0 XML** — parseable by the engine's `saxy`-based parser
2. Contain at least one **Start Event** and at least one **End Event** per process
3. Carry a non-blank `<bfw:version>` (deploy requirement)
4. Pass the engine's deploy-time validation (enforced minimum pattern)
5. NOT use elements beyond what the engine supports at the current phase

### Test execution pattern

Tests deploy the BPMN on the engine before running assertions:

```elixir
defmodule BfwEngine.Integration.CallActivityTest do
  use BfwEngine.IntegrationCase, async: false

  @fixture_path Path.expand("test/fixtures/bpmns/call_activity_simple.bpmn")

  setup do
    bpmn_xml = File.read!(@fixture_path)
    {:ok, _version} = deploy_bpmn(bpmn_xml)
    :ok
  end

  test "child PI completes and maps result back to parent" do
    {:ok, pi} = start_process("call_activity_simple_happy")
    pi = await_terminal(pi.id)

    assert pi.state == :finished
    # assert result mapping applied to parent token
  end

  test "child PI failure propagates to parent boundary" do
    {:ok, pi} = start_process("call_activity_simple_child_crash")
    pi = await_terminal(pi.id)

    assert pi.state == :finished
    # assert boundary error handler fired
  end
end
```

### YAML test specs (companion files)

Each `.bpmn` fixture has an optional companion `.yaml` test spec that declares:

- Start inputs (payload, identity)
- Expected event ordering
- Expected final state per PI/FNI
- Expected token payloads
- Data Object expected values

These specs feed the assertion framework described in
[`testing.md`](../../../docs/architecture/testing.md) §12.4.3.

---

## FixtureProvider

Centralized fixture factory. Never inline fixture data in test bodies.

### Payload helpers

```elixir
FixtureProvider.mint_payload(1024)
FixtureProvider.oversize_payload()
```

---

## MANDATORY: Fix ALL Test Failures

**Every agent MUST fix ALL test failures, warnings, and errors encountered
during `mix quality` or any test run — no exceptions.**

This is a **non-negotiable** rule. Violations of this rule directly endanger
the CI pipeline and block every other contributor.

### Why "pre-existing" is not an excuse

Bifrost Forge World Engine is a highly interconnected umbrella project. A change
to `core_execution` can break tests in `api_web`. A new handler in
`handler_dispatch.ex` can cause cascading failures in conformance tests. A
new PI state can break retry logic in `api_facade`. **It is never safe to
assume a failing test is unrelated to your changes.**

Even if a failure genuinely predates your work, the CI pipeline does not
distinguish "your fault" from "someone else's fault" — it sees red and
blocks the merge. Leaving a known failure for "someone else to fix" is
functionally identical to introducing it yourself.

### Rules

1. **Run `mix quality` after every logical change.** This is defined in
   `.cursor/rules/build.mdc` and is non-optional.
2. **If any test fails, fix it.** Do not move on to the next task. Do not
   mark your work as complete. Do not report "N tests failed but they seem
   pre-existing."
3. **If a test that previously passed now fails, the cause is almost
   certainly your change.** Investigate the connection before assuming
   otherwise. The codebase is too interconnected for coincidences.
4. **If you genuinely cannot fix a failure** (e.g., it requires domain
   knowledge you lack, or it depends on infrastructure you cannot access),
   **explicitly report it as a blocker** with full error output, your
   analysis of the root cause, and what you tried. Do not silently skip it.
5. **"It worked on my machine" is not acceptable.** Tests must pass in the
   standardized `mix quality` pipeline, which includes compile, Credo,
   Dialyzer, Sobelow, docs, unit tests, integration tests, and conformance
   tests.

### Common trap: `DBConnection.OwnershipError`

This error in integration tests almost always means a Process Instance
outlived the test's Ecto sandbox checkout. Common causes:

- The PI's `terminate/3` callback does async work after the test ends
- A child process (Task.Supervisor, handler Task) does a DB write after
  the owning test process exits
- `wait_for_process_instance/2` returned before all PI cleanup finished

Fix by ensuring PI processes fully terminate (including their
Task.Supervisor) before the test asserts. Use `Process.monitor` +
`assert_receive {:DOWN, ...}` patterns instead of `refute Process.alive?`.

---

## Test Coverage Requirements

Every new feature MUST include tests covering:

1. **Happy paths** — Normal operation with valid data
2. **Bad paths** — Malformed, out-of-range, wrong-typed, gibberish data
3. **Sanity checks** — Idempotency, ordering invariants
4. **Security checks** — Auth rejection, expired tokens, wrong secrets

---

## Test Type Decision Tree

```
Is this about a single module's behavior in isolation?
  YES → Unit test (per-app test/)
  NO  ↓
Is this testing cross-app integration (HTTP + EventBus + Plugins)?
  YES → Full-stack integration test (project root test/integration/)
  NO  ↓
Is this about random/adversarial input generation?
  YES → Property-based test (stream_data / Concuerror)
  NO  ↓
Is this verifying normative BPMN 2.0 behavior?
  YES → Conformance test (.bpmn + YAML spec corpus)
  NO  ↓
Is this about throughput or latency under load?
  YES → Load test (k6/wrk, separate suite)
```

---

## Mix Aliases Summary

| Alias | What it runs |
|-------|-------------|
| `mix test.unit` | All per-app tests (excludes `@tag :integration`) |
| `mix test.integration` | Full-stack integration tests at project root (no coverage) |
| `mix test.conformance` | YAML-driven conformance corpus (no coverage) |
| `mix test.coverdata` | Integration + conformance under one `:cover` session; exports coverdata for `--import-cover` |
| `mix test.full` | Compile + credo + unit tests + integration tests |
| `mix quality` | Compile, lint, analysis, docs, `test.coverdata`, then `coveralls.html --umbrella --import-cover cover` |

---

## Environment Variables for Test Config

| Variable | Test default | Purpose |
|----------|-------------|---------|
| `BFE_TOKEN_MAX_BYTES` | `65536` | Default cap; override for CAP-CONFIGURABLE tests |
| `BFE_AUTH_DISABLED` | `false` | Use real JWT auth in integration tests |
| `BFE_MESSAGE_PENDING_TTL` | `PT30S` | For pending-TTL rematch/expiry tests |

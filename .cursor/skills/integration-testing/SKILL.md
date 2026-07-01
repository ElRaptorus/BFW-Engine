# Integration Testing Skill

> **Use when**: writing integration tests, adding test scenarios, extending test fixtures,
> or debugging test failures in the Evil Engine project.

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
docker inspect --format='{{.State.Running}}' evil-engine-postgres-test 2>/dev/null

# First-time setup (creates container + runs migrations)
bash scripts/create-test-db.sh

# Start an existing stopped container
docker start evil-engine-postgres-test

# Verify readiness
docker exec evil-engine-postgres-test pg_isready -U evil_engine

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

`EvilEngine.IntegrationCase` provides:

- **State reset** between tests via `EngineEventBus.reset_state()` and
  `Registry.reset_state()` — no process restarts, no supervisor budget exhaustion.
- **JWT helpers**: `sign_jwt/1`, `conn_with_auth/3`
- **Router helper**: `route/1` sends a conn through the real HTTP router
- **Config override**: `with_config/4` temporarily swaps an app env key

```elixir
defmodule EvilEngine.Integration.MyTest do
  use EvilEngine.IntegrationCase, async: false

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
2. `use EvilEngine.IntegrationCase, async: false`
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
| `EvilEngine.Test.IntegrationSink` | Forwards events to `test_pid` for `assert_receive` |
| `EvilEngine.Test.IntegrationCrashSink` | Deliberately crashes on every event (for isolation tests) |
| `EvilEngine.Test.FakePlugin` | Minimal `EvilEngine.Plugin` behaviour implementation |

Register sinks with the event bus using the 3-arity API:

```elixir
:ok = EngineEventBus.register_sink("test:observer", IntegrationSink, test_pid: self())
```

---

## Sidecar Plugin Testing (Phase 4)

Sidecar plugin integration tests land with Phase 4 step 3. They are **not yet
implemented** — this section captures the requirements so they are not dropped.

Architecture reference: [`docs/architecture/testing.md`](../../../docs/architecture/testing.md) §12.4.8
and [`docs/architecture/plugins.md`](../../../docs/architecture/plugins.md) §9.2.3.

### Fixture location

Multi-language sidecar fixture plugins live at `test/fixtures/plugins/` (project
root). Each subdirectory is a minimal but realistic sidecar with a `plugin.toml`
and a runnable binary/script.

### Required languages

To prove the language-agnostic claim, fixture plugins must cover **five
languages**: Elixir (escript), Python, Ruby, C# (dotnet), and Node.js. Each
must successfully discover, handshake, register, and execute a Service Task
end-to-end.

### Test isolation pattern

```elixir
setup do
  original_dir = Application.get_env(:peripheral_plugins, :sidecar_dir)
  fixture_dir = Path.expand("test/fixtures/plugins")
  Application.put_env(:peripheral_plugins, :sidecar_dir, fixture_dir)

  on_exit(fn ->
    # Disconnect all sidecar Ports, reset registry, restore config
    SidecarLoader.unload_all()
    Registry.reset_state()
    Application.put_env(:peripheral_plugins, :sidecar_dir, original_dir)
  end)

  :ok
end
```

### Scenarios to implement

| ID | Scenario | What it proves |
|----|----------|---------------|
| (i) | Happy-path sidecar Service Task | Full round-trip: discover → handshake → register → execute → result |
| (ii) | Crash mid-execution → reconnect | Port restart, graceful FNI failure |
| (iii) | Repeated crash → quarantine | `PluginQuarantined` event emitted, no further reconnects |
| (iv) | Malformed `plugin.toml` | Engine boots, broken plugin quarantined, others unaffected |
| (v) | Deny-listed manifest | Plugin never spawned, structured log emitted |
| (vi) | Multi-language proof | One fixture per language (Elixir, Python, Ruby, C#, Node.js) |
| (vii) | `sidecar_dir` isolation | Config restored, no registrations leak between tests |

---

## Per-App Unit and Domain Tests

Each umbrella app has its own `test/` directory for domain-specific tests.

### CaseTemplate reference

| Template | Module | Use when… | Sets up |
|----------|--------|-----------|---------|
| `DataCase` | `EvilEngine.DataCase` | Ash resources, Ecto queries | Ecto sandbox |
| `ConnCase` | `EvilEngine.ConnCase` | REST, GraphQL, task completions | Ecto sandbox + Phoenix endpoint |
| `EngineCase` | `EvilEngine.EngineCase` | Full round-trip: deploy → start → assert | Ecto sandbox + Phoenix + all engine GenServers |

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

For integration tests, use `EvilEngine.IntegrationCase.sign_jwt/1` instead.

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
3. Carry a non-blank `<evil:version>` (deploy requirement)
4. Pass the engine's deploy-time validation (enforced minimum pattern)
5. NOT use elements beyond what the engine supports at the current phase

### Test execution pattern

Tests deploy the BPMN on the engine before running assertions:

```elixir
defmodule EvilEngine.Integration.CallActivityTest do
  use EvilEngine.IntegrationCase, async: false

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
| `mix test.integration` | Full-stack integration tests at project root |
| `mix test.full` | Compile + credo + unit tests + integration tests |
| `mix quality` | Same as `test.full` — the quality gate |

---

## Environment Variables for Test Config

| Variable | Test default | Purpose |
|----------|-------------|---------|
| `EVIL_TOKEN_MAX_BYTES` | `65536` | Default cap; override for CAP-CONFIGURABLE tests |
| `EVIL_AUTH_DISABLED` | `false` | Use real JWT auth in integration tests |
| `EVIL_MESSAGE_PENDING_TTL` | `PT30S` | For pending-TTL rematch/expiry tests |

# Integration Testing — Reference Tables

Companion to [SKILL.md](./SKILL.md). Contains detailed API surfaces and mapping
tables for test infrastructure components.

---

## CaseTemplate API

### DataCase

```elixir
defmodule EvilEngine.DataCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      alias EvilEngine.Repo
      import Ecto.Changeset
      import Ecto.Query
      import EvilEngine.DataCase
    end
  end

  setup tags do
    EvilEngine.DataCase.setup_sandbox(tags)
    :ok
  end
end
```

**Setup callbacks**: `setup_sandbox/1` — checks out an Ecto sandbox connection.
**Imported modules**: `Ecto.Changeset`, `Ecto.Query`, `EvilEngine.DataCase`.

### ConnCase

```elixir
defmodule EvilEngine.ConnCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      import Plug.Conn
      import Phoenix.ConnTest
      import EvilEngine.ConnCase
      alias EvilEngine.Router.Helpers, as: Routes
      @endpoint EvilEngine.Endpoint
    end
  end

  setup tags do
    EvilEngine.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
```

**Setup callbacks**: `setup_sandbox/1` + builds a `%Plug.Conn{}`.
**Imported modules**: `Plug.Conn`, `Phoenix.ConnTest`, route helpers.
**Provides**: `%{conn: conn}` in test context.

### EngineCase

```elixir
defmodule EvilEngine.EngineCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      import EvilEngine.EngineCase
      alias EvilEngine.Test.{AuthHelper, FixtureProvider, ProcessInteraction, AssertionBundle}
    end
  end

  setup tags do
    EvilEngine.DataCase.setup_sandbox(tags)
    {:ok, _} = start_supervised(EvilEngine.Supervisor)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
```

**Setup callbacks**: sandbox + starts the full engine supervision tree.
**Imported modules**: all test helpers.
**Provides**: `%{conn: conn}` + running engine.

---

## FixtureProvider Function Table

| Function | Arguments | Returns | Purpose |
|----------|-----------|---------|---------|
| `load_bpmn/1` | `fixture_name :: String.t()` | `{:ok, bpmn_xml :: String.t()}` | Reads `.bpmn` from `test/fixtures/` |
| `load_spec/1` | `fixture_name :: String.t()` | `{:ok, spec :: map()}` | Reads + parses `.yaml` test spec |
| `load_fixture/1` | `fixture_name :: String.t()` | `{:ok, %{bpmn: String.t(), spec: map()}}` | Loads both BPMN + YAML |
| `deploy_fixture/2` | `fixture_name, identity` | `{:ok, process_version}` | Deploys BPMN via REST, returns version |
| `mint_payload/1` | `n_bytes :: pos_integer()` | `map()` | Generates a JSON payload of exactly `n_bytes` |
| `oversize_payload/0` | — | `map()` | `mint_payload(EVIL_TOKEN_MAX_BYTES + 1)` |
| `register_test_plugin/2` | `tier :: :in_beam \| :sidecar, module_or_name` | `:ok` | Registers a plugin for the test session |
| `unregister_test_plugin/1` | `module_or_name` | `:ok` | Removes a test plugin |
| `test_process_payload/0` | — | `map()` | Standard valid payload for process start |
| `test_user_task_result/0` | — | `map()` | Standard valid result for User Task completion |

---

## Scenario-to-Fixture Mapping

| Scenario | Fixture file | Description |
|----------|-------------|-------------|
| S1 | `linear_happy_path.bpmn` | Start → UserTask → ServiceTask → End |
| S2 | `parallel_gateway.bpmn` | Parallel fan-out + join |
| S3 | `exclusive_gateway.bpmn` | Condition-driven routing + default |
| S4 | `parallel_multi_instance_service.bpmn` | N parallel iterations |
| S5 | `sequential_multi_instance_user.bpmn` | N sequential iterations |
| S6 | `subprocess_boundary_timer.bpmn` | Interrupting timer mid-subprocess |
| S7 | `call_activity_single.bpmn` | Single-level CA, input/result mapping |
| S8 | `call_activity_deep_chain.bpmn` + children | 5–6 level deep CA chain |
| S9 | `mixed_scopes_deep.bpmn` + children | Alternating Subprocess + CA, 6 scopes |
| S10 | `cross_pi_message.bpmn` | Single-recipient intermediate messaging |
| S10a | `cross_pi_broadcast.bpmn` | Broadcast-within-key (3 siblings) |
| S10b | `catch_wins_over_start.bpmn` | Catch suppresses Start Event |
| S10c | `pending_ttl_rematch.bpmn` | Pending message rematched within TTL |
| S10d | `pending_ttl_expiry.bpmn` | Pending message expires |
| S10e | `pending_rematch_restart.bpmn` | Pending rematch after SIGKILL restart |
| S10f | `mixed_catch_boundary.bpmn` | Intermediate catch + boundary on same key |
| S11 | `error_boundary_retry.bpmn` | Fatal FNI → boundary → retry |
| S12 | `compensation_flow.bpmn` | Compensation handler on error |
| S13 | `timer_concurrency.bpmn` | Scheduled timer, many concurrent PIs |
| S14 | `multi_instance_call_activity.bpmn` | Parallel MI over CA |
| S15 | `escalation_interrupting.bpmn` + children | 3-level interrupting escalation |
| S15a | `escalation_non_interrupting.bpmn` + children | 3-level non-interrupting escalation |
| S15b | `escalation_uncaught_end.bpmn` + children | Uncaught via Escalation End |
| S15c | `escalation_uncaught_intermediate.bpmn` + children | Uncaught via Intermediate Throw |

---

## Assertion Bundle Checklist

### 1. Flow-Node execution correctness

- [ ] Every expected FNI exists (keyed by `process_instance_id, flow_node_id, iteration_index`)
- [ ] FNI set is **equal** to fixture's expected set (no missing, no extra)
- [ ] `started_at` / `finished_at` strictly monotonic per PI
- [ ] Multi-instance FNI count equals declared cardinality
- [ ] Sequential MI: `started_at` is a total order
- [ ] Parallel MI: all within parent scope's active window

### 2. Final state

- [ ] Every PI reaches declared terminal state exactly
- [ ] Every FNI reaches declared terminal state exactly
- [ ] `PI.finished_at` non-null iff terminal
- [ ] No `active` FNIs remain after root PI is terminal
- [ ] No orphan child PIs with `state = 'running'`

### 3. Token payload

- [ ] Terminal FNI payloads match fixture (deep equality)
- [ ] Data Object final values match fixture
- [ ] Call Activity raw child result + mapping-applied parent value asserted independently
- [ ] Multi-instance: full per-iteration payload list + aggregated payload at join

### 4. Data Object write audit

- [ ] `data_object_writes` sequence matches fixture exactly (ordered by `created_at`)
- [ ] Every `flow_node_instance_id` resolves to a valid FNI
- [ ] Writing FNI's Flow Node model has a `dataOutputAssociation` targeting the DO
- [ ] Last row's `value` equals `data_objects.value`
- [ ] With DB sink ON: 1:1 correspondence with `data_object.written` events
- [ ] Contract violation: zero writes, zero events, FNI → `fatal`

### 5. Audit trail (DB sink ON)

- [ ] Every declared event row present (matched by `event_type, fni_id, prev_fni_id`)
- [ ] No unexpected event rows (set-equality)
- [ ] Referential integrity: all `fni_id` references resolve
- [ ] `previous_flow_node_instance_id` chains form valid DAG

### 6. Parent/child correlation

- [ ] `child.parent_process_instance_id == parent.id`
- [ ] Child's `process_version_id` is latest non-deleted at spawn time
- [ ] CA FNI `finished` iff child PI `finished`

### 7. Engine invariants

- [ ] Zero `engine.crashes` telemetry counter increment
- [ ] No `FATAL`-level JSON log
- [ ] All internal queues return to baseline (0) before assertions
- [ ] `engine.pi.spawned` increment equals fixture's total PI count
- [ ] `engine.fni.executed` increment equals fixture's total FNI count

---

## Environment Variables for Test Config

| Variable | Test default | Override for | Relevant scenarios |
|----------|-------------|-------------|-------------------|
| `EVIL_TOKEN_MAX_BYTES` | `65536` | Cap-rejection / cap-configurable | CAP-* scenarios |
| `EVIL_AUTH_DISABLED` | `false` | Unit tests (set `true`) vs integration (`false`) | Auth-sensitive tests |
| `EVIL_MESSAGE_PENDING_TTL` | `PT30S` | Pending message TTL tests | S10c, S10d, S10e |
| `EVIL_SIGNAL_PENDING_TTL` | `PT30S` | Pending signal TTL tests | Signal variants |
| `EVIL_JWT_HS256_SECRET` | `test-secret-min-32-bytes-long!!!` | AuthHelper token signing | All authenticated tests |
| `EVIL_PLUGINS_SIDECAR_DIR` | `test/fixtures/sidecar/` | Sidecar plugin integration | Plugin tests |
| `EVIL_PARTITION_AHEAD_MONTHS` | `1` | Partition creation for tests | Partition tests |
| `EVIL_RETENTION_FINISHED_DAYS` | unset | Retention runner tests | Retention scenarios |
| `EVIL_RETENTION_ENGINE_AUDIT_DAYS` | unset | Engine audit retention | Audit retention tests |

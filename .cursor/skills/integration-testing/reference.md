# Integration Testing — Reference

Layout and suite overview: `docs/architecture/testing.md` §Test layout.

## Case templates

| Module | File | Setup | Imports / provides |
|--------|------|-------|--------------------|
| `BfwEngine.Persistence.DataCase` | `test/unit/persistence/support/data_case.ex` | Sandbox checkout of `Repo` and `ReadRepo`, shared mode | `import BfwEngine.Persistence.DataCase` |
| `BfwEngine.IntegrationCase` | `test/support/integration_case.ex` | Restarts `EngineEventBus`, plugin registry, auth provider registry and BPMN `ModelCache` through `BfwEngine.Test.ServiceReset`; sets the test HS256 secret; terminates running PIs; sandbox checkout when the pool is a sandbox | `Plug.Test`, `Plug.Conn`, `conn_with_auth/3`, `route/1`, `sign_jwt/1` |
| `BfwEngine.ExecutionCase` | `test/support/execution_case.ex` | `IntegrationCase` reset plus message and signal subscriptions; event collector setup | Imports `DbAssertions`, `EventCollector`, `BpmnLoader`, `ProcessInteractions`; `http_*` helpers for every REST operation (deploy, start, user/manual tasks, abort, retry, triggers, catalog, GraphQL, DMN, ad-hoc), `poll_pi_state/3`, `poll_fni_state/4`, `wait_for_process_instance/2`, `fetch_data_object*/2` |

Unit tests use `ExUnit.Case` and reset GenServers through `BfwEngine.Test.ServiceReset` (`test/unit/harness/support/service_reset.ex`).

## Harness modules (`test/support/`)

| Module | Purpose |
|--------|---------|
| `BfwEngine.Test.DbAssertions` | Row reads and assertions: `fetch_process_instance!/1`, `fetch_flow_node_instances/1`, `assert_pi_state!/3`, `assert_execution_chain!/2`, `assert_all_fnis_terminal!/1`, `assert_flow_node_instance_count!/2`, `find_fni_by_flow_node_id/2`, `assert_no_running_fnis!/1`, `await_child_process_instance_ids/2` |
| `BfwEngine.Test.ProcessInteractions` | Drive a running PI: finish/cancel user and manual tasks, finish/fail async service tasks, `await_process_instance_state/3`, `await_waiting_fni_by_node_id/3`, `await_finished_fni_by_node_id/3`, `await_child_process_instance_state/2` |
| `BfwEngine.Test.EventCollector` | EventSink that forwards every engine event to the test: `start_link/1`, `get_events/1`, `await_events/3`, `silence/1` |
| `BfwEngine.Test.PayloadCapFixtures` | `mint_payload/1` (exact JSON byte size), `oversize_payload/0`, `exactly_at_limit_payload/0`, `json_byte_size/1` |
| `BfwEngine.Test.BpmnLoader` | `deploy_fixture/2` for a fixture under `test/fixtures/bpmns/` |
| `BfwEngine.Test.ConformanceRunner`, `ConformanceSteps`, `DmnConformanceRunner` | Execute the YAML specs in `test/conformance/` |
| `BfwEngine.Test.ClientEndpoint` | Loopback Bandit listener for the Elixir client tests |
| `BfwEngine.Test.LoadHelpers`, `BenchmarkReporter`, `LoadRunnerReport`, `CompletionCounter` | Load suite only |

JWTs are signed with `BfwEngine.Test.AuthHelper.sign_jwt/1` (`test/unit/auth/support/auth_helper.ex`); the case templates' `sign_jwt/1` delegate to it.

## Assertion checklist for an execution scenario

1. **Flow nodes** — the set of FNIs equals the expected set (no missing, no extra); MI iteration count equals the collection length.
2. **Final state** — every PI and FNI reaches its expected terminal state; no `:active` / `:waiting` FNI remains after the root PI is terminal; no child PI is left `running`.
3. **Tokens** — terminal FNI outputs and Data Object values match (deep equality); a Call Activity's child result and the mapped parent value are asserted separately.
4. **Data Object writes** — `data_object_writes` rows ordered by `created_at` match; the last row's `value` equals `data_objects.value`; a contract violation leaves zero writes and the FNI `fatal`.
5. **Parent / child** — `child.parent_process_instance_id == parent.id`; the child's `process_version_id` is the latest non-deleted version at spawn time.
6. **Events** — when the scenario is about observability, assert the typed events through `EventCollector`, not log output.

## Environment variables relevant to tests

| Variable | Effect in tests |
|----------|-----------------|
| `BFE_TOKEN_MAX_BYTES` | Payload cap for the `CAP-*` scenarios |
| `BFE_AUTH_DISABLED` | Must stay `false` in integration tests; auth rejection is part of the coverage |
| `BFE_JWT_HS256_SECRET` | Secret used by `AuthHelper` when set; the case templates fall back to a fixed test secret |
| `BFE_MESSAGE_PENDING_TTL`, `BFE_SIGNAL_PENDING_TTL` | Pending-message / pending-signal TTL scenarios |
| `BFE_PARTITION_AHEAD_MONTHS` | Partitions the runners create at start (`Partitions.ensure_partitions/0`) |

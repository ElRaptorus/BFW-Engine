# Decision Audit Reporter — example event sink + facade worker

Builds a post-execution DMN compliance audit: runtime coverage from live Business Rule Task completions, persisted FNI inspection, boundary-case evaluations, latency SLA flags, and a JSON report for operators and DMN observers.

This is the in-BEAM successor of the former `examples/sidecar-js/decision-audit-reporter` sketch (removed with the gRPC sidecar host, PLUG-D1). The observation goals are unchanged; the plugin now uses `register_event_sink` plus `EngineFacade` instead of a mocked gRPC sidecar.

## What this demonstrates

- **Event streaming** — `AuditSink` accepts `FlowNodeInstanceFinished` for DMN Business Rule Tasks and records IDs in `EventTracker`
- **Facade API queries** — after the collection window, `FniInspector` calls `facade.flow_node_instances.get/1` for `type_properties` (decision ref, latency, matched rules, trace)
- **Decision evaluation** — `BoundaryTester` runs boundary-case inputs via `facade.decisions.evaluate/3` to complement runtime coverage
- **Audit report assembly** — JSON report with per-model stats, rule coverage, and compliance flags

Compared with [`dead_rule_detector`](../dead_rule_detector/):

| Aspect | `dead_rule_detector` | `decision_audit_reporter` |
|--------|----------------------|---------------------------|
| Data source | Plugin deploys fixtures and starts N process instances | Observes live BRT completions, then queries FNIs |
| Goal | Dead-rule / coverage analysis | Same goal, plus latency SLA and a compliance report |
| Boundary tests | Not included | Ad-hoc `evaluate` of configured edge-case inputs |

Both use the same employee-benefits DMN fixture and intentionally omit inputs that hit rules 10, 11, and 12 when those rules are absent from runtime traces.

## Architecture

```
EngineEventBus (FlowNodeInstanceFinished)
        │
        ▼
  AuditSink ──► EventTracker (FNI IDs)
        │
        ▼
  FniInspector ──► facade.flow_node_instances.get
        │
        ├──► flow node instance details (latency, matched rules, trace)
        │
        ▼
  BoundaryTester ──► facade.decisions.evaluate
        │
        ▼
  CoverageAnalyzer + AuditReportBuilder ──► AuditReport JSON
```

The plugin never replaces DMN execution. It observes BRT completions and queries the engine facade for deeper inspection and ad-hoc evaluation.

## Fixtures

| File | Purpose |
|------|---------|
| `bpmn/employee_benefits_process.bpmn` | Single BRT calling `employee-benefits` |
| `dmn/employee_benefits.dmn` | 12-rule benefits table (rules 10–12 are hard to hit) |

Identical copies of the in-BEAM `dead_rule_detector` example.

## Report format and compliance flags

The audit report map includes:

- **summary** — total executions, unique models, average and P95 latency (microseconds), boundary-test error rate
- **per_model** — execution count, average latency, rule coverage, boundary test results
- **compliance**
  - `all_models_evaluated` — every per-model entry has `execution_count > 0`
  - `no_dead_rules_found` — no unmatched rule IDs in runtime coverage
  - `latency_within_sla` — all per-model `avg_latency_us` below `100_000` µs (override with `:sla_threshold_us`)

## Usage steps

1. Copy `lib/*.ex` into your OTP application (or add the example path to code paths in development).
2. Set `:plugin_module` to `Examples.BusinessRules.DecisionAuditReporter.DecisionAuditReporterPlugin` and list your app in `EVIL_PLUGINS_INBEAM`.
3. Deploy `dmn/employee_benefits.dmn` and `bpmn/employee_benefits_process.bpmn`.
4. Start process instances during the collection window (default 60 s).
5. Inspect engine logs for lines prefixed with `decision_audit_reporter:`.
6. Retrieve the last report from tests or IEx with `AuditReporterWorker.get_last_report/1`.

Run unit tests:

```bash
mix test examples/plugins/business_rules/decision_audit_reporter/test/event_tracker_test.exs
mix test examples/plugins/business_rules/decision_audit_reporter/test/audit_sink_test.exs
mix test examples/plugins/business_rules/decision_audit_reporter/test/coverage_analyzer_test.exs
mix test examples/plugins/business_rules/decision_audit_reporter/test/audit_report_builder_test.exs
mix test examples/plugins/business_rules/decision_audit_reporter/test/fni_inspector_test.exs
mix test examples/plugins/business_rules/decision_audit_reporter/test/boundary_tester_test.exs
mix test examples/plugins/business_rules/decision_audit_reporter/test/audit_reporter_worker_test.exs
```

## Configuration options

| Option | Module | Description |
|--------|--------|-------------|
| `tracker_name` | `AuditSink.init/1` | Registered name for `EventTracker` |
| `collection_window_ms` | `AuditReporterWorker.start_link/1` | How long to observe before building the report (default `60_000`) |
| `sla_threshold_us` | `AuditReportBuilder.build/1` | Per-model average latency SLA (default `100_000`) |

## Extending

- **Custom boundary tests** — extend `employee_benefits_boundary_inputs/0` on the worker or load from JSON
- **SLA thresholds** — pass `:sla_threshold_us` to `AuditReportBuilder.build/1`
- **Output destinations** — pipe the report map to S3, SIEM, or a governance dashboard instead of `Logger.info`

## Further reading

- [`EvilEngine.Plugin`](../../../../apps/engine_sdk/lib/evil_engine/plugin.ex) — lifecycle callbacks
- [`EvilEngine.EngineFacade`](../../../../apps/engine_sdk/lib/evil_engine/engine_facade.ex) — facade namespace surface
- [`docs/architecture/dmn.md`](../../../../docs/architecture/dmn.md) — DMN evaluation and traces
- [`docs/architecture/plugins.md`](../../../../docs/architecture/plugins.md) — plugin loading and facade wiring
- [`examples/plugins/business_rules/dead_rule_detector/README.md`](../dead_rule_detector/README.md) — in-BEAM coverage counterpart that starts its own process instances

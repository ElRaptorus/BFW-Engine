# Decision Audit Reporter (JS gRPC Sidecar)

> **Not supported in v1 (PLUG-D1).** Sketch only — mocked SDK, no sidecar
> host. Will not load on a v1 engine. See `examples/README.md`.

Comprehensive post-execution decision audit reports from a Node.js sidecar plugin.

## What this demonstrates

- **Event streaming** — subscribe to `fni.finished` and track Business Rule Task (BRT) DMN executions
- **Facade API queries** — fetch flow node instance `type_properties` (decision ref, latency, matched rules, trace)
- **Decision evaluation** — run boundary-case inputs via `evaluateDecision` to complement runtime coverage
- **Audit report assembly** — JSON report with per-model stats, rule coverage, and compliance flags

## Architecture

```
Engine events (fni.finished)
        │
        ▼
  EventTracker ──► tracked FNI IDs
        │
        ▼
  FniInspector ──► getFlowNodeInstance (gRPC facade)
        │
        ├──► FniDetails (latency, matched rules, trace)
        │
        ▼
  BoundaryTester ──► evaluateDecision (gRPC facade)
        │
        ▼
  CoverageAnalyzer + AuditReportBuilder ──► AuditReport JSON
```

The sidecar never replaces DMN execution on the BEAM. It observes BRT completions and queries the engine facade for deeper inspection and ad-hoc evaluation — the same split as in-BEAM observability plugins.

## Forward-looking

This example is built and unit-tested against a **mocked** `SidecarPlugin` interface in `src/types.ts`. Live integration would require a gRPC sidecar host, which is **deferred post-v1** (PLUG-D1). Do not treat this example as a Phase 5/6 deliverable.

## Fixtures

| File | Purpose |
|------|---------|
| `bpmn/employee_benefits_process.bpmn` | Single BRT calling `employee-benefits` |
| `dmn/employee_benefits.dmn` | 12-rule benefits table (rules 10–12 are hard to hit) |

Identical copies of the in-BEAM `dead_rule_detector` example (8.6).

## Report format and compliance flags

The `AuditReport` JSON includes:

- **summary** — total executions, unique models, average and P95 latency (microseconds), boundary-test error rate
- **perModel** — execution count, average latency, rule coverage, boundary test results
- **compliance**
  - `allModelsEvaluated` — every per-model entry has `executionCount > 0`
  - `noDeadRulesFound` — no unmatched rule IDs in runtime coverage
  - `latencyWithinSla` — all per-model `avgLatencyUs` below `DEFAULT_SLA_THRESHOLD_US` (100_000 µs)

Set `slaThresholdUs` in `AuditReportBuilder.build()` or tune via environment when wiring production output.

## Comparison with in-BEAM `dead_rule_detector` (8.6)

| Aspect | `dead_rule_detector` (Elixir) | `decision-audit-reporter` (JS) |
|--------|------------------------------|--------------------------------|
| Runtime | In-BEAM plugin on startup | Node.js gRPC sidecar |
| Data source | `EvilEngine.Api` after process runs | Events + gRPC facade |
| Goal | Dead-rule / coverage analysis | Same goal, plus latency SLA and compliance report |
| Integration | Live today | Forward-looking (mocked SDK) |

Both use the same employee-benefits DMN fixture and intentionally omit inputs that hit rules 10, 11, and 12.

## Extending

- **Custom boundary tests** — extend `EMPLOYEE_BENEFITS_BOUNDARY_INPUTS` in `src/main.ts` or load from JSON
- **SLA thresholds** — pass `slaThresholdUs` to `AuditReportBuilder.build()`
- **Output destinations** — pipe `AuditReport` JSON to S3, SIEM, or a governance dashboard
- **Collection window** — set `COLLECTION_WINDOW_MS` when running `npm start`

## Running

From the monorepo JavaScript workspace:

```bash
cd packages/js
pnpm install
cd ../../examples/sidecar-js/decision-audit-reporter
pnpm test
pnpm start   # mocked plugin; sleeps COLLECTION_WINDOW_MS then prints report
```

## Further reading

- [`docs/architecture/plugins.md`](../../../docs/architecture/plugins.md) — plugin and sidecar patterns
- [`docs/architecture/dmn.md`](../../../docs/architecture/dmn.md) — DMN evaluation and traces
- [`examples/plugins/business_rules/dead_rule_detector/`](../../plugins/business_rules/dead_rule_detector/) — in-BEAM counterpart

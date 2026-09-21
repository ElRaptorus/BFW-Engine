# DRD Chain Orchestrator — example lifecycle plugin

Deploys a multi-decision credit-underwriting DRD with BKM reuse, runs it through a Business Rule Task, and logs the full evaluation chain from process and ad-hoc traces.

## What this demonstrates

This plugin shows how to orchestrate a **complex DRD** end-to-end via the engine facade:

1. Deploy bundled DMN and BPMN fixtures
2. Start a process instance with sample applicant data
3. Read the BRT `type_properties.trace` from the finished flow node instance
4. Run the same evaluation ad-hoc with an explicit root `decision_model_id`
5. Format both traces with `TraceInspector` and compare the decision chains

Highlights:

- **DRD chaining** — four dependent decisions evaluated in dependency order
- **BKM reuse** — `Credit Score Calculator` invoked from `Applicant Credit Score`
- **Trace inspection** — step numbers, hit policies, BKM parameter bindings, nested BKM chains
- **Facade orchestration** — `deploy`, `processes.start`, `flow_node_instances.get`, `decisions.evaluate`

## DMN model overview

`dmn/credit_underwriting.dmn` defines model id **`credit-underwriting`** with namespace `https://example.com/dmn/credit`.

| Element | Type | Role |
|---------|------|------|
| Six `inputData` nodes | External inputs | Applicant profile and loan request |
| `Credit Score Calculator` | BKM (UNIQUE table) | Reusable scoring function |
| `Applicant Credit Score` | Decision (invocation) | Invokes the BKM with bound parameters |
| `Debt-to-Income Ratio` | Decision (literal) | `existingDebt / annualIncome` |
| `Risk Assessment` | Decision (FIRST table) | Maps score + DTI to risk tier |
| `Underwriting Decision` | Decision (UNIQUE table, root) | Final approval outcome |

**Evaluation order:** inputs → BKM → Applicant Credit Score → Debt-to-Income Ratio → Risk Assessment → Underwriting Decision

Ad-hoc evaluation must pass `decision_model_id: "Decision_underwriting_decision"` because the model contains multiple decisions.

## BPMN process overview

`bpmn/credit_underwriting_process.bpmn` runs:

```
Start → BusinessRuleTask("Underwrite Application") → ExclusiveGateway("Approved?")
  → [token.approved = true] → UserTask("Prepare Offer Letter") → End("Approved")
  → [default] → ServiceTask("Send Rejection") → End("Declined")
```

- Process id: `credit-underwriting-process`
- Business Rule Task: `implementation="dmn"`, `<bfw:decisionRef>credit-underwriting</bfw:decisionRef>`
- Service Task: `implementation="notification"` with `<bfw:type>notification</bfw:type>`
- Version: `1.0.0` via `<bfw:version>`

## Trace format

`TraceInspector.format_chain/1` turns a trace map into a list of steps:

```elixir
[
  %{
    step: 1,
    decision: "Applicant Credit Score",
    hit_policy: "unique",
    result: 720,
    duration_us: 1200,
    bkm_invocations: [
      %{
        bkm_name: "Credit Score Calculator",
        parameters: [{"creditHistory", "good"}, ...],
        result: 720,
        nested_bkms: []
      }
    ],
    input_count: 2
  },
  ...
]
```

`TraceInspector.format_summary/1` produces a multi-line log-friendly summary from that list.

## Usage

1. Register `Examples.BusinessRules.DrdChainOrchestrator.DrdChainOrchestratorPlugin` in engine plugin configuration.
2. Start the engine; `on_load/1` stores the facade and `on_ready/1` starts `DrdChainOrchestratorWorker`.
3. Inspect engine logs for lines prefixed with `drd_chain_orchestrator:`.

## Tests

```bash
mix test examples/plugins/business_rules/drd_chain_orchestrator/test/trace_inspector_test.exs
mix test examples/plugins/business_rules/drd_chain_orchestrator/test/drd_chain_orchestrator_worker_test.exs
```

From the umbrella test suite (loads example sources via `apps/peripheral_plugins/test/examples/`):

```bash
mix test apps/peripheral_plugins/test/examples/drd_chain_orchestrator_from_examples_test.exs
```

## Architecture

| Module | Role |
|--------|------|
| `DrdChainOrchestratorPlugin` | `BfwEngine.Plugin` lifecycle (`on_load`, `on_ready`) |
| `FacadeStore` | Agent-backed facade stash |
| `DrdChainOrchestratorWorker` | GenServer orchestration and logging |
| `TraceInspector` | Pure trace formatting |

## Further reading

- [`docs/architecture/dmn.md`](../../../../docs/architecture/dmn.md) — DRG evaluation and BKM traces
- [`docs/guides/handbook/business-rule-tasks.md`](../../../../docs/guides/handbook/business-rule-tasks.md) — BRT execution and `type_properties`
- [`examples/plugins/business_rules/decision_audit_reporter/README.md`](../decision_audit_reporter/README.md) — similar facade worker pattern
- [`test/integration/dmn/dmn_drg_chaining_test.exs`](../../../../test/integration/dmn/dmn_drg_chaining_test.exs) — HTTP DRG chaining tests

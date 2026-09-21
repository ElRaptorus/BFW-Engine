# Business Rule Tasks

Business Rule Tasks evaluate business logic through one of two execution modes selected by the standard BPMN `implementation` attribute. They are always synchronous — the engine evaluates the rule and advances the token immediately.

## How It Works

1. The BPMN process defines a `<bpmn:businessRuleTask>` with an `implementation` attribute
2. The `implementation` value selects the execution mode: `"feel"` or `"dmn"`
3. At runtime, the engine runs the **input pipeline**: input mappers (FEEL) → payload contract (JSON Schema)
4. The engine dispatches to the selected mode:
   - `"feel"` — evaluates the inline `<bpmn:script>` body as a FEEL expression
   - `"dmn"` — resolves and evaluates a deployed DMN decision table via `bfw:decisionRef`
5. The **output pipeline** runs: output mappers (FEEL) → result contract (JSON Schema) → PayloadCap
6. The token advances to the next flow node

## Mode Selection via `implementation`

The standard BPMN `implementation` attribute serves as an explicit mode discriminator, following the same dispatch-key pattern used by Service Tasks.

| `implementation` value | Mode | Required companion | Description |
|------------------------|------|--------------------|-------------|
| `"feel"` | FEEL | `<bpmn:script>` | Evaluate an inline FEEL expression against the token |
| `"dmn"` | DMN | `bfw:decisionRef` | Evaluate a deployed DMN decision table |

The validator rejects any Business Rule Task with a missing, blank, or unrecognized `implementation` value. This includes `"plugin"`, which was removed — BRTs exclusively evaluate business rules via FEEL or DMN.

> **Note:** Plugin delegation was removed. Business Rule Tasks
> exclusively evaluate business rules via FEEL or DMN. Plugins observe
> BRT execution via engine events and analyze results through the
> facade — they never replace the execution path.

## FEEL Mode

The simplest form — write a FEEL expression directly in the `<bpmn:script>` child element:

```xml
<bpmn:businessRuleTask id="BRT_1" name="Calculate Discount" implementation="feel">
  <bpmn:script>{ discount: if token.amount > 100 then 0.1 else 0 }</bpmn:script>
</bpmn:businessRuleTask>
```

If the FEEL expression returns a scalar value (number, string, boolean), the engine wraps it in `%{"result" => value}`. If it returns a map, the map is used as-is.

This mode is functionally identical to Script Task's inline mode and shares the same FEEL evaluation path.

## DMN Mode

DMN mode resolves a deployed DMN decision table by `bfw:decisionRef` and evaluates it against the token:

```xml
<bpmn:businessRuleTask id="BRT_1" name="Discount Rules" implementation="dmn">
  <bpmn:extensionElements>
    <bfw:decisionRef>discount-rules</bfw:decisionRef>
    <bfw:decisionElementId>Decision_Discount</bfw:decisionElementId>
    <bfw:resultVariable>discountResult</bfw:resultVariable>
    <bfw:traceUnmatchedRules>true</bfw:traceUnmatchedRules>
  </bpmn:extensionElements>
</bpmn:businessRuleTask>
```

The engine resolves the latest enabled version of the DMN model, loads the parsed AST from `DMN.ModelCache`, and evaluates it in a supervised `Task` with a configurable timeout (`:dmn_evaluation_timeout_ms`, default 30 s). The full `EvaluationResult` — including hit policy, matched rules, and the structured trace — is stored in the FNI's `type_properties` for auditing and debugger consumption.

| Extension | Purpose |
|-----------|---------|
| `bfw:decisionRef` | DMN decision model ID to resolve at runtime |
| `bfw:decisionElementId` | Which `<decision>` to evaluate when the DMN model contains more than one. Omit for single-decision models |
| `bfw:resultVariable` | Wrap the DMN result under this key (optional; without it, the raw result map is the output) |
| `bfw:traceUnmatchedRules` | When `true`, include unmatched rule details in the evaluation trace |

## Data Pipeline (Mappers + Contracts)

Business Rule Tasks support the same data pipeline as Service Tasks and Script Tasks:

```xml
<bpmn:businessRuleTask id="BRT_1" name="Mapped Rule" implementation="feel">
  <bpmn:script>{ computed: token.input_value * 3 }</bpmn:script>
  <bpmn:extensionElements>
    <bfw:inputMapping source="token.raw_amount" target="input_value"/>
    <bfw:payloadContract>{"type":"object","required":["input_value"]}</bfw:payloadContract>
    <bfw:outputMapping source="token.computed" target="tripled"/>
    <bfw:resultContract>{"type":"object","required":["tripled"]}</bfw:resultContract>
  </bpmn:extensionElements>
</bpmn:businessRuleTask>
```

The full pipeline:

```
token → in_mappings (FEEL) → payload_contract (JSON Schema) → mode dispatch → out_mappings (FEEL) → result_contract (JSON Schema) → PayloadCap → downstream
```

| Extension | Purpose |
|-----------|---------|
| `bfw:inputMapping` | FEEL expression to transform input before rule evaluation |
| `bfw:payloadContract` | JSON Schema to validate the mapped input |
| `bfw:outputMapping` | FEEL expression to transform rule output |
| `bfw:resultContract` | JSON Schema to validate the mapped output |

## Error Handling

All failures in the Business Rule Task pipeline transition the FNI to `fatal`:

- **FEEL evaluation error** (corrupt script syntax) — `{:script_eval_failed, script, reason}`
- **Missing script in FEEL mode** — `{:missing_script, message}`
- **Decision not found** — `{:decision_not_found, decision_ref}`
- **Decision disabled** — `{:decision_disabled, decision_ref}`
- **Decision version not found** — `{:decision_version_not_found, decision_ref}`
- **DMN cache load failure** — `{:dmn_cache_load_failed, reason}`
- **DMN evaluation failure** — `{:dmn_evaluation_failed, error_type, metadata}`
- **DMN evaluation timeout** — `{:dmn_evaluation_timeout, %{timeout_ms: ..., decision_ref: ...}}`
- **Unrecognized implementation** — `{:unknown_brt_implementation, value}`
- **Input mapping failure** — `{:in_mapping_failed, details}`
- **Output mapping failure** — `{:out_mapping_failed, details}`
- **Contract violation** — `{:business_rule_task_contract_violation, violations}`

## Comparison with Script Task

Business Rule Tasks and Script Tasks share the FEEL evaluation engine and the data pipeline. The key differences:

| Aspect | Script Task | Business Rule Task |
|--------|-------------|-------------------|
| Mode selection | Implicit (presence of `scriptRef` vs `script`) | Explicit (`implementation` attribute) |
| Dispatch modes | 2 (inline FEEL, plugin via `scriptRef`) | 2 (FEEL, DMN) |
| DMN integration | No | Yes |
| `type_properties` | Not set | `%{mode: "feel"}` or `%{mode: "dmn", ...audit data...}` |
| Semantic intent | General-purpose computation | Business logic decisions |

## Related

- [DMN Decisions](dmn-decisions.md) — comprehensive DMN guide: authoring, deploying, evaluating, observability
- [Script Tasks](script-tasks.md) — analogous inline FEEL evaluation and plugin dispatch
- [Service Tasks](service-tasks.md) — plugin dispatch via `implementation`
- [Expressions](expressions.md) — FEEL expression language reference
- [Error Handling](error-handling.md) — fatal state transitions

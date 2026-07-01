# DMN Decisions

The engine includes a full DMN 1.5 Conformance Level 3 (CL3) decision engine.
DMN models are authored as XML, deployed to the engine via REST, and evaluated
either standalone through the API or as part of a BPMN process via Business
Rule Tasks.

## What is DMN?

DMN (Decision Model and Notation) is an OMG standard for modelling business
decisions. Where BPMN models *processes* (sequences of tasks), DMN models
*decisions* (rules that produce an output from given inputs). The two standards
complement each other: a BPMN process can invoke a DMN decision at any point
where business logic needs to be evaluated.

The engine supports DMN at Conformance Level 3 — the highest level — which
includes decision tables, all 12 boxed expression types, Decision Requirements
Diagrams (DRDs), Business Knowledge Models (BKMs), Decision Services, and
cross-model imports.

## Core Concepts

### Decision Table

The most common DMN expression type. A decision table maps combinations of
input values to output values through a set of rules:

```
┌──────────────────┬──────────────────┬──────────────────┐
│  Input: amount   │  Input: region   │  Output: rate    │
├──────────────────┼──────────────────┼──────────────────┤
│  < 1000          │  "EU"            │  0.05            │
│  < 1000          │  "US"            │  0.07            │
│  >= 1000         │  -               │  0.03            │
└──────────────────┴──────────────────┴──────────────────┘
```

Each input/output cell is a FEEL expression. Input cells are *unary tests*
(conditions evaluated against the input value); output cells are *expressions*
that produce the result. The `-` wildcard matches any input.

### Hit Policy

The hit policy determines what happens when multiple rules match:

| Policy | Symbol | Behaviour |
|--------|--------|-----------|
| UNIQUE | U | Exactly one rule must match; error on multiple matches |
| FIRST | F | First matching rule in declaration order wins |
| PRIORITY | P | Highest-priority matching rule wins (priority defined by output value order) |
| ANY | A | All matches must agree on the same output |
| COLLECT | C | Returns all matching outputs as a list; supports aggregation (sum, min, max, count) |
| RULE ORDER | R | All matching rules, returned in declaration order |
| OUTPUT ORDER | O | All matching rules, sorted by output priority |

### Literal Expression

A single FEEL expression that computes a value directly. Useful for
calculations that don't need a tabular rule structure:

```xml
<decision id="Decision_tax" name="Calculate Tax">
  <variable name="tax" typeRef="number"/>
  <literalExpression>
    <text>amount * taxRate</text>
  </literalExpression>
</decision>
```

### Business Knowledge Model (BKM)

A reusable piece of decision logic with formal parameters. BKMs are invoked
from decisions via `knowledgeRequirement` references, enabling logic reuse
across multiple decisions:

```xml
<businessKnowledgeModel id="BKM_discount" name="Discount Formula">
  <encapsulatedLogic>
    <formalParameter name="basePrice" typeRef="number"/>
    <formalParameter name="loyaltyYears" typeRef="number"/>
    <literalExpression>
      <text>if loyaltyYears > 5 then basePrice * 0.15 else basePrice * 0.05</text>
    </literalExpression>
  </encapsulatedLogic>
</businessKnowledgeModel>
```

### Decision Requirements Diagram (DRD)

A DRD defines how decisions depend on each other. When a decision references
another decision via an `informationRequirement`, the engine evaluates them
in dependency order (topological sort). This allows you to chain decisions:

```
Input Data (customer)
     ↓
Decision (Risk Score)  ←  BKM (Score Formula)
     ↓
Decision (Approval)
     ↓
Output: approved / denied
```

The engine automatically resolves the evaluation order. Circular dependencies
are rejected at deploy time.

### Decision Service

A Decision Service exposes a defined subset of a DRD as a callable unit.
It declares which decisions are *outputs* (returned to the caller) and
which are *encapsulated* (internal intermediate steps). This gives you a
clean public interface over a complex decision graph:

```xml
<decisionService id="DS_underwriting" name="Underwriting Service">
  <outputDecision href="#Decision_approval"/>
  <encapsulatedDecision href="#Decision_risk_score"/>
  <inputData href="#InputData_applicant"/>
</decisionService>
```

### Boxed Expressions (CL3)

Beyond decision tables and literal expressions, DMN 1.5 CL3 defines 10
additional boxed expression types that the engine fully supports:

| Expression | Purpose |
|------------|---------|
| Context | Ordered key-value pairs; entries can reference earlier siblings |
| Invocation | Calls a BKM's encapsulated logic with explicit parameter bindings |
| List | Ordered collection of sub-expressions |
| Relation | Tabular data (named columns, expression rows) |
| Function Definition | Reusable FEEL function (kind: `feel`) |
| Conditional | `if` / `then` / `else` branching |
| Filter | List filtering with a match predicate |
| For | Iteration with `iterator` / `in` / `return` |
| Every | Universal quantifier ("every x in list satisfies ...") |
| Some | Existential quantifier ("some x in list satisfies ...") |

All boxed expression types can be nested arbitrarily — a Context entry can
contain an Invocation, which can contain a Conditional, and so on.

## Deploying DMN Models

DMN models are deployed to the engine via the REST API, independently of
BPMN processes:

```bash
curl -X POST http://localhost:4000/decisions \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "sources": [
      { "name": "discount-rules", "xml": "<definitions>...</definitions>" }
    ]
  }'
```

The deploy pipeline:

1. **Parse** — SAX-based XML parsing produces a structured model AST
2. **Validate** — structural validation catches missing expressions, cycle detection, reference integrity, hit policy correctness
3. **Precompile** — all FEEL expressions are compiled to optimized references at deploy time (no runtime parsing)
4. **Persist** — model stored in `decision_definitions` / `decision_versions` tables
5. **Cache** — compiled model placed in the in-memory `DMN.ModelCache`

### Versioning

DMN models follow the same versioning pattern as BPMN processes:

- Each deploy creates a new `decision_version` linked to the `decision_definition`
- The engine always evaluates the **latest enabled, non-deleted version** unless a specific version is requested
- Versions can be soft-deleted (`DELETE /decisions/{id}/versions/{v}`)
- The entire definition can be disabled (`PUT /decisions/{id}/disable`) to temporarily prevent evaluation
- Disabled definitions return `{:error, :decision_disabled}` on evaluation attempts

### REST Endpoints

| Method | Path | Purpose |
|--------|------|---------|
| `POST /decisions` | Deploy one or more DMN models |
| `GET /decisions` | List all decision definitions |
| `GET /decisions/{id}` | Get a specific definition |
| `GET /decisions/{id}/versions` | List version history |
| `PUT /decisions/{id}/enable` | Enable a disabled definition |
| `PUT /decisions/{id}/disable` | Disable (prevent evaluation) |
| `DELETE /decisions/{id}` | Undeploy all versions |
| `DELETE /decisions/{id}/versions/{v}` | Soft-delete a specific version |

## Evaluating Decisions Standalone

DMN decisions can be evaluated directly via REST, outside of any BPMN process.
This is useful for testing, ad-hoc queries, or when decisions are consumed by
external systems.

### Evaluate Latest Version

```bash
curl -X POST http://localhost:4000/decisions/discount-rules/evaluate \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{ "input": { "amount": 500, "region": "EU" } }'
```

Response:

```json
{
  "result": { "rate": 0.05 },
  "trace": {
    "decisions": [{
      "decisionModelId": "Decision_rate",
      "decisionName": "Discount Rate",
      "hitPolicy": "unique",
      "matchedRules": ["Rule_1"],
      "durationMicroseconds": 42,
      "inputs": [
        { "inputId": "Input_amount", "resolvedValue": 500 },
        { "inputId": "Input_region", "resolvedValue": "EU" }
      ]
    }]
  }
}
```

### Evaluate Specific Version

```bash
curl -X POST http://localhost:4000/decisions/discount-rules/versions/2.0.0/evaluate \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{ "input": { "amount": 500, "region": "EU" } }'
```

### Evaluate Decision Service

Decision Services expose a curated subset of a DRD. Evaluate them with a
dedicated endpoint:

```bash
curl -X POST http://localhost:4000/decisions/underwriting/services/DS_underwriting/evaluate \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{ "input": { "applicant": { "income": 75000, "creditScore": 720 } } }'
```

## Using DMN with Business Rule Tasks

The most common way to use DMN is through BPMN Business Rule Tasks. The
engine evaluates the DMN model as part of the process flow and feeds the
result into the process token.

### Basic Wiring

Set `implementation="dmn"` on the Business Rule Task and reference the
deployed DMN model via `evil:decisionRef`:

```xml
<bpmn:businessRuleTask id="BRT_discount" name="Apply Discount" implementation="dmn">
  <bpmn:extensionElements>
    <evil:decisionRef>discount-rules</evil:decisionRef>
  </bpmn:extensionElements>
  <bpmn:incoming>Flow_1</bpmn:incoming>
  <bpmn:outgoing>Flow_2</bpmn:outgoing>
</bpmn:businessRuleTask>
```

At runtime:

1. The engine resolves `discount-rules` to its latest enabled version
2. Loads the compiled model from `DMN.ModelCache`
3. Evaluates the decision against the current process token
4. Merges the result into the token and advances

### Multi-Decision Models

When a DMN model contains multiple `<decision>` elements (a DRD), the engine
needs to know which decision to evaluate as the entry point. Use
`evil:decisionElementId` to select it:

```xml
<bpmn:businessRuleTask id="BRT_approval" name="Underwriting" implementation="dmn">
  <bpmn:extensionElements>
    <evil:decisionRef>credit-underwriting</evil:decisionRef>
    <evil:decisionElementId>Decision_final_approval</evil:decisionElementId>
  </bpmn:extensionElements>
</bpmn:businessRuleTask>
```

The engine evaluates the named decision and all its upstream dependencies
(per the DRD). If `evil:decisionElementId` is omitted and the model contains
exactly one decision, it auto-resolves. If it contains multiple decisions
and no element ID is specified, the FNI transitions to `fatal` with an
`{:error, :ambiguous_decision}` error.

### Result Variable Wrapping

By default, the DMN evaluation result is merged directly into the output
token. Use `evil:resultVariable` to wrap it under a specific key:

```xml
<evil:resultVariable>discountResult</evil:resultVariable>
```

| Scenario | Output token |
|----------|-------------|
| Decision table returns `%{"rate" => 0.05}`, no `resultVariable` | `%{"rate" => 0.05}` |
| Same, with `resultVariable = "discount"` | `%{"discount" => %{"rate" => 0.05}}` |
| Literal expression returns `42`, no `resultVariable` | `%{"result" => 42}` |
| Same, with `resultVariable = "answer"` | `%{"answer" => 42}` |

### Input/Output Mappers and Contracts

Business Rule Tasks support the full data pipeline — the same mappers and
contracts available on Service Tasks and Script Tasks:

```xml
<bpmn:businessRuleTask id="BRT_1" name="Mapped Decision" implementation="dmn">
  <bpmn:extensionElements>
    <evil:decisionRef>my-rules</evil:decisionRef>
    <evil:inputMapping source="token.orderData" target="order"/>
    <evil:payloadContract>{"type":"object","required":["order"]}</evil:payloadContract>
    <evil:outputMapping source="token.riskLevel" target="risk"/>
    <evil:resultContract>{"type":"object","required":["risk"]}</evil:resultContract>
  </bpmn:extensionElements>
</bpmn:businessRuleTask>
```

The pipeline runs in this order:

```
token → in_mappings (FEEL) → payload_contract (JSON Schema) → DMN evaluation → out_mappings (FEEL) → result_contract (JSON Schema) → PayloadCap → downstream
```

### Unmatched Rule Tracing

Enable `evil:traceUnmatchedRules` to include details about rules that
did *not* match in the evaluation trace. This is valuable for debugging
decision logic and detecting dead rules:

```xml
<evil:traceUnmatchedRules>true</evil:traceUnmatchedRules>
```

## Evaluation Trace and Observability

Every DMN evaluation — whether standalone or via a Business Rule Task —
produces a structured `EvaluationTrace` containing full audit data:

| Field | Description |
|-------|-------------|
| `decisions` | List of per-decision traces (one per DRD node evaluated) |
| `hit_policy` | Which hit policy was applied |
| `matched_rules` | IDs of rules that fired |
| `inputs` | Resolved input values with their expression IDs |
| `duration_microseconds` | Wall-clock evaluation time |
| `bkm_traces` | Invocation traces for any BKMs called during evaluation |
| `import_traces` | Traces from cross-model import evaluations |
| `input_coercions` | Records of any type coercions applied to inputs |
| `warnings` | Output type validation warnings (e.g. type mismatches) |

### BRT Audit Data (`type_properties`)

When a Business Rule Task evaluates a DMN model, the full trace is stored
in the Flow Node Instance's `type_properties` field:

```json
{
  "mode": "dmn",
  "decision_ref": "discount-rules",
  "decision_element_id": "Decision_rate",
  "decision_version_id": "550e8400-...",
  "definitions_id": "definitions_discount",
  "definitions_namespace": "https://example.com/dmn/discount",
  "version": "1.0.0",
  "hit_policy": "unique",
  "matched_rules": ["Rule_2"],
  "trace": { "decisions": [...] },
  "duration_us": 1234
}
```

This data is available through the GraphQL API on `FlowNodeInstance.typeProperties`
and through `FlowNodeInstanceFinished` engine events, enabling plugins and
external systems to analyze decision execution after the fact.

### Telemetry Events

The engine emits `:telemetry` events for DMN operations:

| Event | Measurements | Metadata |
|-------|-------------|----------|
| `[:evil_engine, :dmn, :evaluation, :stop]` | `duration` (native time) | `decision_model_id`, `hit_policy`, `matched_rule_count` |
| `[:evil_engine, :dmn, :deploy, :stop]` | `duration` | `model_id`, `version`, `decision_count` |

These events feed into the Prometheus `/metrics` endpoint when enabled.

## Plugin Observation

Plugins do not execute DMN decisions — that is exclusively the engine's
responsibility. Instead, plugins observe and analyze decision execution
through two channels:

1. **Event Sinks** — register an `EventSink` that filters for
   `FlowNodeInstanceFinished` events where `flow_node_type == :business_rule_task`.
   The event's `type_properties` carries the full evaluation trace.

2. **Facade Closures** — use `facade.decisions.*` to list definitions,
   retrieve XML, evaluate ad-hoc, or inspect version history for post-execution
   analysis.

See [Plugin Development](../plugins/getting-started.md) for how to build
observation plugins, and the `examples/plugins/business_rules/` directory
in the engine repository for 8 working Elixir examples covering decision
trace publishing, regression testing, dead rule detection, and more.

## Error Handling

All DMN-related failures in a Business Rule Task transition the FNI to `fatal`:

| Error | Cause |
|-------|-------|
| `{:decision_not_found, ref}` | `evil:decisionRef` does not match any deployed definition |
| `{:decision_disabled, ref}` | The definition exists but is disabled |
| `{:decision_version_not_found, ref}` | No active (non-deleted) version available |
| `{:dmn_cache_load_failed, reason}` | Model cache could not load the compiled model |
| `{:dmn_evaluation_failed, type, meta}` | FEEL evaluation error during rule matching |
| `{:dmn_evaluation_timeout, meta}` | Evaluation exceeded the configured timeout (default 30s) |
| `{:error, :ambiguous_decision}` | Multi-decision model without `evil:decisionElementId` |

Standalone REST evaluation returns structured error responses with the same
error types as HTTP 422 bodies.

## Configuration

| Environment variable / config key | Default | Purpose |
|----------------------------------|---------|---------|
| `:core_dmn, :max_import_depth` | `10` | Maximum depth for cross-model import chains |
| `:core_execution, :dmn_evaluation_timeout_ms` | `30_000` | Timeout for DMN evaluation in BRT context |

## Complete Example

A minimal end-to-end example: deploy a DMN model, then use it from a BPMN
process.

### 1. The DMN Model (`discount-rules.dmn`)

```xml
<?xml version="1.0" encoding="UTF-8"?>
<definitions xmlns="https://www.omg.org/spec/DMN/20191111/MODEL/"
             id="definitions_discount"
             name="Discount Rules"
             namespace="https://example.com/dmn/discount">

  <inputData id="InputData_amount" name="amount"/>
  <inputData id="InputData_region" name="region"/>

  <decision id="Decision_rate" name="Discount Rate">
    <variable name="rate" typeRef="number"/>
    <informationRequirement>
      <requiredInput href="#InputData_amount"/>
    </informationRequirement>
    <informationRequirement>
      <requiredInput href="#InputData_region"/>
    </informationRequirement>
    <decisionTable id="DT_rate" hitPolicy="UNIQUE">
      <input id="Input_amount">
        <inputExpression typeRef="number"><text>amount</text></inputExpression>
      </input>
      <input id="Input_region">
        <inputExpression typeRef="string"><text>region</text></inputExpression>
      </input>
      <output id="Output_rate" name="rate" typeRef="number"/>
      <rule id="Rule_1">
        <inputEntry><text>&lt; 1000</text></inputEntry>
        <inputEntry><text>"EU"</text></inputEntry>
        <outputEntry><text>0.05</text></outputEntry>
      </rule>
      <rule id="Rule_2">
        <inputEntry><text>&lt; 1000</text></inputEntry>
        <inputEntry><text>"US"</text></inputEntry>
        <outputEntry><text>0.07</text></outputEntry>
      </rule>
      <rule id="Rule_3">
        <inputEntry><text>&gt;= 1000</text></inputEntry>
        <inputEntry><text>-</text></inputEntry>
        <outputEntry><text>0.03</text></outputEntry>
      </rule>
    </decisionTable>
  </decision>
</definitions>
```

### 2. The BPMN Process

```xml
<bpmn:process id="order-discount" name="Apply Order Discount" isExecutable="true">
  <bpmn:extensionElements>
    <evil:version>1.0.0</evil:version>
  </bpmn:extensionElements>

  <bpmn:startEvent id="Start_1">
    <bpmn:outgoing>Flow_1</bpmn:outgoing>
  </bpmn:startEvent>

  <bpmn:businessRuleTask id="BRT_discount" name="Calculate Discount"
                         implementation="dmn">
    <bpmn:extensionElements>
      <evil:decisionRef>discount-rules</evil:decisionRef>
    </bpmn:extensionElements>
    <bpmn:incoming>Flow_1</bpmn:incoming>
    <bpmn:outgoing>Flow_2</bpmn:outgoing>
  </bpmn:businessRuleTask>

  <bpmn:endEvent id="End_1">
    <bpmn:incoming>Flow_2</bpmn:incoming>
  </bpmn:endEvent>

  <bpmn:sequenceFlow id="Flow_1" sourceRef="Start_1" targetRef="BRT_discount"/>
  <bpmn:sequenceFlow id="Flow_2" sourceRef="BRT_discount" targetRef="End_1"/>
</bpmn:process>
```

### 3. Deploy and Run

```bash
# Deploy the DMN model
curl -X POST http://localhost:4000/decisions \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{ "sources": [{ "name": "discount-rules", "xml": "..." }] }'

# Deploy the BPMN process
curl -X POST http://localhost:4000/processes \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{ "sources": [{ "name": "order-discount", "xml": "..." }] }'

# Start a process instance — the BRT evaluates the DMN automatically
curl -X POST http://localhost:4000/processes/order-discount/start \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{ "payload": { "amount": 500, "region": "EU" } }'
```

The process instance finishes with `{ "rate": 0.05 }` merged into the token.

## Related

- [Business Rule Tasks](business-rule-tasks.md) — BRT modes, data pipeline, error handling
- [Expressions](expressions.md) — FEEL expression language reference
- [Deploying Processes](deploying-processes.md) — BPMN deployment (DMN follows the same pattern)
- [Error Handling](error-handling.md) — fatal state transitions
- [Plugin Development](../plugins/getting-started.md) — building observation plugins

# Exclusive Gateways

Exclusive Gateways route a process along exactly one of several paths based on FEEL conditions. They are the primary mechanism for conditional branching in BPMN processes.

## Split (Diverging)

A split gateway has one incoming and multiple outgoing sequence flows. Each outgoing flow can carry a `conditionExpression` written in [FEEL](expressions.md). The engine evaluates all conditions and enforces **exactly-one-truthy** semantics:

| Outcome | Behavior |
|---------|----------|
| Unmarked non-default outgoing flow (no `conditionExpression`, not `default`) | **Runtime fatal** (`exclusive_gateway_unconditional_flow`) **before** FEEL on a split (`outgoing > 1`). A **single** unmarked outgoing is pass-through. The diagram still deploys. Studio lints warning (`bpmn-development`) / error (`bpmn-production-ready`). |
| Single outgoing with a condition that is `false` and no default | PI transitions to `fatal` (`no_matching_condition`) — the condition is still evaluated |
| Exactly one condition is `true` | That path is taken |
| Zero conditions are `true`, default flow exists | Default flow is taken |
| Zero conditions are `true`, no default flow | PI transitions to `fatal` (`no_matching_condition`) |
| Multiple conditions are `true` | PI transitions to `fatal` (`ambiguous_condition`) |
| Any expression evaluation fails | PI transitions to `fatal` (`expression_evaluation_failed`) |

This is a **deliberate divergence** from the BPMN 2.0 specification's "first truthy wins" rule. Strict enforcement prevents ambiguous, non-deterministic routing.

### BPMN Example

```xml
<bpmn:exclusiveGateway id="Gateway_1" name="Check Amount" default="Flow_Default">
  <bpmn:incoming>Flow_In</bpmn:incoming>
  <bpmn:outgoing>Flow_High</bpmn:outgoing>
  <bpmn:outgoing>Flow_Low</bpmn:outgoing>
  <bpmn:outgoing>Flow_Default</bpmn:outgoing>
</bpmn:exclusiveGateway>

<bpmn:sequenceFlow id="Flow_High" sourceRef="Gateway_1" targetRef="Task_High">
  <bpmn:conditionExpression xsi:type="bpmn:tFormalExpression">
    token.amount > 1000
  </bpmn:conditionExpression>
</bpmn:sequenceFlow>

<bpmn:sequenceFlow id="Flow_Low" sourceRef="Gateway_1" targetRef="Task_Low">
  <bpmn:conditionExpression xsi:type="bpmn:tFormalExpression">
    token.amount <= 1000
  </bpmn:conditionExpression>
</bpmn:sequenceFlow>

<!-- Default flow: referenced by the gateway's default attribute; no conditionExpression -->
<bpmn:sequenceFlow id="Flow_Default" sourceRef="Gateway_1" targetRef="Task_Fallback" />
```

### Expression Context

Conditions are evaluated against the standard [FEEL context](expressions.md), including `token`, `identity`, `dataObjects`, `process`, and `processInstance` bindings. Common patterns:

```
token.amount > 1000
token.status = "approved" and token.priority > 5
identity.roles contains "manager"
```

### Default Flow

A default flow is taken when no conditional flow evaluates to `true`. Mark it with the standard BPMN `default="Flow_…"` attribute on the gateway. It must not carry a `conditionExpression`. If no default flow is defined and no condition matches, the PI transitions to `fatal`.

## Join (Converging)

A join gateway has multiple incoming and one outgoing sequence flow. It acts as a pure **pass-through** — the first arriving token is immediately forwarded to the outgoing flow. No synchronization or merging occurs.

## Mixed Gateways

Gateways with both multiple incoming and multiple outgoing flows are **rejected at runtime** with a `mixed_gateway` error. Use separate gateway nodes for splitting and joining.

## Error States

| Error | Cause | PI State |
|-------|-------|----------|
| `no_matching_condition` | No outgoing condition evaluates to `true` and no default flow exists | `fatal` |
| `ambiguous_condition` | Multiple outgoing conditions evaluate to `true` | `fatal` |
| `expression_evaluation_failed` | A FEEL expression on an outgoing flow fails to evaluate | `fatal` |
| `mixed_gateway` | Gateway has both >1 incoming and >1 outgoing flows | `fatal` |

## Related

- [FEEL Expressions](expressions.md) -- expression syntax and context bindings
- [Error Handling](error-handling.md) -- fatal states and encounter-time validation
- [Deploying Processes](deploying-processes.md) -- deploy processes with gateways

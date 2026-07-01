# Inclusive Gateways

Inclusive Gateways (OR-Gateways) route a process along **one or more** paths based on FEEL conditions. Unlike Exclusive Gateways (exactly one path) and Parallel Gateways (all paths unconditionally), Inclusive Gateways activate every outgoing path whose condition is truthy — a hybrid of both.

## OR-Split (Diverging)

A split gateway has one incoming and multiple outgoing sequence flows. The engine evaluates **all** conditional flows and activates every path whose condition is `true`:

| Outcome | Behavior |
|---------|----------|
| 1+ conditions are `true` | All truthy paths are taken (tokens forked), plus any unconditional non-default flows |
| Zero conditions are `true`, default flow exists | Default flow only (unconditional flows are suppressed) |
| Zero conditions are `true`, no default flow | PI transitions to `fatal` (`no_matching_condition`) |
| Any expression evaluation fails | PI transitions to `fatal` (`expression_evaluation_failed`) |

### Key Differences from Exclusive and Parallel

| Aspect | Exclusive | Inclusive | Parallel |
|--------|-----------|-----------|----------|
| Conditions evaluated | All, exactly one must be true | All, any number can be true | None (always all) |
| Paths activated | Exactly one | All truthy + unconditional | All unconditionally |
| Default flow | Fallback when zero truthy | Fallback when zero truthy | N/A |
| Multiple truthy | Fatal (`ambiguous_condition`) | Expected behavior | N/A |

### Unconditional Flows

Outgoing flows without a `conditionExpression` that are not the default are treated as **unconditional** — they are always activated alongside any truthy conditional flows. When zero conditions are truthy and a default flow exists, unconditional flows are suppressed (only the default is taken).

### BPMN Example

```xml
<bpmn:inclusiveGateway id="Gateway_1" name="Process Order" default="Flow_Default">
  <bpmn:incoming>Flow_In</bpmn:incoming>
  <bpmn:outgoing>Flow_Ship</bpmn:outgoing>
  <bpmn:outgoing>Flow_Invoice</bpmn:outgoing>
  <bpmn:outgoing>Flow_Default</bpmn:outgoing>
</bpmn:inclusiveGateway>

<bpmn:sequenceFlow id="Flow_Ship" sourceRef="Gateway_1" targetRef="Task_Ship">
  <bpmn:conditionExpression>token.requiresShipping = true</bpmn:conditionExpression>
</bpmn:sequenceFlow>

<bpmn:sequenceFlow id="Flow_Invoice" sourceRef="Gateway_1" targetRef="Task_Invoice">
  <bpmn:conditionExpression>token.requiresInvoice = true</bpmn:conditionExpression>
</bpmn:sequenceFlow>

<bpmn:sequenceFlow id="Flow_Default" sourceRef="Gateway_1" targetRef="Task_Log" />
```

If `requiresShipping` and `requiresInvoice` are both `true`, both `Task_Ship` and `Task_Invoice` execute in parallel. If neither is truthy, `Task_Log` runs as a fallback.

## OR-Join (Converging)

An OR-join waits for tokens from all incoming paths that **could still deliver a token**. Paths that are "dead" (no active flow node instance can reach them) are excluded from the wait set.

### Dead-Path Elimination

For each incoming sequence flow of the join, the engine classifies it as:

| Status | Meaning |
|--------|---------|
| **Arrived** | A token has been delivered via this flow |
| **Waiting** | No token yet, but at least one active or waiting FNI exists upstream that could produce one |
| **Dead** | No token, and no active/waiting FNI can reach this flow — will never arrive |

The join fires when all incoming flows are either **arrived** or **dead**, and at least one flow is **arrived**. The arrived tokens are merged using "last-wins per key" (`Map.merge/2`), identical to Parallel Gateway.

### Deploy-Time Analysis

At deploy time, the engine computes a **backward reachability set** for each incoming flow of every inclusive join. This pre-computation turns the runtime dead-path check into an efficient set intersection instead of a graph traversal. The analysis is re-computed each time the process model is loaded (not persisted in the database).

### When Does Re-Evaluation Happen?

The engine re-evaluates all parked inclusive joins **after every FNI state change** (not just on token arrival). This ensures that when a branch reaches an End Event or goes fatal/aborted/interrupted, the join detects that the branch is now "dead" and fires with the tokens that have already arrived.

### Distinction from Parallel Join

| Aspect | Parallel Join | Inclusive Join |
|--------|---------------|----------------|
| Required tokens | Static = incoming flow count | Dynamic = number of live upstream paths |
| Branch reaches End Event | Join waits forever (structural error) | Dead-path elimination detects it; join fires normally |
| `required` count on resume | Static, from incoming flow count | Re-computed via dead-path elimination |

## Token Merge at Join

When the inclusive join fires, all arrived branch payloads are merged using "last-wins per key" — identical to Parallel Gateway. If branches produce overlapping keys, the value from the branch that arrived last wins.

```
Branch A token: { "orderId": "123", "shipped": true }
Branch B token: { "orderId": "123", "invoiced": true }
→ Merged:       { "orderId": "123", "shipped": true, "invoiced": true }
```

If both branches set the same key to different values, the last arrival wins.

## Mixed Gateways

Gateways with both multiple incoming and multiple outgoing flows are **rejected at runtime** with a `mixed_gateway` error. Use separate gateway nodes for splitting and joining.

## Retry

Inclusive join FNIs are **invalid retry checkpoints** — retrying with an inclusive join as the reset target returns HTTP 422 (`retry_checkpoint_is_join_gateway`). Retry from an upstream task or the process start instead.

## Error States

| Error | Cause | PI State |
|-------|-------|----------|
| `no_matching_condition` | No outgoing condition evaluates to `true` and no default flow exists | `fatal` |
| `expression_evaluation_failed` | A FEEL expression on an outgoing flow fails to evaluate | `fatal` |
| `mixed_gateway` | Gateway has both >1 incoming and >1 outgoing flows | `fatal` |
| `duplicate_join_arrival` | A token arrives at the join via an incoming flow that already delivered a token | `fatal` |

## Related

- [Exclusive Gateways](exclusive-gateways.md) -- exactly-one-path routing
- [FEEL Expressions](expressions.md) -- expression syntax and context bindings
- [Error Handling](error-handling.md) -- fatal states and encounter-time validation
- [Deploying Processes](deploying-processes.md) -- deploy processes with gateways

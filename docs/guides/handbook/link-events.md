# Link Events

Link Events provide an intra-process GOTO mechanism. A Link Throw Event transfers the token to a matching Link Catch Event within the same process scope, effectively jumping over intermediate flow nodes without requiring explicit sequence flows.

## How It Works

1. A Link Throw Event fires and resolves the matching Link Catch Event by `name`
2. The engine verifies exactly one Catch Event shares the same link name within the process
3. The token is routed directly to the Link Catch Event (the Throw FNI finishes)
4. The Link Catch Event acts as a landing pad — it continues via its outgoing sequence flows

Link Events are always **intermediate** (never Start or End Events). The pair functions like a labeled GOTO: the Throw is the jump source, the Catch is the destination.

## BPMN Configuration

```xml
<!-- Link Throw — sends the token to "approval-stage" -->
<bpmn:intermediateThrowEvent id="LinkThrow_1" name="Jump to Approval">
  <bpmn:linkEventDefinition name="approval-stage" />
  <bpmn:incoming>Flow_BeforeJump</bpmn:incoming>
</bpmn:intermediateThrowEvent>

<!-- Link Catch — receives the token from "approval-stage" -->
<bpmn:intermediateCatchEvent id="LinkCatch_1" name="Approval Landing">
  <bpmn:linkEventDefinition name="approval-stage" />
  <bpmn:outgoing>Flow_AfterLanding</bpmn:outgoing>
</bpmn:intermediateCatchEvent>
```

The link name (`approval-stage` in this example) must match exactly between the Throw and Catch. The Throw has no outgoing sequence flows; the Catch has no incoming sequence flows. Both are exempt from the engine's orphan-node validation for this reason.

## Multi-Pair Support

A process can contain multiple independent link pairs, each with a distinct name:

```xml
<bpmn:intermediateThrowEvent id="LT_A">
  <bpmn:linkEventDefinition name="stage-a" />
  <bpmn:incoming>Flow_1</bpmn:incoming>
</bpmn:intermediateThrowEvent>

<bpmn:intermediateCatchEvent id="LC_A">
  <bpmn:linkEventDefinition name="stage-a" />
  <bpmn:outgoing>Flow_2</bpmn:outgoing>
</bpmn:intermediateCatchEvent>

<bpmn:intermediateThrowEvent id="LT_B">
  <bpmn:linkEventDefinition name="stage-b" />
  <bpmn:incoming>Flow_3</bpmn:incoming>
</bpmn:intermediateThrowEvent>

<bpmn:intermediateCatchEvent id="LC_B">
  <bpmn:linkEventDefinition name="stage-b" />
  <bpmn:outgoing>Flow_4</bpmn:outgoing>
</bpmn:intermediateCatchEvent>
```

Each pair resolves independently. Multiple Throw Events can target the same Catch Event (fan-in), but there must be exactly one Catch per link name.

## Error Handling

Link pair consistency is validated at runtime, not at deploy time. This allows work-in-progress BPMN diagrams to be deployed successfully while the Studio linter catches pairing issues at design time.

| Condition | Result |
|-----------|--------|
| Exactly one matching Catch for the link name | Token routed successfully |
| No matching Catch (orphan throw) | FNI transitions to `fatal` |
| Multiple Catches with the same link name | FNI transitions to `fatal` |

## Use Cases

Link Events are useful when:

- **Simplifying complex diagrams** — replace long, winding sequence flows with named jumps
- **Implementing retry loops** — a Throw at the end of an error-handling path jumps back to a Catch before the retryable step
- **Page breaks** — in large diagrams, Link Events visually connect flow across diagram pages

## Scope Rules

Link pairs must reside in the **same process scope**. A Link Throw inside a subprocess cannot target a Link Catch in the parent process, and vice versa. Cross-process jumps require Call Activities or message-based communication.

## Related

- [Error Handling](error-handling.md) -- fatal transitions from broken link pairs
- [Exclusive Gateways](exclusive-gateways.md) -- conditional branching as an alternative to link jumps
- [Call Activities](call-activities.md) -- cross-process invocation

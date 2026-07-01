# Call Activities

Call Activities invoke another BPMN process as a child, creating a separate Process Instance (PI) with its own lifecycle. The parent PI waits until the child completes, then continues with the child's result. This guide covers configuration, data mapping, error handling, and resume behavior.

## How It Works

1. The parent PI encounters a Call Activity and resolves the referenced process to its latest deployed version
2. Input mappings (if configured) transform the parent's token payload into the child's start payload
3. A new child PI is spawned and linked to the parent
4. The parent's Call Activity FNI enters `waiting` state while the child runs
5. When the child finishes, output mappings (if configured) transform the child's result before returning it to the parent
6. The parent PI continues along the Call Activity's outgoing sequence flow

## BPMN Configuration

```xml
<bpmn:callActivity id="CA_1" name="Process Order" calledElement="OrderSubProcess">
  <bpmn:extensionElements>
    <evil:inputMapping source="token.orderId" target="order_id" />
    <evil:inputMapping source="token.customer" target="customer_info" />
    <evil:outputMapping source="token.result" target="order_result" />
  </bpmn:extensionElements>
  <bpmn:incoming>Flow_In</bpmn:incoming>
  <bpmn:outgoing>Flow_Out</bpmn:outgoing>
</bpmn:callActivity>
```

| Extension Element | Purpose |
|-------------------|---------|
| `calledElement` (attribute) | Process key of the child process to invoke |
| `evil:inputMapping` | FEEL expression mapping parent token fields to child start payload |
| `evil:outputMapping` | FEEL expression mapping child result fields back to parent token |

## Input Mappings

Input mappings use [FEEL expressions](expressions.md) to build the child's start payload from the parent's current token. Each mapping has a `source` (FEEL expression) and a `target` (output field name).

```xml
<evil:inputMapping source="token.orderId" target="order_id" />
<evil:inputMapping source="token.amount * 1.1" target="total_with_tax" />
```

The expression is evaluated against the parent PI's full [FEEL context](expressions.md) (including `token`, `identity`, `dataObjects`, etc.). If any mapping expression fails to evaluate, the parent PI transitions to `fatal` without spawning a child.

When no input mappings are configured, the parent's full token payload is passed to the child unchanged.

## Output Mappings

Output mappings transform the child PI's aggregated result before it flows back to the parent. The child's result is built by merging payloads from all End Events the child reached (FinalToken aggregation).

```xml
<evil:outputMapping source="token.result" target="order_result" />
<evil:outputMapping source="token.status" target="child_status" />
```

The expression is evaluated against a FEEL context where `token` is the child's aggregated result payload. If any output mapping expression fails, the parent PI transitions to `fatal`.

When no output mappings are configured, the child's aggregated result is returned to the parent unchanged.

## Child PI Lifecycle

The child PI is a fully independent Process Instance with its own ID, state machine, FNI tree, and persistence. Key relationships:

| Property | Description |
|----------|-------------|
| `parent_process_instance_id` | Set on the child PI, pointing back to the parent |
| `triggerer_flow_node_instance_id` | Set on the child PI, pointing to the parent's Call Activity FNI |
| `child_process_instance_id` | Stored in the Call Activity FNI's `type_properties`, pointing to the child |

This bidirectional linkage allows auditing the parent-child relationship from either direction.

### Events

When a child PI is spawned, the engine emits:

| Event | Channel | Content |
|-------|---------|---------|
| `CallActivityChildStarted` | `EngineEventBus` | `call_activity_flow_node_instance_id`, `parent_process_instance_id`, `child_process_instance_id`, `child_process_version_id`, `occurred_at` |
| Telemetry `[:evil_engine, :call_activity, :child_started]` | `:telemetry` | Same fields as the struct |

Additionally, `ProcessInstanceStateChanged` events for child PIs include the `parent_process_instance_id` field, and `FniStateChanged` events include the `process_instance_id` field.

## Error Handling

When a child PI transitions to `fatal`, the Call Activity checks for attached [Error Boundary Events](error-boundary-events.md):

| Scenario | Behavior |
|----------|----------|
| Child fatals, matching boundary exists | Parent routes through the boundary's outgoing flows (parent finishes normally) |
| Child fatals, no matching boundary | Parent PI transitions to `fatal` |
| Child crashes (OTP process death) | Treated as `CHILD_CRASH` error, checked against boundaries |
| Called element cannot be resolved | Parent PI transitions to `fatal` (no child spawned) |
| Input mapping FEEL expression fails | Parent PI transitions to `fatal` (no child spawned) |
| Output mapping FEEL expression fails | Parent PI transitions to `fatal` (child completed, but result mapping failed) |

### Error Codes

| Error Code | Meaning |
|-----------|---------|
| `CHILD_FATAL` | Child PI went fatal (generic, no specific error code from the child) |
| `CHILD_CRASH` | Child process crashed at the OTP level |
| `CHILD_START_FAILED` | Child PI could not be started |
| *(handler-specific)* | If the child's error carries its own `error_code`, it is forwarded as-is |

## Resume on Restart

Call Activities support full resume-on-restart. When the engine restarts and resumes a parent PI with a waiting Call Activity FNI, the handler checks the child PI's state:

| Child State | Resume Behavior |
|-------------|----------------|
| Still running (in Registry) | Parent re-monitors the running child and waits for completion |
| No longer running | Parent spawns a new child PI and runs the full lifecycle from scratch |
| No `child_process_instance_id` recorded | Parent spawns a new child PI (treated as if no child was ever started) |

## Version Resolution

The `calledElement` attribute specifies the process key (not a version). The engine resolves to the **latest non-deleted, enabled version** of the referenced process at the time the Call Activity executes. This means:

- Deploying a new version of the child process affects future Call Activity executions
- Already-running child PIs are not affected by new deployments
- If the referenced process is disabled or undeployed, the Call Activity fails with a resolution error

## Related

- [Error Boundary Events](error-boundary-events.md) -- catching child PI errors
- [FEEL Expressions](expressions.md) -- input/output mapping expressions
- [Error Handling](error-handling.md) -- fatal states and error propagation
- [Deploying Processes](deploying-processes.md) -- deploy the child process before invoking it
- [Monitoring](monitoring.md) -- observing child PI lifecycle events

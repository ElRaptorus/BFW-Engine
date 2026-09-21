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
    <bfw:startEventId>Start_Express</bfw:startEventId>
    <bfw:inputMapping source="token.orderId" target="order_id" />
    <bfw:inputMapping source="token.customer" target="customer_info" />
    <bfw:outputMapping source="token.result" target="order_result" />
    <bfw:payloadContract>{"type":"object","required":["order_id"]}</bfw:payloadContract>
    <bfw:resultContract>{"type":"object","required":["order_result"]}</bfw:resultContract>
  </bpmn:extensionElements>
  <bpmn:incoming>Flow_In</bpmn:incoming>
  <bpmn:outgoing>Flow_Out</bpmn:outgoing>
</bpmn:callActivity>
```

| Extension Element | Purpose |
|-------------------|---------|
| `calledElement` (attribute) | Process key of the child process to invoke |
| `bfw:startEventId` | Child Start Event to enter. Required when the child has multiple untyped starts; optional when it has exactly one |
| `bfw:inputMapping` | FEEL expression mapping parent token fields to child start payload |
| `bfw:outputMapping` | FEEL expression mapping child result fields back to parent token |
| `bfw:payloadContract` | JSON Schema on the child's start payload (after input mapping). Violation is fatal to the Call Activity FNI |
| `bfw:resultContract` | JSON Schema on the child's aggregated result (after output mapping). Violation is fatal to the Call Activity FNI |

`bfw:startEventId` selects which Start Event the child begins at. Required when the child has multiple untyped Start Events; optional when it has exactly one. If the ID is missing from the child model the Call Activity fatals with `start_event_not_found`. If the child has multiple untyped starts and this extension is omitted, the engine returns `ambiguous_start_event`.

## Input Mappings

Input mappings use [FEEL expressions](expressions.md) to build the child's start payload from the parent's current token. Each mapping has a `source` (FEEL expression) and a `target` (output field name).

```xml
<bfw:inputMapping source="token.orderId" target="order_id" />
<bfw:inputMapping source="token.amount * 1.1" target="total_with_tax" />
```

The expression is evaluated against the parent PI's full [FEEL context](expressions.md) (including `token`, `identity`, `dataObjects`, etc.). If any mapping expression fails to evaluate, the parent PI transitions to `fatal` without spawning a child.

When no input mappings are configured, the parent's full token payload is passed to the child unchanged.

## Output Mappings

Output mappings transform the child PI's aggregated result before it flows back to the parent. The child's result is built by merging payloads from all End Events the child reached (FinalToken aggregation).

```xml
<bfw:outputMapping source="token.result" target="order_result" />
<bfw:outputMapping source="token.status" target="child_status" />
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
| Telemetry `[:bfw_engine, :call_activity, :child_started]` | `:telemetry` | Same fields as the struct |

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

The `calledElement` attribute is the process key (not a version). Optional `<bfw:calledProcessVersion>` pins the child to that process's `<bfw:version>` string.

| Pin | What the engine does at enter time |
|-----|-------------------------------------|
| Omitted or blank | Latest **enabled**, non-deleted catalog version — newest `deployed_at`, not semver order |
| Set to a version string | Exact `bfw:version` match. Missing / soft-deleted → Call Activity fatals (`called_process_version_not_found`). Catalog process disabled → `version_disabled` (this atom is **not** rewritten to `process_not_found`) |
| Set to the word `latest` | Looks up a version **actually named** `latest`. That is not a keyword. Retry's JSON `"version": "latest"` *is* a keyword; this field is not. Leave the property empty for dynamic latest. |

Resolution happens when the Call Activity **enters** (or re-enters after the child tree was deleted). The spawned child PI stores `process_version_id` (UUID). Resume reconnects that UUID. Multi-instance iterations each resolve independently: unpinned iterations can straddle a child deploy; a pin keeps every iteration on the same child version. Nested Call Activities resolve independently; a parent pin does not constrain grandchildren.

**Retrying at the Call Activity does not change the child diagram.** Checkpoint **at** the Call Activity (or no checkpoint / checkpoint after it) keeps the **same child process instance** and `process_version_id`. If that child is `fatal` / `aborted` / `error`, retry **resets it in place**. A `finished` child is left as-is. To spawn a **new** child instance (new pin, or unpinned latest after a child deploy), checkpoint an FNI **before** the Call Activity so the Call Activity and child tree are hard-deleted — that **re-runs preceding parent work**. See [retry.md](retry.md) Process Instance Tree, including the known limitation for picking a new child version without duplicating parent work.

- Deploying a new version of the child process affects future **enters** of unpinned Call Activities
- Already-running (and identity-preserved) child PIs are not affected by new deployments or by a changed pin on a surviving Call Activity
- If the referenced process is disabled or undeployed, an unpinned Call Activity fails with `process_not_found`; a pinned one fails with `version_disabled` when the catalog row exists but is disabled

## Related

- [Error Boundary Events](error-boundary-events.md) -- catching child PI errors
- [FEEL Expressions](expressions.md) -- input/output mapping expressions
- [Error Handling](error-handling.md) -- fatal states and error propagation
- [Deploying Processes](deploying-processes.md) -- deploy the child process before invoking it
- [Monitoring](monitoring.md) -- observing child PI lifecycle events

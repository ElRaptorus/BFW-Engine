# Process Instance Retry

The engine retries process instances that have failed (`fatal`), been aborted (`aborted`), or terminated via an Error End Event (`error`). There is **one** command: `PUT /process-instances/{id}/retry`. There is no separate restart endpoint. Omitting a checkpoint retries from the Start Event on the same call.

`:compensated`, `:escalated`, and `:cancelled` are terminal-but-handled business outcomes and are **not** retryable (`process_instance_not_retriable`).

## How It Works

1. A PI reaches `fatal`, `aborted`, or `error` state
2. An operator (or plugin) sends `PUT /process-instances/{id}/retry` with optional parameters
3. The engine validates the request (PI state, version compatibility, checkpoint restrictions, authorization)
4. The PI is reset according to the specified strategy and resumes execution

## REST API

```bash
# Retry from the Start Event (same version)
curl -X PUT http://localhost:4000/process-instances/$PI_ID/retry \
  -H "Authorization: Bearer $TOKEN"

# Retry with version migration (evil:version string or "latest")
curl -X PUT http://localhost:4000/process-instances/$PI_ID/retry \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"version": "2.0.0"}'

# Retry from a specific checkpoint
curl -X PUT http://localhost:4000/process-instances/$PI_ID/retry \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"resetToFlowNodeInstanceId": "fni-uuid"}'

# Retry with both version migration and checkpoint
curl -X PUT http://localhost:4000/process-instances/$PI_ID/retry \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"version": "latest", "resetToFlowNodeInstanceId": "fni-uuid"}'
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `version` | string | Target **`evil:version`** to migrate to. Use `"latest"` to auto-resolve to the most recent enabled, non-deleted version. Omit to retry on the same version. |
| `resetToFlowNodeInstanceId` | string | Checkpoint FNI ID. All FNIs causally downstream of this FNI are deleted, and this FNI is reset to `active`. Omit to retry from the Start Event. |

Plugins: `facade.process_instances.retry.(id, opts)` with `skip_claims: true`.

### Response Codes

| Code | Meaning |
|------|---------|
| 204 | Retry initiated successfully (no response body) |
| 404 | PI not found or soft-deleted, target version not found, or checkpoint FNI not found |
| 422 | PI is not retryable, checkpoint restriction, or version migration is incompatible |
| 401 | Missing or invalid authentication |
| 403 | Caller lacks `retry_process_instance` permission for this PI |
| 503 | Engine at capacity (`TDE_MAX_CONCURRENT_PIS` reached) |

### HTTP 422 restriction codes

| Error code | Meaning |
|------------|---------|
| `process_instance_not_retriable` | PI is not in `fatal` / `aborted` / `error` (includes `finished`, `escalated`, `compensated`, `cancelled`, `running`) |
| `retry_checkpoint_is_join_gateway` | Checkpoint is a parallel join. Retry at the fork or upstream |
| `retry_checkpoint_is_mi_iteration` | Checkpoint is an MI/Loop iteration FNI. Retry at the shell or upstream |
| `retry_checkpoint_is_ebg_loser` | Checkpoint was cancelled by an Event-Based Gateway race |
| `retry_checkpoint_is_non_retryable` | Checkpoint was interrupted by a BPMN flow mechanism |
| `retry_inside_adhoc_subprocess` | Targeted PI is a child of an ad-hoc subprocess scope |
| `retry_checkpoint_inside_adhoc_subprocess` | Checkpoint points inside an ad-hoc subprocess scope |
| `retry_inside_transaction_scope` | Targeted PI has a transaction ancestor |
| `retry_checkpoint_inside_transaction` | Checkpoint points inside a transaction child scope |
| `version_migration_incompatible` | Surviving flow-node IDs are missing from the target version |

## Version Migration

When a `version` parameter is provided, the engine attempts to migrate the PI to a different version of the same process model. The migration checks structural compatibility between the original and target versions:

- All FNI flow node IDs that survived the checkpoint reset must exist in the target version
- The Start Event used by the original PI must exist in the target version

If the target version is structurally incompatible, the retry is rejected with **422** and an error body:

```json
{
  "error": "version_migration_incompatible",
  "message": "Target version is not compatible with the current PI state",
  "missingFlowNodeIds": ["Task_renamed"],
  "processModelId": "my-process",
  "currentVersion": "1.0.0",
  "targetVersion": "2.0.0"
}
```

The `"latest"` keyword resolves to the most recent non-deleted, enabled version at the time of the retry request.

## Checkpoint Reset

When `resetToFlowNodeInstanceId` is provided, the engine performs a targeted reset:

1. **Forward reachability traversal** — identifies all FNIs that are causally downstream of the checkpoint FNI
2. **Deletion** — removes all downstream FNIs from the database
3. **Data Object rollback** — reverts any Data Object writes performed by deleted FNIs
4. **Reset** — sets the checkpoint FNI back to `active` state

Without a checkpoint, all FNIs are deleted and the PI retries from the Start Event.

## Process Instance Tree

When a PI is part of a Call Activity hierarchy (parent/child relationships), retry operates on the entire tree:

| Scenario | Behavior |
|----------|----------|
| Retry on the root PI | Resets the root and cascades to descendants as needed |
| Retry on a child PI | Resets the child; the parent's Call Activity FNI re-enters `waiting` |
| Call Activity FNI survives checkpoint | Child PI is preserved (reset if non-terminal) |
| Call Activity FNI is deleted by checkpoint | Child PI is hard-deleted along with its entire subtree |

The retry endpoint always targets a single PI. Tree reconciliation (resetting ancestors upward and descendants downward) happens automatically.

## Three-Phase Mechanism

Internally, retry follows three phases:

1. **Targeted reset** — checkpoint + version migration on the specified PI (pure DB operations)
2. **Tree reset** — reconcile ancestors (upward) and descendants (downward through Call Activities)
3. **Resume** — resume from the root PI via the standard `ResumeRunner` code path

Phases 1 and 2 are pure database operations. Phase 3 reuses the same resume logic as engine-restart recovery, ensuring consistency.

## Authorization

Retry requires the `retry_process_instance` JWT claim:

| Claim Value | Scope |
|-------------|-------|
| `"none"` | Cannot retry any PI (default) |
| `"own"` | Can retry PIs the caller originally started |
| `"all"` | Can retry any PI |

## Events

A successful retry emits `ProcessInstanceRetried` via the EngineEventBus (camelCase on the wire):

| Field | Description |
|-------|-------------|
| `processInstanceId` | Root PI of the tree |
| `targetProcessInstanceId` | The PI the caller targeted (may differ from the root) |
| `processModelId` | BPMN process ID string |
| `version` | **Process version UUID** of the version the PI is now on (not the `evil:version` string) |
| `previousState` | `"fatal"`, `"aborted"`, or `"error"` |
| `previousVersion` | Process version UUID before migration, or `null` |
| `newVersion` | Process version UUID after migration, or `null` when no migration |
| `resetToFlowNodeInstanceId` | Checkpoint FNI, or `null` when omitted |
| `retriedBy` | Identity of the caller |
| `startedById` | Visibility stamp |
| `hasLanelessFlowNode` / `laneNames` | Visibility stamps (same model as `ProcessInstanceStateChanged`) |
| `occurredAt` | UTC timestamp |

## Related

- [Error Handling](error-handling.md) -- fatal, aborted, and error PI states
- [Error End Events](error-end-events.md) -- PIs in error state and retry support
- [Call Activities](call-activities.md) -- parent/child PI relationships
- [Transactions](transactions.md) -- transaction-scope retry restrictions
- [Ad-hoc Subprocesses](adhoc-subprocesses.md) -- ad-hoc-scope retry restrictions
- [Starting Instances](starting-instances.md) -- PI lifecycle from the start
- [Monitoring](monitoring.md) -- observing retry events
- [Authentication](../api/authentication.md) -- `retry_process_instance` claim

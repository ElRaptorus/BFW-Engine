# Process Instance Retry and Restart

The engine provides a retry mechanism for process instances that have failed (`fatal`), been aborted (`aborted`), or terminated via an Error End Event (`error`). Retry restarts the PI from a checkpoint or from the beginning, optionally migrating to a newer version of the process definition.

## How It Works

1. A PI reaches `fatal`, `aborted`, or `error` state
2. An operator sends `PUT /process-instances/{id}/retry` with optional parameters
3. The engine validates the request (PI state, version compatibility, authorization)
4. The PI is reset according to the specified strategy and resumes execution

## REST API

```bash
# Retry from the beginning (same version)
curl -X PUT http://localhost:4000/process-instances/$PI_ID/retry \
  -H "Authorization: Bearer $TOKEN"

# Retry with version migration
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
| `version` | string | Target process version to migrate to. Use `"latest"` to auto-resolve to the most recent enabled, non-deleted version. Omit to retry on the same version. |
| `resetToFlowNodeInstanceId` | string | Checkpoint FNI ID. All FNIs causally downstream of this FNI are deleted, and this FNI is reset to `active`. Omit to restart from the beginning. |

### Response Codes

| Code | Meaning |
|------|---------|
| 204 | Retry initiated successfully (no response body) |
| 404 | PI not found or soft-deleted |
| 422 | PI is in a non-retryable state (e.g. `running` or `finished`), or version migration is incompatible |
| 401 | Missing or invalid authentication |
| 403 | Caller lacks `retry_process_instance` permission for this PI |
| 503 | Engine at capacity (`EVIL_MAX_CONCURRENT_PIS` reached) |

## Version Migration

When a `version` parameter is provided, the engine attempts to migrate the PI to a different version of the same process model. The migration checks structural compatibility between the original and target versions:

- All FNI flow node IDs that survived the checkpoint reset must exist in the target version
- The Start Event used by the original PI must exist in the target version

If the target version is structurally incompatible, the retry is rejected with **422** and an error body:

```json
{
  "error": "version_migration_incompatible",
  "message": "Target version is not compatible with the current PI state",
  "missing_flow_node_ids": ["Task_renamed"],
  "process_model_id": "my-process",
  "current_version": "1.0.0",
  "target_version": "2.0.0"
}
```

The `"latest"` keyword resolves to the most recent non-deleted, enabled version at the time of the retry request.

## Checkpoint Reset

When `resetToFlowNodeInstanceId` is provided, the engine performs a targeted reset:

1. **Forward reachability traversal** — identifies all FNIs that are causally downstream of the checkpoint FNI
2. **Deletion** — removes all downstream FNIs from the database
3. **Data Object rollback** — reverts any Data Object writes performed by deleted FNIs
4. **Reset** — sets the checkpoint FNI back to `active` state

Without a checkpoint, all FNIs are deleted and the PI restarts from the Start Event.

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
3. **Resume** — restart from the root PI via the standard `ResumeRunner` code path

Phases 1 and 2 are pure database operations. Phase 3 reuses the same resume logic as engine-restart recovery, ensuring consistency.

## Authorization

Retry requires the `retry_process_instance` JWT claim:

| Claim Value | Scope |
|-------------|-------|
| `"none"` | Cannot retry any PI (default) |
| `"own"` | Can retry PIs the caller originally started |
| `"all"` | Can retry any PI |

## Events

A successful retry emits `Event.ProcessInstanceRetried` via the EngineEventBus:

| Field | Description |
|-------|-------------|
| `process_instance_id` | The retried PI |
| `target_process_instance_id` | Same as `process_instance_id` (reserved for future use) |
| `process_model_id` | Process model key |
| `version` | The version string used |
| `previous_state` | `"fatal"`, `"aborted"`, or `"error"` |
| `previous_version` | Version before migration (if applicable) |
| `new_version` | Version after migration (if applicable) |
| `reset_to_flow_node_instance_id` | Checkpoint FNI (if provided) |
| `retried_by` | Identity of the caller |
| `occurred_at` | UTC timestamp |

## Related

- [Error Handling](error-handling.md) -- fatal, aborted, and error PI states
- [Error End Events](error-end-events.md) -- PIs in error state and retry support
- [Call Activities](call-activities.md) -- parent/child PI relationships
- [Starting Instances](starting-instances.md) -- PI lifecycle from the start
- [Monitoring](monitoring.md) -- observing retry events
- [Authentication](../api/authentication.md) -- `retry_process_instance` claim

# User Tasks

User Tasks are wait states that pause execution until a human completes the task. This guide covers the available extension elements, how to complete tasks, and result contract validation.

## Extension Elements

| Extension | Purpose |
|-----------|---------|
| `evil:assignees` | FEEL expression evaluated at runtime for task assignment |
| `evil:formFields` | Formkit-opaque form definition (passed through to clients, not interpreted by the engine) |
| `evil:inputMapping` | FEEL-based input mapper (`source`/`target` pair). Transforms incoming token before the task is presented. Multiple supported |
| `evil:outputMapping` | FEEL-based output mapper (`source`/`target` pair). Transforms user submission before result contract validation. Multiple supported |
| `evil:payloadContract` | JSON Schema validated on incoming data (after input mapping). Violation → fatal |
| `evil:resultContract` | JSON Schema enforced on completion results (after output mapping). Violation → retryable (422) |
| `evil:dueDate` | FEEL expression or ISO 8601 timestamp for task deadline metadata |
| `evil:priority` | Numeric priority value |

```xml
<bpmn:userTask id="review_order" name="Review Order">
  <bpmn:extensionElements>
    <evil:assignees>["clerk_role", "manager_role"]</evil:assignees>
    <!-- alternatively: <evil:assignees>identity.groups</evil:assignees> -->
    <evil:inputMapping source="token.raw_name" target="customer_name"/>
    <evil:payloadContract>{"type":"object","required":["customer_name"],"properties":{"customer_name":{"type":"string"}}}</evil:payloadContract>
    <evil:outputMapping source="token.user_approved" target="approved"/>
    <evil:resultContract>{"type":"object","required":["approved"],"properties":{"approved":{"type":"boolean"}}}</evil:resultContract>
    <evil:dueDate>2026-12-31T23:59:59Z</evil:dueDate>
    <evil:priority>5</evil:priority>
  </bpmn:extensionElements>
</bpmn:userTask>
```

## Data Pipeline

The User Task implements a full data transformation pipeline ():

1. **Input**: `token` → `in_mappings` (FEEL) → `payload_contract` (JSON Schema) → FNI enters `:waiting`
2. **Output** (on finish): `user result` → `out_mappings` (FEEL) → `result_contract` (JSON Schema) → `PayloadCap` → downstream token

**Error semantics**: Input mapping failures and `payload_contract` violations transition the FNI to `fatal` (upstream data is broken, user cannot fix it). Output mapping failures also transition to `fatal`. `result_contract` violations return a 422 error and the FNI stays in `:waiting` (retryable — the user can correct their submission).

## Completing a User Task

### REST — `PUT /user-tasks/{fniId}/finish`

```bash
curl -X PUT http://localhost:4000/user-tasks/$FNI_ID/finish \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"result": {"approved": true, "comment": "Looks good"}}'
```

| Status | Meaning |
|--------|---------|
| `204`  | Task completed successfully (no body) |
| `403`  | Caller can see the task (`"read"` or `observe_all`) but lacks `"write"` |
| `404`  | FNI not found or invisible to caller (no observe of that lane) |
| `413`  | Result payload exceeds `EVIL_TOKEN_MAX_BYTES` |
| `422`  | Task not in `waiting` state, or result contract violation |

### Authorization

The caller's JWT must include `lane:<lane_name>="write"` for the lane the
User Task belongs to. `"read"` or `observe_all` can see the task but
finishing it returns **403**. If the task is not on any lane, any
authenticated caller may finish it. Tasks the caller cannot observe
return `404` to prevent existence probing. See
[Authentication](../api/authentication.md).

## Cancelling a User Task

### REST — `PUT /user-tasks/{fniId}/cancel`

```bash
curl -X PUT http://localhost:4000/user-tasks/$FNI_ID/cancel \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"reason": "No longer needed"}'
```

| Status | Meaning |
|--------|---------|
| `204`  | Task cancelled, PI aborted (no body) |
| `403`  | Caller can see the task but lacks `"write"` |
| `404`  | FNI not found or invisible to caller |
| `422`  | Task not in `waiting` state |

Cancellation transitions the FNI to `aborted` and **aborts the entire
process instance** — the same effect as `PUT /process-instances/{id}/abort`.
All parallel branches are stopped and the PI transitions to `aborted`.
The same lane-based authorization rules apply as for finishing.

## Result Contract Validation

When a `evil:resultContract` JSON Schema is defined, the engine validates the
completion result strictly. If the result does not match the schema, the request
is rejected with `422 contract_violation` and the FNI remains in `waiting`
state — the process instance stays running. The user can correct the payload and
retry. A `UserTaskValidationFailed` event is emitted for observability.

## Querying User Tasks via GraphQL

Flow node instances (including user tasks) can be queried via [GraphQL](../api/graphql-reference.md):

```graphql
query {
  flowNodeInstances(
    filter: { flowNodeType: { eq: "user_task" }, state: { eq: "waiting" } },
    limit: 25,
    offset: 0
  ) {
    results {
      id
      flowNodeId
      processInstanceId
      inputToken
      state
    }
    count
    hasNextPage
  }
}
```

GraphQL queries enforce lane-based visibility — only FNIs within visible process instances are returned. See [Authentication](../api/authentication.md) for lane claim details.

## FEEL in User Tasks

[FEEL expressions](expressions.md) can be used in conditions on outgoing sequence flows from User Tasks. The completed result is available as the `token` binding in subsequent expressions.

## Related

- [Manual Tasks](manual-tasks.md) -- simpler wait states without forms
- [Error Handling](error-handling.md) -- contract violations and fatal states
- [Authentication](../api/authentication.md) -- assignee claims and lane authorization

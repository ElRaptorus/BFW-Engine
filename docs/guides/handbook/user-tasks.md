# User Tasks

User Tasks are wait states that pause execution until a human completes the task. This guide covers the available extension elements, how to complete tasks, and result contract validation.

## Extension Elements

| Extension | Purpose |
|-----------|---------|
| `bfw:assignees` | FEEL expression evaluated at runtime for task assignment |
| `bfw:formFields` | JSON array of form fields, passed through to clients and not interpreted by the engine |
| `bfw:inputMapping` | FEEL-based input mapper (`source`/`target` pair). Transforms incoming token before the task is presented. Multiple supported |
| `bfw:outputMapping` | FEEL-based output mapper (`source`/`target` pair). Transforms the `{ actionId, values }` token before result contract validation. Multiple supported |
| `bfw:payloadContract` | JSON Schema validated on incoming data (after input mapping). Violation → fatal |
| `bfw:resultContract` | JSON Schema enforced on completion results (after output mapping). Violation → retryable (422) |
| `bfw:dueDate` | FEEL expression or ISO 8601 timestamp for task deadline metadata |
| `bfw:priority` | Numeric priority value |

`bfw:formFields` is a JSON array. Each field has `id`, `type`, `label`, and `required`, plus optional `placeholder`, `defaultValue`, `options`, `validationRules`, and `hint` (help text shown with the field). `type` is one of `text`, `number`, `date`, `checkbox`, `dropdown`, `radio`, `textarea`, `file`, `toggle`, `section_header`. `options` (`label` and `value`) apply to dropdown, radio, and checkbox group fields. A known validation rule is `pattern`: `value` is a regular expression the whole input must match, and `message` is shown on failure.

```xml
<bpmn:userTask id="review_order" name="Review Order">
  <bpmn:extensionElements>
    <bfw:assignees>["clerk_role", "manager_role"]</bfw:assignees>
    <!-- alternatively: <bfw:assignees>identity.groups</bfw:assignees> -->
    <bfw:inputMapping source="token.raw_name" target="customer_name"/>
    <bfw:payloadContract>{"type":"object","required":["customer_name"],"properties":{"customer_name":{"type":"string"}}}</bfw:payloadContract>
    <bfw:outputMapping source="token.values.approved" target="approved"/>
    <bfw:resultContract>{"type":"object","required":["approved"],"properties":{"approved":{"type":"boolean"}}}</bfw:resultContract>
    <bfw:dueDate>2026-12-31T23:59:59Z</bfw:dueDate>
    <bfw:priority>5</bfw:priority>
  </bpmn:extensionElements>
</bpmn:userTask>
```

## Data Pipeline

The User Task implements a full data transformation pipeline ():

1. **Input**: `token` → `in_mappings` (FEEL) → `payload_contract` (JSON Schema) → FNI enters `:waiting`
2. **Output** (on finish): `{ actionId, values }` → `out_mappings` (FEEL `token` is that object) → `result_contract` (JSON Schema) → `PayloadCap` → downstream token, replacing the input token

Without output mappings the next token is the envelope. To flatten a field, map it out:

```xml
<bfw:outputMapping source="token.values.approved" target="approved"/>
```

Gateways then read `token.approved`. With no mapping they read `token.actionId` and `token.values.<fieldId>`. A result-contract violation path starts with `/values` when the contract checks the unmapped envelope.

**Error semantics**: Input mapping failures and `payload_contract` violations transition the FNI to `fatal` (upstream data is broken, user cannot fix it). Output mapping failures also transition to `fatal`. `result_contract` violations return a 422 error and the FNI stays in `:waiting` (retryable — the user can correct their submission).

## Completing a User Task

### REST — `PUT /user-tasks/{fniId}/finish`

```bash
curl -X PUT http://localhost:4000/user-tasks/$FNI_ID/finish \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"actionId": "confirm", "values": {"approved": true, "comment": "Looks good"}}'
```

| Status | Meaning |
|--------|---------|
| `204`  | Task completed successfully (no body) |
| `403`  | Caller can see the task (`"read"` or `observe_all`) but lacks `"write"` |
| `404`  | FNI not found or invisible to caller (no observe of that lane) |
| `413`  | `values` exceeds `BFE_TOKEN_MAX_BYTES` (`field` `values`), or the token written after the envelope and output mappings does (`field` `user_task_result`). A `values` object exactly at the cap can still be rejected, because the stored token is `{ actionId, values }`. The task stays waiting |
| `422`  | Task not in `waiting` state, `invalid_values`, `invalid_action_id`, or result contract violation |

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
process tree** — the same effect as `PUT /process-instances/{id}/abort`.
All parallel branches and descendant Call Activity / SubProcess children
are stopped and the PI transitions to `aborted`. Error Boundary Events
do not catch the abort. The same lane-based authorization rules apply as
for finishing.

## Result Contract Validation

When a `bfw:resultContract` JSON Schema is defined, the engine validates the
mapped output. Without output mappings that output is `{ actionId, values }`,
so a contract written against flat field values does not match and the task
stays waiting. If the output does not match the schema, the request
is rejected with `422 contract_violation` and the FNI remains in `waiting`
state — the process instance stays running. The user can correct the payload and
retry. A `UserTaskValidationFailed` event is emitted for observability.
Violation paths on the unmapped envelope start with `/values`.

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

[FEEL expressions](expressions.md) can be used in conditions on outgoing sequence flows from User Tasks. The task token is available as the `token` binding. Without output mappings that token is `{ actionId, values }`.

## Related

- [Manual Tasks](manual-tasks.md) -- simpler wait states without forms
- [Error Handling](error-handling.md) -- contract violations and fatal states
- [Authentication](../api/authentication.md) -- assignee claims and lane authorization

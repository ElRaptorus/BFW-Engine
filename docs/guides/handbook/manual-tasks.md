# Manual Tasks

Manual Tasks represent work performed outside the engine that optionally requires explicit operator confirmation before the process continues.

## The `bfw:requireConfirmation` Extension

| Value | Behavior |
|-------|----------|
| `true` | FNI enters `waiting` state — an operator must explicitly confirm completion |
| `false` or absent | Pass-through — the token flows to the next node immediately |

```xml
<bpmn:manualTask id="verify_shipment" name="Verify Shipment">
  <bpmn:extensionElements>
    <bfw:requireConfirmation>true</bfw:requireConfirmation>
  </bpmn:extensionElements>
</bpmn:manualTask>
```

## Confirming a Manual Task

When confirmation is required, confirm the task with its own endpoint. The request has no body:

```bash
curl -X PUT http://localhost:4000/manual-tasks/$FNI_ID/confirm \
  -H "Authorization: Bearer $TOKEN"
```

To cancel the task instead (this aborts the whole process instance tree):

```bash
curl -X PUT http://localhost:4000/manual-tasks/$FNI_ID/cancel \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"reason": "not needed"}'
```

The `/user-tasks/{id}/finish` and `/user-tasks/{id}/cancel` endpoints accept User Tasks only and answer `404` for a Manual Task.

Manual Tasks do not support form fields or result contracts. The token passes through unchanged: the output token is the token the task entered with, and any body sent to `confirm` is ignored.

A confirming Manual Task appears in the same task inbox as User Tasks (`GET`/subscribe on `user_tasks:pending`, or the equivalent GraphQL query), marked with `flowNodeType: "manual_task"` so a client can tell it apart from a User Task. It disappears from the inbox — via one `UserTaskFinished` event — as soon as it stops waiting for any reason: an explicit confirm or cancel, a boundary event interrupting the task, a Terminate/Error/Cancel End Event elsewhere in the process, or the process instance aborting or fataling. A non-confirming Manual Task never appears in the inbox at all.

## Use Cases

- **Approval gates** -- require a manager to confirm before proceeding
- **Manual verification** -- pause the process until a physical check is done
- **External handoffs** -- wait for a third party to signal completion

## Related

- [User Tasks](user-tasks.md) -- completion mechanics and result contracts
- [FEEL Expressions](expressions.md) -- expressions in outgoing conditions

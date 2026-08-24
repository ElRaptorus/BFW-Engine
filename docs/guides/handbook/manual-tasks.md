# Manual Tasks

Manual Tasks represent work performed outside the engine that optionally requires explicit operator confirmation before the process continues.

## The `evil:requireConfirmation` Extension

| Value | Behavior |
|-------|----------|
| `true` | FNI enters `waiting` state — an operator must explicitly confirm completion |
| `false` or absent | Pass-through — the token flows to the next node immediately |

```xml
<bpmn:manualTask id="verify_shipment" name="Verify Shipment">
  <bpmn:extensionElements>
    <evil:requireConfirmation>true</evil:requireConfirmation>
  </bpmn:extensionElements>
</bpmn:manualTask>
```

## Confirming a Manual Task

When confirmation is required, complete the task using the same endpoints as User Tasks:

```bash
curl -X PUT http://localhost:4000/user-tasks/$FNI_ID/finish \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"result": {}}'
```

Or via REST — see [User Tasks](user-tasks.md) for the finish request body.

Manual Tasks do not support form fields or result contracts. The result payload (if any) becomes the output token.

## Use Cases

- **Approval gates** -- require a manager to confirm before proceeding
- **Manual verification** -- pause the process until a physical check is done
- **External handoffs** -- wait for a third party to signal completion

## Related

- [User Tasks](user-tasks.md) -- completion mechanics and result contracts
- [FEEL Expressions](expressions.md) -- expressions in outgoing conditions

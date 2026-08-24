# Starting Process Instances

This guide covers how to start a new process instance and configure initial payload and start event selection.

## Starting via REST

```bash
curl -X POST http://localhost:4000/processes/order_process/start \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "payload": {"orderId": "ORD-123", "amount": 500},
    "startEventId": "Start_Main",
    "businessKey": "external-ref-42"
  }'
```

All fields in the body are optional:

| Field | Purpose |
|-------|---------|
| `payload` | Initial token data for the process instance |
| `startEventId` | Disambiguate when multiple Start Events exist |
| `businessKey` | User-assigned business key for external correlation |

### Response

```json
{
  "processInstanceId": "pi-uuid-...",
  "processModelId": "order_process",
  "version": "2.1.0",
  "state": "running"
}
```

| Status | Meaning |
|--------|---------|
| `201` | PI started |
| `401` | Missing or invalid JWT |
| `403` | Caller has `"read"` / `observe_all` but not `"write"` on the Start Event's lane |
| `404` | Process not found, no active version, or caller has no observe claim on the Start Event's lane |
| `413` | Payload exceeds `EVIL_TOKEN_MAX_BYTES` (see [Error Handling](error-handling.md)) |
| `422` | Process disabled (`process_disabled`), or ambiguous / non-matching start event |

## Start Event Resolution

The engine resolves the target Start Event using these rules:

| Start Events in Process | `startEventId` Provided | Behavior |
|------------------------|------------------------|----------|
| Single untyped | No | Uses the single Start Event |
| Single untyped | Yes, matching | Uses it |
| Single untyped | Yes, non-matching | Error: `start_event_not_found` |
| Multiple untyped | No | Error: `ambiguous_start_event` |
| Multiple untyped | Yes, matching | Uses the matching one |
| Multiple untyped | Yes, non-matching | Error: `start_event_not_found` |

## Payload Size Limit

The `payload` field is subject to the engine-wide `EVIL_TOKEN_MAX_BYTES` cap (default 64 KiB). Oversized payloads are rejected before any engine state changes. See [Error Handling](error-handling.md) for the error response shape.

## Identity

The caller's JWT claims are captured as the PI's `started_by` identity. This identity is available in [FEEL expressions](expressions.md) via the `identity` binding and is recorded for audit purposes.

## Related

- [Deploying Processes](deploying-processes.md) -- deploy before you can start
- [FEEL Expressions](expressions.md) -- the `identity` and `token` bindings available in conditions
- [REST API Reference](../api/rest-reference.md) -- complete endpoint documentation

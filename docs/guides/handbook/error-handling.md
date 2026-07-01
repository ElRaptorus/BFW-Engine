# Error Handling

This guide covers the error states, rejection mechanisms, and failure isolation built into the engine.

## FNI and PI States

### Flow Node Instance (FNI) States

| State | Meaning |
|-------|---------|
| `active` | Currently executing |
| `waiting` | Paused for external input (User Task, Manual Task, async Service Task) |
| `finished` | Completed successfully |
| `fatal` | Unrecoverable error — the PI also transitions to `fatal` |
| `aborted` | Aborted by an external actor (user cancel, PI abort) |
| `interrupted` | Interrupted by another BPMN element (Boundary Event, Terminate End Event, Error End Event) |
| `error` | The FNI threw a modeled BPMN error via an [Error End Event](error-end-events.md) |

### Process Instance (PI) States

| State | Meaning |
|-------|---------|
| `running` | Normal execution — FNIs are being dispatched |
| `finished` | All paths reached End Events |
| `fatal` | An FNI encountered an unrecoverable engine error |
| `aborted` | Explicitly aborted by an operator via `PUT /process-instances/{id}/abort` |
| `error` | The process ended via an [Error End Event](error-end-events.md) — a modeled BPMN error outcome |

A PI transitions to `fatal` when any FNI reaches `fatal` state. A PI transitions to `error` when an Error End Event fires — this is a modeled business error, not an engine crash.

Terminal PIs (`finished`, `fatal`, `aborted`, or `error`) stop their OTP process — there is no lingering state.

PIs in `fatal`, `aborted`, or `error` state can be retried via the [Retry and Restart](retry-restart.md) mechanism.

### `fatal` vs `error`

These two states represent fundamentally different situations:

| | `fatal` | `error` |
|---|---------|-----------|
| **Cause** | Engine failure (handler crash, unsupported element, persistence error) | Modeled BPMN error (the diagram author placed an Error End Event) |
| **FNI state** | `:fatal` | `:error` (the Error End Event FNI) |
| **Siblings** | Remain in their current state | Interrupted (`:interrupted` with reason `:error_end_event`) |
| **Parent behavior** | Child PI fatal → parent CA gets `CHILD_FATAL` error | Child PI in `error` state → parent CA matches boundary by `error_code` |
| **Retryable** | Yes | Yes (operator can fix root cause and retry) |
| **REST/GraphQL** | State `"fatal"` | State `"error"` |

## Payload Cap

Every user-supplied payload is checked against `EVIL_TOKEN_MAX_BYTES` (default 64 KiB, configurable). This applies to:

- PI start payload
- User Task completion results
- Service Task handler output
- Async flow node completion payloads
- Published messages, signals, and escalations

### REST Response (HTTP 413)

```json
{
  "error": "payload_too_large",
  "field": "payload",
  "size": 123456,
  "limit": 65536
}
```

### GraphQL Error

```json
{
  "errors": [{
    "message": "payload_too_large",
    "extensions": {
      "code": "PAYLOAD_TOO_LARGE",
      "field": "payload",
      "size": 123456,
      "limit": 65536
    }
  }]
}
```

No engine state changes on a payload cap violation — the operation is rejected before any work begins.

## Result Contract Violations

When a [User Task](user-tasks.md) defines an `evil:resultContract` (JSON Schema), the completion result is validated strictly. A schema mismatch causes the FNI to transition to `fatal`.

## Handler Errors

When a [Service Task](service-tasks.md) handler returns `{:error, reason}`, the FNI transitions to `fatal`. Retry logic is the plugin's responsibility — the engine does not retry failed handlers automatically.

## SinkFailed Events

When an Event Sink crashes during `handle_event/2`, the `EngineEventBus` catches the error and:

1. Emits a `SinkFailed` event to all surviving sinks
2. Preserves the crashing sink's previous state
3. Continues dispatching to other sinks

The bus itself is never killed by a sink crash. See [Implementing Event Sinks](../plugins/event-sink.md) for sink isolation details.

## Error End Events

Error End Events allow process modelers to signal a modeled BPMN error. When an Error End Event fires:

1. The Error End Event FNI transitions to `error` state
2. All remaining active/waiting sibling FNIs are interrupted
3. The PI transitions to `error` state
4. If the PI has a parent (Call Activity), the error propagates for boundary matching

See [Error End Events](error-end-events.md) for full details, BPMN examples, and error resolution rules.

## Error Boundary Events

Error Boundary Events allow a process to catch and handle errors from activity nodes. They catch both engine failures and modeled BPMN errors (from [Error End Events](error-end-events.md)). Instead of the parent PI going `fatal` or `error`, the error is routed to an alternative path.

See [Error Boundary Events](error-boundary-events.md) for full configuration, matching rules, and examples.

## Encounter-Time Validation

The engine validates certain structural properties at execution time (not just at deploy):

| Condition | Error |
|-----------|-------|
| Non-gateway node with multiple outgoing flows | `implicit_split` |
| Non-End-Event node with zero outgoing flows | `dead_end` |
| Unsupported BPMN element type encountered | `unsupported_element` |

These cause the FNI to transition to `fatal`.

## Process Instance Retry

PIs that reach `fatal`, `aborted`, or `error` state are not permanently stuck. The engine provides a [Retry and Restart](retry-restart.md) mechanism that allows operators to:

- Restart a PI from the beginning or from a specific checkpoint
- Migrate to a newer, compatible version of the process definition
- Automatically reconcile parent/child PI trees (Call Activity hierarchies)

See the [Retry and Restart](retry-restart.md) guide for full details.

## Related

- [Error End Events](error-end-events.md) -- throwing modeled BPMN errors
- [Retry and Restart](retry-restart.md) -- recovering from fatal, aborted, and error states
- [Error Boundary Events](error-boundary-events.md) -- catching errors from activities
- [Call Activities](call-activities.md) -- child PI error propagation
- [Service Tasks](service-tasks.md) -- retry policies and async error handling
- [User Tasks](user-tasks.md) -- result contract validation
- [Link Events](link-events.md) -- orphan link pairs cause fatal transitions
- [Troubleshooting](../operations/troubleshooting.md) -- diagnosing common issues

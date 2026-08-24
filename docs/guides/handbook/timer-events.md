# Timer Events

Timer Events allow a process to react to the passage of time. The engine supports three timer types — durations, dates, and cycles — across three BPMN positions: Intermediate Catch Events, Boundary Events, and Start Events.

## Timer Types

Every timer is configured via one of three ISO 8601 specs in the BPMN XML:

| Timer Type | XML Element | Example | Meaning |
|------------|-------------|---------|---------|
| Duration | `<bpmn:timeDuration>` | `PT30M` | Fire after 30 minutes |
| Date | `<bpmn:timeDate>` | `2026-12-01T10:00:00Z` | Fire at a specific date and time |
| Cycle | `<bpmn:timeCycle>` | `R3/PT1H` | Fire every hour, 3 times |

Cycle specs follow the pattern `R[n]/PT...` where `n` is the repetition count. Use `R/PT...` (no number) for infinite repetitions.

Duration and date specs also accept FEEL expressions that resolve to a duration or date string at runtime:

```xml
<bpmn:timeDuration>"PT" + string(token.delaySeconds) + "S"</bpmn:timeDuration>
```

## Intermediate Timer Catch Events

An Intermediate Timer Catch Event pauses a running process instance until the timer fires. It is the simplest timer position — a "wait here for X time" gate in the flow.

### Supported timer types

| Timer Type | Supported | Behaviour |
|------------|-----------|-----------|
| Duration | Yes | Waits for the specified duration, then continues |
| Date | Yes | Waits until the specified date/time, then continues. If the date is in the past, continues immediately |
| Cycle | No | Not supported per BPMN spec. The engine rejects cycle specs on intermediate catch events |

### BPMN example

```xml
<bpmn:intermediateCatchEvent id="Wait_30min" name="Cool down period">
  <bpmn:timerEventDefinition>
    <bpmn:timeDuration>PT30M</bpmn:timeDuration>
  </bpmn:timerEventDefinition>
  <bpmn:incoming>Flow_In</bpmn:incoming>
  <bpmn:outgoing>Flow_Out</bpmn:outgoing>
</bpmn:intermediateCatchEvent>
```

### FEEL expressions

Timer specs can be FEEL expressions evaluated against the current token:

```xml
<bpmn:intermediateCatchEvent id="Wait_Dynamic" name="Dynamic delay">
  <bpmn:timerEventDefinition>
    <bpmn:timeDuration>"PT" + string(token.seconds) + "S"</bpmn:timeDuration>
  </bpmn:timerEventDefinition>
  <bpmn:incoming>Flow_In</bpmn:incoming>
  <bpmn:outgoing>Flow_Out</bpmn:outgoing>
</bpmn:intermediateCatchEvent>
```

If the expression evaluates to a DateTime, it is used directly as the fire time. If it evaluates to a string, the engine parses it as an ISO 8601 spec.

### Runtime behaviour

1. The FNI enters the `:waiting` state
2. The timer spec is evaluated (FEEL or ISO 8601)
3. A timer is registered with the Scheduler
4. When the timer fires, the FNI completes and the token continues along the outgoing sequence flow

The timer's `fire_at` is persisted in the FNI's `type_properties`, so the engine can reconstruct the timer after a restart.

## Timer Boundary Events

A Timer Boundary Event is attached to a host activity (User Task, Service Task, etc.) and fires while the host is running. There are two variants:

- **Interrupting** — the timer fires, the host activity is cancelled, and the process follows the boundary's outgoing path
- **Non-Interrupting** — the timer fires, the host activity continues, and a parallel branch is spawned along the boundary's outgoing path

### Supported timer types

| Timer Type | Interrupting | Non-Interrupting |
|------------|-------------|-----------------|
| Duration | Fires once, interrupts host | Fires once, spawns parallel branch |
| Date | Fires once at the target date, interrupts host | Fires once at the target date, spawns parallel branch |
| Cycle | Fires on the **first** occurrence only, then interrupts host | Fires on **every** occurrence, spawning a new parallel branch each time |

### BPMN example (interrupting)

```xml
<bpmn:userTask id="Task_Review" name="Review Order">
  <bpmn:incoming>Flow_In</bpmn:incoming>
  <bpmn:outgoing>Flow_Success</bpmn:outgoing>
</bpmn:userTask>

<bpmn:boundaryEvent id="Timer_Timeout" attachedToRef="Task_Review" cancelActivity="true">
  <bpmn:timerEventDefinition>
    <bpmn:timeDuration>PT1H</bpmn:timeDuration>
  </bpmn:timerEventDefinition>
  <bpmn:outgoing>Flow_Timeout</bpmn:outgoing>
</bpmn:boundaryEvent>
```

If the user does not complete the review within 1 hour, the timer fires, the User Task is interrupted, and the process follows `Flow_Timeout`.

### BPMN example (non-interrupting cycle)

```xml
<bpmn:userTask id="Task_Review" name="Review Order">
  <bpmn:incoming>Flow_In</bpmn:incoming>
  <bpmn:outgoing>Flow_Success</bpmn:outgoing>
</bpmn:userTask>

<bpmn:boundaryEvent id="Timer_Reminder" attachedToRef="Task_Review" cancelActivity="false">
  <bpmn:timerEventDefinition>
    <bpmn:timeCycle>R/PT15M</bpmn:timeCycle>
  </bpmn:timerEventDefinition>
  <bpmn:outgoing>Flow_SendReminder</bpmn:outgoing>
</bpmn:boundaryEvent>
```

Every 15 minutes while the User Task is active, a parallel branch is spawned along `Flow_SendReminder` (e.g. to send a reminder notification). The User Task continues waiting. Use `R3/PT15M` to limit the reminders to 3 occurrences.

### Cleanup guarantees

Timers are tightly bound to the lifecycle of the boundary event's host activity:

| When the host... | Timer action |
|-----------------|-------------|
| Completes normally | All attached boundary timers are cancelled |
| Goes fatal | All attached boundary timers are cancelled |
| Is aborted | All attached boundary timers are cancelled |
| Is interrupted by another boundary | Sibling boundary timers are cancelled |

No timer created by a boundary event can survive beyond its host's lifecycle. This also applies within the `core_timers` Scheduler — the engine cancels the ETS entry, leaving no remnants.

### Simultaneous fires

If multiple interrupting boundaries fire at the same instant, the first one processed wins and the others are discarded. For a mix of interrupting and non-interrupting boundaries, the order depends on message arrival — both outcomes are valid per the BPMN specification.

## Timer Start Events

Timer Start Events create process instances based on time. They come in three flavours, each with fundamentally different semantics:

### Cycle Timer Start Events (auto-scheduled)

Cycle timers are the only start event type that fires automatically. When a process with a cycle timer start is deployed, the engine schedules a recurring timer that creates a new process instance on each fire.

```xml
<bpmn:startEvent id="Start_Hourly" name="Hourly Check">
  <bpmn:timerEventDefinition>
    <bpmn:timeCycle>R/PT1H</bpmn:timeCycle>
  </bpmn:timerEventDefinition>
  <bpmn:outgoing>Flow_1</bpmn:outgoing>
</bpmn:startEvent>
```

Cycle start events support **enable/disable** via the Timer Schedules API:

```
GET  /timer-schedules              # List all schedules
GET  /timer-schedules/:id          # Get a single schedule
PUT  /timer-schedules/:id/enable   # Re-enable a disabled schedule
PUT  /timer-schedules/:id/disable  # Disable a schedule
```

Disabling a schedule stops the timer from firing. Re-enabling re-arms it with the next occurrence. The cycle's remaining repetition count is preserved across enable/disable toggles.

On engine restart, all enabled cycle schedules are automatically reloaded and re-armed.

### Date Timer Start Events (manual start, blocking gate)

A date timer start is **not** auto-scheduled. When a process instance is started manually (via the API with `start_event_id`), the start event acts as a blocking gate: the PI starts, but the Start Event FNI does not complete until the specified date/time is reached.

```xml
<bpmn:startEvent id="Start_NewYear" name="New Year Launch">
  <bpmn:timerEventDefinition>
    <bpmn:timeDate>2027-01-01T00:00:00Z</bpmn:timeDate>
  </bpmn:timerEventDefinition>
  <bpmn:outgoing>Flow_1</bpmn:outgoing>
</bpmn:startEvent>
```

If the date is already in the past when the PI starts, the start event completes immediately.

### Duration Timer Start Events (manual start, blocking delay)

Like date timers, a duration timer start is **not** auto-scheduled. It acts as a blocking delay: the PI starts, and the start event holds for the configured duration before completing.

```xml
<bpmn:startEvent id="Start_Delayed" name="Delayed Start">
  <bpmn:timerEventDefinition>
    <bpmn:timeDuration>PT5M</bpmn:timeDuration>
  </bpmn:timerEventDefinition>
  <bpmn:outgoing>Flow_1</bpmn:outgoing>
</bpmn:startEvent>
```

The PI is created immediately but the first activity after the start event is not reached until 5 minutes have elapsed.

### Summary

| Timer Type | Auto-scheduled | Enable/Disable | Fires repeatedly | Blocking gate |
|------------|---------------|----------------|-------------------|---------------|
| Cycle | Yes (at deploy) | Yes | Yes | No |
| Date | No (manual start) | No | No | Yes (until date) |
| Duration | No (manual start) | No | No | Yes (for duration) |

## Resume Behaviour

Timer events are designed to survive engine restarts:

- **Intermediate Catch**: The `fire_at` datetime is stored in the FNI's `type_properties`. On resume, if the fire time is in the future, the timer is re-registered with the Scheduler. If it is in the past, the FNI completes immediately.
- **Boundary**: Same as Intermediate Catch — the `fire_at` is stored and re-evaluated on resume. If the timer should have fired during downtime, it fires immediately (interrupting the host if applicable).
- **Cycle Start**: All enabled cycle schedules are reloaded from the database on engine boot and re-armed in the Scheduler.
- **Date/Duration Start**: Not auto-scheduled, so no resume action is needed — the blocking gate is handled by the Start Event handler.

## Manual Trigger and Cycle Schedules

Waiting Intermediate Catch or Boundary timer FNIs can be fired without waiting for the scheduled time:

```bash
curl -X POST http://localhost:4000/timer-events/$FNI_ID/trigger \
  -H "Authorization: Bearer $TOKEN"
```

Response `200`: `{ "triggered": true }`. Authorization is lane `"write"` (or laneless FNI, or `zeeky_boogie_doog`). Errors: `404` (not found / invisible), `403` (forbidden), `409` (FNI not active/waiting), `422` (`not_a_timer_event`).

Cycle Timer Start schedules are listed and toggled via REST (`GET /timer-schedules`, `GET /timer-schedules/{id}`, `PUT /timer-schedules/{id}/enable`, `PUT /timer-schedules/{id}/disable`). Plugins use `facade.timers`:

| Function | Purpose |
|----------|---------|
| `trigger_event.(flow_node_instance_id)` | Same as the REST trigger |
| `list_schedules.(opts)` / `get_schedule.(id)` | Inspect cycle schedules |
| `enable_schedule.(id)` / `disable_schedule.(id)` | Toggle a cycle schedule |

## Related

- [Error Boundary Events](error-boundary-events.md) — error-triggered boundary events
- [FEEL Expressions](expressions.md) — dynamic timer specs via FEEL
- [Deploying Processes](deploying-processes.md) — how cycle timer starts are registered at deploy time
- [Monitoring](monitoring.md) — timer-related telemetry events

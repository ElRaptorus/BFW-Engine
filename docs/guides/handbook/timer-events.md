# Timer Events

Timer Events allow a process to react to the passage of time. The engine supports three timer types — durations, dates, and cycles — across three BPMN positions: Intermediate Catch Events, Boundary Events, and Start Events.

## Timer Types

Every timer is configured via one of three ISO 8601 specs in the BPMN XML:

| Timer Type | XML Element | Example | Meaning |
|------------|-------------|---------|---------|
| Duration | `<bpmn:timeDuration>` | `PT30M` | Fire after 30 minutes |
| Date | `<bpmn:timeDate>` | `2026-12-01T10:00:00Z` | Fire at a specific date and time |
| Cycle | `<bpmn:timeCycle>` | `R3/PT1H` | Fire every hour, 3 times |

Cycle specs follow the pattern `R[n]/PT...` where `n` is the repetition count. Use `R/PT...` (no number) for infinite repetitions. `R[n]/<start date>/PT...` anchors the cycle at a start date; the first occurrence is at that start date (`R3/2026-06-01T10:00:00Z/PT1H` fires at 10:00, 11:00, and 12:00). Without a start date, the first occurrence is one interval after the timer is armed. The interval must be longer than zero.

Exactly one of the three elements may be set; a deploy with none or several is rejected. A literal `timeDate` must carry a UTC offset (`Z` or `+02:00`): `2026-12-01T10:00:00` is rejected at deploy.

Specs also accept FEEL expressions, resolved when the timer is armed:

```xml
<bpmn:timeDuration>duration("PT" + string(token.delaySeconds) + "S")</bpmn:timeDuration>
<bpmn:timeDate>date and time(token.dueAt)</bpmn:timeDate>
```

| Spec | FEEL result accepted |
|------|----------------------|
| `timeDuration` | A FEEL duration (`duration("PT5M")`) or an ISO 8601 duration string |
| `timeDate` | A FEEL date and time, or an ISO 8601 date-time string with an offset |
| `timeCycle` | An ISO 8601 cycle string (`"R3/PT1H"`) |

A FEEL date and time without an offset (`date and time("2026-12-01T10:00:00")`) is read as **UTC**. FEEL `now()` returns the server's local clock time without an offset, so expressions built on `now()` are only correct when the engine runs in UTC (the Docker image does). Date-times with a zone name (`@Europe/Berlin`) are not supported. A spec that cannot be resolved fails the element with `timer_resolution_failed`.

## Intermediate Timer Catch Events

An Intermediate Timer Catch Event pauses a running process instance until the timer fires. It is the simplest timer position — a "wait here for X time" gate in the flow.

### Supported timer types

| Timer Type | Supported | Behaviour |
|------------|-----------|-----------|
| Duration | Yes | Waits for the specified duration, then continues |
| Date | Yes | Waits until the specified date/time, then continues. If the date is in the past, continues immediately |
| Cycle | No | Not supported per BPMN spec. A deploy with a cycle on an intermediate catch event is rejected |

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

See the table under [Timer Types](#timer-types) for the accepted results.

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

### Missed cycle occurrences

A cycle never catches up on occurrences it missed. If an occurrence passes while the engine is stopped (or before the timer could fire), it is skipped and counts against the repetitions; the next future occurrence fires. A non-interrupting cycle whose occurrences have all passed never fires again and ends with its host. The same rule applies to cycle Timer Start Events and Event Subprocess timer starts: after a weekend of downtime, an hourly schedule fires once at the next full interval, not once per missed hour. A cycle Timer Start whose start date already lies in the past when it is deployed or enabled skips the occurrences that are already due; when none is left, the schedule is stored as exhausted and never fires.

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

Disabling a schedule stops the timer from firing. Re-enabling re-arms it with the next occurrence. The cycle's remaining repetition count is preserved across enable/disable toggles. A cycle with a start date keeps its schedule (occurrences that came due while it was disabled are skipped and count against the repetitions, occurrences that fired before the disable are not counted again); a cycle without a start date fires one interval after it is enabled.

On engine restart, all enabled cycle schedules are automatically reloaded and re-armed with their next future occurrence (missed occurrences are skipped, see [Missed cycle occurrences](#missed-cycle-occurrences)). The same reload runs if the internal scheduler process ever crashes and restarts; a reload that fails there is attempted three times with increasing delay before the schedules stay unarmed until the next engine restart.

Only the latest version of a process is scheduled. Deploying a new version removes the previous version's schedules, so their ids stop resolving. Deleting the latest version restores schedules for the version before it: they start again with the full repetition count and enabled, under new ids.

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
- **Boundary**: Same as Intermediate Catch — the `fire_at` is stored and re-evaluated on resume. If a duration or date timer should have fired during downtime, it fires immediately (interrupting the host if applicable). Non-interrupting **cycle** boundaries also persist `is_cycle`, remaining `cycle_repetitions`, and ISO 8601 `cycle_interval` on enter and after each re-arm; resume skips the occurrences missed during downtime, stores the next one, and keeps repeating. A boundary whose host already finished before the restart never fires.
- **Cycle Start**: All enabled cycle schedules are reloaded from the database on engine boot and re-armed with their next future occurrence.
- **Event Subprocess timer start**: Armed relative to the scope's start time, so a resumed scope keeps its original deadline. After an engine restart a cycle keeps its original schedule: the next occurrence is the first one plus one interval per fire so far, and occurrences missed while the engine was down are skipped. Each cycle tick emits a `TimerFired` event (`kind: start`).
- **Date/Duration Start**: Not auto-scheduled, so no resume action is needed — the blocking gate is handled by the Start Event handler.

## Manual Trigger and Cycle Schedules

Waiting Intermediate Catch or Boundary timer FNIs can be fired without waiting for the scheduled time:

```bash
curl -X POST http://localhost:4000/timer-events/$FNI_ID/trigger \
  -H "Authorization: Bearer $TOKEN"
```

Response `200`: `{ "triggered": true }`, or `{ "triggered": false }` when the FNI had no armed timer to fire (for example, the handler has not armed it yet, or a cycle boundary has no occurrence left). Authorization is lane `"write"` (or laneless FNI, or `zeeky_boogie_doog`). Errors: `404` (not found / invisible), `403` (forbidden), `409` (FNI not active/waiting), `422` (`not_a_timer_event`).

Cycle Timer Start schedules are listed and toggled via REST (`GET /timer-schedules`, `GET /timer-schedules/{id}`, `PUT /timer-schedules/{id}/enable`, `PUT /timer-schedules/{id}/disable`). Plugins use `facade.timers`:

| Function | Purpose |
|----------|---------|
| `trigger_event.(flow_node_instance_id)` | Same as the REST trigger: `{:ok, %{triggered: true}}` when a timer fired, `{:ok, %{triggered: false}}` when nothing was armed; not found, forbidden, not a timer, and not waiting are `{:error, reason}` |
| `list_schedules.(opts)` / `get_schedule.(id)` | Inspect cycle schedules |
| `enable_schedule.(id)` / `disable_schedule.(id)` | Toggle a cycle schedule |

## Related

- [Error Boundary Events](error-boundary-events.md) — error-triggered boundary events
- [FEEL Expressions](expressions.md) — dynamic timer specs via FEEL
- [Deploying Processes](deploying-processes.md) — how cycle timer starts are registered at deploy time
- [Monitoring](monitoring.md) — timer-related telemetry events

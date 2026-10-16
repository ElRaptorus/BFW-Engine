# Timer Subsystem (`core_timers`)

---

## Overview

`core_timers` is a lightweight, metadata-opaque timer service. It knows nothing about BPMN, Flow Nodes, Process Instances, or FEEL expressions. It accepts timer registrations with a concrete `fire_at` DateTime, a `target` (PID or registered name), and an opaque `metadata` map. On expiry, it sends `{:timer_fired, timer_ref, metadata}` to the target. The metadata is stored and returned verbatim — `core_timers` never interprets it.

---

## Architecture

```
┌──────────────────────────────────────────────────┐
│              StartEventManager                    │
│  register / unregister / enable / disable         │
│  record_fire / list / get                         │
├──────────────────────────────────────────────────┤
│              Scheduler (GenServer)                │
│  ┌──────────────┐  ┌──────────────┐              │
│  │ Primary ETS  │  │ Target Index │              │
│  │ (ordered_set)│  │    (bag)     │              │
│  └──────────────┘  └──────────────┘              │
│  PID monitoring │ Tick loop │ Cycle re-arm       │
├──────────────────────────────────────────────────┤
│              ISO8601 (pure functions)             │
│  resolve_fire_at / parse_cycle / next_cycle_fire │
├──────────────────────────────────────────────────┤
│              Persistence (behaviour)              │
│  create / update / delete / list / get            │
└──────────────────────────────────────────────────┘
```

### Dependency Rule

`core_timers` depends only on `core_types` (shared basic types) and `:telemetry`. It does **not** depend on `core_expressions`, `core_bpmn`, `core_events`, or `core_execution`. Messages flow back to `core_execution` via `send/2` — no compile-time dependency required.

---

## Scheduler

**Path:** `apps/core_timers/lib/bfw_engine/timers/scheduler.ex`

GenServer managing all in-memory timers via two ETS tables.

### Client API

| Function | Arguments | Returns | Description |
|----------|-----------|---------|-------------|
| `schedule/1` | `%{fire_at, target, metadata}` | `{:ok, timer_ref}` | Register a new timer |
| `cancel/1` | `timer_ref` | `:ok \| {:error, :not_found}` | Cancel a single timer |
| `cancel_all_for_target/1` | `target` (PID or atom) | `non_neg_integer()` | Cancel all timers for a given target and stop monitoring it; returns the number cancelled |
| `fire_now_for_target/2` | `target` (PID), optional `server` | `non_neg_integer()` | Immediately fire all pending timers for the target; returns count fired |
| `armed_count/0` | — | `non_neg_integer()` | Number of currently armed timers |

### ETS Layout

1. **Primary** (`:ordered_set`): `{{fire_at_unix_ms, timer_ref}, target, metadata, cycle_info}`
   Ordered by fire time — `ets.first/1` gives the earliest expiring timer.

2. **Target index** (`:bag`): `{target_key, timer_ref, fire_at_unix_ms}`
   Enables O(n) `cancel_all_for_target/1` without scanning the primary table.

### PID Monitoring

When a target is a PID, the Scheduler monitors it via `Process.monitor/1`. On `:DOWN`, all timers for that PID are cancelled automatically. This prevents stale timers from accumulating for terminated process instances.

### Tick Mechanism

Uses `Process.send_after(self(), :tick, tick_interval_ms)`. Each tick pops all expired entries (fire_at ≤ now) and delivers `{:timer_fired, timer_ref, metadata}` to the target via `send/2`. Configurable via `:core_timers, :tick_interval_ms` (default 1000ms, test: 50ms).

### Cycle Timers

For timers with `cycle_interval` set, the Scheduler:
1. Delivers the fire message to the target
2. Computes the next occurrence after now via `ISO8601.next_future_cycle_fire/3`
3. Re-inserts the timer into ETS with the updated fire time
4. Hands `(metadata, next_fire_at | nil, remaining)` to the optional `on_cycle_advance` callback so `StartEventManager` can persist updated state

Cycle timers decrement their `remaining` counter on each fire. When no occurrence is left, the timer is not re-armed and the callback receives `(metadata, nil, 0)`. A re-armed cycle keeps its `timer_ref`, so the ref returned by `schedule/1` (persisted as the schedule's `scheduler_ref`) cancels the cycle at any point in its life; `disable_schedule/1` and `unregister_timer_starts/1` therefore always reach the live entry.

**Catch-up (decision D-2):** an occurrence that is already due when the cycle re-arms (a late tick, a manual fire) is skipped, using up one repetition, and the first future occurrence is armed. A cycle never fires more than once per tick. Fixed-length intervals (weeks, days, hours, minutes, seconds) are skipped arithmetically; calendar intervals (years, months) step one occurrence at a time. `ISO8601.parse_cycle/1` rejects a zero or negative interval (`{:non_positive_cycle_interval, text}`), which would otherwise never advance.

**Callback worker:** `on_cycle_advance` runs in a process linked to the Scheduler, in fire order. A slow persistence write (with `PersistenceRetry` back-off) never delays a tick or a `schedule`/`cancel` call. A raise, throw, or exit in the callback is logged and the worker continues. If the worker dies anyway (killed), the Scheduler logs it and starts a new one; advances that were queued in the dead worker are not persisted.

### Restart

The ETS tables are owned by the Scheduler and die with it. The Scheduler traps exits; `terminate/2` clears a `:persistent_term` marker on `:normal`/`:shutdown`. When `init/1` finds the marker still set, the previous Scheduler crashed, and the optional `on_restart` callback (`{StartEventManager, :reload_start_schedules, []}` in `Timers.Application`) runs in a separate process to re-arm the persisted cycle start schedules. A restore that raises, exits, throws, or returns `{:error, reason}` (`reload_start_schedules/1` returns `{:error, reason}` when it cannot list the armed schedules) is retried with exponential backoff, three attempts in total starting at 500 ms; only then is an error logged: cycle start schedules stay unarmed until the next engine boot. A restart through the supervisor's `terminate_child`/`restart_child` (test reset) is a clean shutdown and restores nothing.

Known limit: PI-scoped timers (catch, boundary, start gate, Event Subprocess starts) have no persistence in `core_timers`. Their handler Tasks keep waiting after a Scheduler crash until an engine restart resumes the instance; the manual trigger cannot fire them, because the Scheduler no longer holds their timers.

### Manual timer trigger (`fire_now_for_target/2`)

**Path:** `BfwEngine.Timers.Scheduler.fire_now_for_target/2`

Immediately delivers `{:timer_fired, timer_ref, metadata}` to the target PID for every armed timer in the target index, then removes each from ETS. Cycle timers follow the same re-arm path as tick-based expiry (`maybe_rearm_cycle/5`). Returns the number of timers actually fired.

Used by the timer event manual trigger API (debugger / test acceleration):

```
POST /timer-events/:flow_node_instance_id/trigger
  → BfwEngine.Api.trigger_timer_event/3
    → BfwEngine.Execution.trigger_timer_event/2
      → ProcessInstance.trigger_timer_event/2  (gen_statem.call)
        → Scheduler.fire_now_for_target(handler_task_pid)
          → {:timer_fired, ...} to timer handler Task
```

The Api layer checks lane access first, then FNI type (`intermediate_catch_event` or `boundary_event` with `event_type: "timer"`) and active/waiting state, before reaching Execution. The PI gen_statem performs a minimal in-memory guard: the FNI must still be `:active` or `:waiting` with a live handler PID, otherwise `{:error, :fni_not_active_or_found}`. When the handler holds no armed timer (not armed yet, already fired, or an exhausted cycle boundary) nothing fires and the PI answers `{:error, :timer_not_armed}`. `BfwEngine.Api.trigger_timer_event/3` turns the outcome into `{:ok, %{triggered: true}}` or `{:ok, %{triggered: false}}`, so REST (`200 {"triggered": …}`) and the plugin facade's `timers.trigger_event` answer the same; not found, forbidden, not a timer event, and not active/waiting stay errors.

REST: `BfwEngineWeb.Http.TimerEventController` (`POST /timer-events/:flow_node_instance_id/trigger`). Client: `EventClient.triggerTimer/1` in `@elraptorus/bfw_engine_client`.

---

## ISO 8601 Module

**Path:** `apps/core_timers/lib/bfw_engine/timers/iso8601.ex`

Pure-function module for ISO 8601 timer spec resolution. No GenServer, no side effects.

| Function | Signature | Description |
|----------|-----------|-------------|
| `resolve_fire_at/3` | `(:date \| :duration \| :cycle, spec_string, reference_time)` | Resolves a spec string to a concrete `DateTime` or `{:cycle, cycle_spec}` |
| `parse_cycle/1` | `(spec_string)` | Parses `R[n]/duration` into `%{repetitions, interval_duration, start_at}` |
| `next_cycle_fire/2` | `(cycle_spec, last_fire_at)` | Computes next fire time; returns `{next_fire, updated_spec}` or `nil` when exhausted |
| `next_future_cycle_fire/3` | `(cycle_spec, last_fire_at, now)` | `next_cycle_fire/2` followed by `skip_missed_occurrences/3` |
| `skip_missed_occurrences/3` | `(cycle_spec, fire_at, now)` | Skips occurrences at or before `now` (one repetition each); returns the first future occurrence or `nil` |
| `first_fire_at/2` | `(cycle_spec, reference_time)` | First occurrence of a cycle: `start_at` itself for a start-anchored cycle (`R<n>/<start>/<duration>`, as ISO 8601 defines it), else `reference_time + interval` |

### Cycle Spec Format

Supports `R[n]/PT...` where:
- `R/PT1H` = infinite repetitions, 1 hour apart
- `R3/PT30M` = 3 repetitions, 30 minutes apart
- `R1/PT5S` = single fire after 5 seconds
- `R3/2026-06-01T10:00:00Z/PT1H` = 3 repetitions at 10:00, 11:00, and 12:00 (the first occurrence is the start)

Every caller of `first_fire_at/2` gets the same anchor: Timer Start schedules on deploy and enable, cycle boundary events, and Event Subprocess cycle starts.

Uses Elixir 1.18 `Duration.from_iso8601/1` for durations and `DateTime.from_iso8601/1` for dates.

---

## StartEventManager

**Path:** `apps/core_timers/lib/bfw_engine/timers/start_event_manager.ex`

Manages the lifecycle of Timer Start Event schedules. Receives pre-extracted timer specs from the deploy path — does **not** scan BPMN models or evaluate FEEL. Which version is scheduled is decided by the deploy and version-delete hooks in `BfwEngine.Api.Processes`: only the latest live version of each process has schedules ([execution.md](./execution.md) §Superseded Versions).

### Public API

| Function | Description |
|----------|-------------|
| `register_timer_starts/4` | Persist + schedule cycle timer starts for a deployed version. A cycle whose start lies in the past skips its due occurrences (one repetition each, D-2); a finite cycle with none left is persisted exhausted (`next_fire_at: nil`, `cycle_remaining: 0`) and not armed |
| `unregister_timer_starts/1` | Cancel ETS entries + delete persistence records for a version |
| `enable_schedule/1` | Re-enable a disabled cycle schedule and re-arm it in the Scheduler with its persisted `cycle_remaining`, cancelling any entry it still holds. A start-anchored cycle continues from its persisted `next_fire_at` (the occurrence `cycle_remaining` counts from, so occurrences fired before the disable are not counted again); a cycle without a start is re-anchored one interval after the enable. Occurrences already due are skipped (one repetition each), and a schedule with none left is persisted exhausted, so enabling an enabled schedule leaves one armed entry. An exhausted schedule (`cycle_remaining == 0`) is only marked enabled; it is not armed and never fires again |
| `disable_schedule/1` | Cancel Scheduler entry, set `enabled=false` in persistence |
| `handle_cycle_advance/3` | Scheduler callback after each cycle fire: persists the new `next_fire_at` and `cycle_remaining` (`next_fire_at = nil` once the cycle is exhausted). Runs in the Scheduler's callback worker. The **only** writer of cycle state while the schedule is armed (`reload_start_schedules/1` writes it before arming) |
| `record_fire/1` | Set `last_triggered_at` after the listener started a PI. Does not touch `cycle_remaining` or `next_fire_at` |
| `list_schedules/1` | Query schedules with optional filters |
| `get_schedule/1` | Get single schedule by ID |
| `reload_start_schedules/1` | Reload of armed cycle schedules from persistence at engine boot and after a Scheduler crash (`on_restart`). Each schedule continues from its persisted `next_fire_at` and `cycle_remaining` (not the spec's full repetition count). Occurrences that passed while it was not armed are skipped (one repetition each); the next future occurrence is persisted and armed, and a schedule with none left is persisted as exhausted (`next_fire_at: nil`, `cycle_remaining: 0`). A live entry under the persisted `scheduler_ref` is cancelled first, so reloading twice arms once |

### Schedule Record Fields

| Field | Type | Description |
|-------|------|-------------|
| `id` | UUID | Unique schedule identifier |
| `process_version_id` | String | Owning process version |
| `process_model_id` | String | Owning process model |
| `flow_node_id` | String | BPMN flow node ID of the Timer Start Event |
| `kind` | `"cycle"` | Timer type; a check constraint (`timer_start_schedules_kind_cycle`) admits only cycles |
| `iso_spec` | String | Raw ISO 8601 spec |
| `enabled` | Boolean | Whether the schedule is active |
| `next_fire_at` | DateTime? | Next scheduled fire time (nil = exhausted) |
| `last_triggered_at` | DateTime? | Last successful fire time |
| `cycle_total` | Integer? | Total cycle repetitions (nil = infinite) |
| `cycle_remaining` | Integer? | Remaining repetitions |
| `scheduler_ref` | String? | Current Scheduler ETS reference |

---

## Persistence Behaviour

**Path:** `apps/core_timers/lib/bfw_engine/timers/persistence.ex`

Only Timer Start Event schedules use this persistence layer. PI-scoped timers (Intermediate Catch and Boundary) are stored in FNI `type_properties` and do not need dedicated persistence.

| Callback | Description |
|----------|-------------|
| `create_schedule/1` | Persist a new schedule record |
| `update_schedule/2` | Update fields on an existing schedule |
| `delete_schedules_for_version/1` | Remove all schedules for a process version |
| `list_armed_schedules/0` | List enabled schedules with non-nil `next_fire_at` |
| `list_all_schedules/1` | List schedules with optional keyword filters |
| `get_schedule/1` | Get single schedule by ID |

### Implementations

| Module | Domain | Purpose |
|--------|--------|---------|
| `BfwEngine.Persistence.TimerStartScheduleAdapter` | `peripheral_persistence` | **Implemented.** Ash + AshPostgres adapter for the operational `timer_start_schedules` table. **Production default** (`config/config.exs` sets `:core_timers, :persistence_module` to this module). Cycle Timer Start schedules survive engine restart; boot reload from Postgres is real. |
| `BfwEngine.Timers.Persistence.NoOp` | `core_timers` | In-memory GenServer. **Test-only default** (`config/test.exs`). `ExecutionCase` switches tests that exercise Timer Start persistence to `TimerStartScheduleAdapter`. |

---

## Configuration

| Key | Default | Test | Description |
|-----|---------|------|-------------|
| `:core_timers, :tick_interval_ms` | `1000` | `50` | Scheduler tick frequency |
| `:core_timers, :timer_start_target` | `:timer_start_listener` | — | Registered name for Timer Start fire delivery |
| `:core_timers, :persistence_module` | `BfwEngine.Persistence.TimerStartScheduleAdapter` | `BfwEngine.Timers.Persistence.NoOp` | Persistence behaviour implementation. Production uses the Ash adapter; test env keeps NoOp; `ExecutionCase` switches to the adapter. |

---

## Telemetry Events

`core_timers` emits lightweight `:telemetry` events (no typed `Event.*` structs — those belong to `core_execution`):

| Event | Measurements | Metadata |
|-------|-------------|----------|
| `[:bfw_engine, :timer, :armed]` | `%{count: 1}` | `%{timer_ref, target}` |
| `[:bfw_engine, :timer, :fired]` | `%{count: 1}` | `%{timer_ref, target}` |
| `[:bfw_engine, :timer, :cancelled]` | `%{count: 1}` | `%{timer_ref, target}` |

---

## File Path Reference

| Module | Path |
|--------|------|
| `BfwEngine.Timers` | `apps/core_timers/lib/bfw_engine/timers.ex` |
| `BfwEngine.Timers.Scheduler` | `apps/core_timers/lib/bfw_engine/timers/scheduler.ex` |
| `BfwEngine.Timers.ISO8601` | `apps/core_timers/lib/bfw_engine/timers/iso8601.ex` |
| `BfwEngine.Timers.StartEventManager` | `apps/core_timers/lib/bfw_engine/timers/start_event_manager.ex` |
| `BfwEngine.Timers.Persistence` | `apps/core_timers/lib/bfw_engine/timers/persistence.ex` |
| `BfwEngine.Timers.Persistence.NoOp` | `apps/core_timers/lib/bfw_engine/timers/persistence/no_op.ex` |
| `BfwEngine.Persistence.TimerStartScheduleAdapter` | `apps/peripheral_persistence/lib/bfw_engine/persistence/timer_start_schedule_adapter.ex` |
| `BfwEngine.Timers.Application` | `apps/core_timers/lib/bfw_engine/timers/application.ex` |

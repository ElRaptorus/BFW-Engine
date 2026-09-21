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
| `cancel_all_for_target/1` | `target` (PID or atom) | `:ok` | Cancel all timers for a given target |
| `fire_now_for_target/2` | `target` (PID), optional `server` | `non_neg_integer()` | Immediately fire all pending timers for the target; returns count fired |
| `armed_count/0` | — | `non_neg_integer()` | Number of currently armed timers |
| `reset_state/0` | — | `:ok` | Clear all timers (test helper) |

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
2. Computes the next fire time via `ISO8601.next_cycle_fire/2`
3. Re-inserts the timer into ETS with the updated fire time
4. Invokes an optional `on_cycle_advance` callback so `StartEventManager` can persist updated state

Cycle timers decrement their `remaining` counter on each fire. When `remaining` reaches 0 (or `nil` for infinite cycles), the timer is not re-armed.

### Manual timer trigger (`fire_now_for_target/2`)

**Path:** `BfwEngine.Timers.Scheduler.fire_now_for_target/2`

Immediately delivers `{:timer_fired, timer_ref, metadata}` to the target PID for every armed timer in the target index, then removes each from ETS. Cycle timers follow the same re-arm path as tick-based expiry (`maybe_rearm_cycle/5`). Returns the number of timers fired.

Used by the timer event manual trigger API (debugger / test acceleration):

```
POST /timer-events/:flow_node_instance_id/trigger
  → BfwEngine.Api.trigger_timer_event/3
    → BfwEngine.Execution.trigger_timer_event/2
      → ProcessInstance.trigger_timer_event/2  (gen_statem.call)
        → Scheduler.fire_now_for_target(handler_task_pid)
          → {:timer_fired, ...} to timer handler Task
```

The Api layer validates FNI type (`intermediate_catch_event` or `boundary_event` with `event_type: "timer"`), active/waiting state, and lane access before reaching Execution. The PI gen_statem performs a minimal in-memory guard: the FNI must still be `:active` or `:waiting` with a live handler PID, otherwise `{:error, :fni_not_active_or_found}`.

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
| `first_fire_at/2` | `(cycle_spec, reference_time)` | Computes the first fire time from a cycle spec |

### Cycle Spec Format

Supports `R[n]/PT...` where:
- `R/PT1H` = infinite repetitions, 1 hour apart
- `R3/PT30M` = 3 repetitions, 30 minutes apart
- `R1/PT5S` = single fire after 5 seconds

Uses Elixir 1.18 `Duration.from_iso8601/1` for durations and `DateTime.from_iso8601/1` for dates.

---

## StartEventManager

**Path:** `apps/core_timers/lib/bfw_engine/timers/start_event_manager.ex`

Manages the lifecycle of Timer Start Event schedules. Receives pre-extracted timer specs from the deploy path — does **not** scan BPMN models or evaluate FEEL.

### Public API

| Function | Description |
|----------|-------------|
| `register_timer_starts/4` | Persist + schedule cycle timer starts for a deployed version |
| `unregister_timer_starts/1` | Cancel ETS entries + delete persistence records for a version |
| `enable_schedule/1` | Re-enable a disabled cycle schedule, re-arm in Scheduler |
| `disable_schedule/1` | Cancel Scheduler entry, set `enabled=false` in persistence |
| `record_fire/1` | Update `last_triggered_at`, decrement `cycle_remaining`, compute `next_fire_at` |
| `list_schedules/1` | Query schedules with optional filters |
| `get_schedule/1` | Get single schedule by ID |
| `reload_start_schedules/0` | Boot-time reload of armed cycle schedules from persistence |

### Schedule Record Fields

| Field | Type | Description |
|-------|------|-------------|
| `id` | UUID | Unique schedule identifier |
| `process_version_id` | String | Owning process version |
| `process_model_id` | String | Owning process model |
| `flow_node_id` | String | BPMN flow node ID of the Timer Start Event |
| `kind` | `"cycle" \| "date" \| "duration"` | Timer type |
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

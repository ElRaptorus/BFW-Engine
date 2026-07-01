defmodule EvilEngine.Timers do
  @moduledoc """
  Lightweight, metadata-opaque timer scheduler service.

  `core_timers` knows nothing about BPMN, Flow Nodes, Process Instances,
  or FEEL expressions. It accepts timer registrations with a concrete
  `fire_at` DateTime, a `target` (PID or registered atom), and an opaque
  `metadata` map. On expiry it sends `{:timer_fired, timer_ref, metadata}`
  to the target.

  ## Modules

  - `EvilEngine.Timers.Scheduler` — GenServer backed by ETS; tick loop,
    fire dispatch, PID monitoring, cycle re-arm
  - `EvilEngine.Timers.ISO8601` — Pure ISO 8601 parser for dates,
    durations, and `R[n]/[start]/P...` cycles
  - `EvilEngine.Timers.StartEventManager` — Timer Start schedule
    lifecycle (register, unregister, enable/disable, record_fire)
  - `EvilEngine.Timers.Persistence` — Behaviour for Timer Start
    schedule persistence

  ## Dependencies

  `core_timers` depends only on `core_types` and `:telemetry`. It does
  NOT depend on `core_expressions`, `core_bpmn`, `core_events`, or
  `core_execution`. Fire messages flow back to `core_execution` via
  `send/2` — no compile-time dependency.
  """
end

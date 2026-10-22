defmodule BfwEngine.Timers do
  @moduledoc """
  Lightweight, metadata-opaque timer scheduler service.

  `BfwEngine.Timers` knows nothing about BPMN, Flow Nodes, Process Instances,
  or FEEL expressions. It accepts timer registrations with a concrete
  `fire_at` DateTime, a `target` (PID or registered atom), and an opaque
  `metadata` map. On expiry it sends `{:timer_fired, timer_ref, metadata}`
  to the target.

  ## Modules

  - `BfwEngine.Timers.Scheduler` — GenServer backed by ETS; tick loop,
    fire dispatch, PID monitoring, cycle re-arm
  - `BfwEngine.Timers.ISO8601` — Pure ISO 8601 parser for dates,
    durations, and `R[n]/[start]/P...` cycles
  - `BfwEngine.Timers.StartEventManager` — Timer Start schedule
    lifecycle (register, unregister, enable/disable, record_fire)
  - `BfwEngine.Timers.Persistence` — Behaviour for Timer Start
    schedule persistence

  ## Dependencies

  `BfwEngine.Timers` depends only on `BfwEngine.Types` and `:telemetry`. It does
  NOT depend on `BfwEngine.Expressions`, `BfwEngine.BPMN`, `BfwEngine.Events`, or
  `BfwEngine.Execution`. Fire messages flow back to `BfwEngine.Execution` via
  `send/2` — no compile-time dependency.
  """

  use Boundary,
    deps: [BfwEngine.Types],
    exports: [ISO8601, Persistence, Scheduler, StartEventManager]
end

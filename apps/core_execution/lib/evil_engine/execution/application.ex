defmodule EvilEngine.Execution.Application do
  @moduledoc """
  OTP application for the execution runtime.

  Starts the PI Registry and DynamicSupervisor. The one-shot
  `ResumeRunner` task is NOT started here — it lives in
  `peripheral_persistence`'s supervisor so the Ecto Repo is
  guaranteed to be available when the resume query runs.
  """

  use Application

  alias EvilEngine.Events.EngineEventBus
  alias EvilEngine.Types.Event

  @impl true
  def start(_type, _args) do
    # Cap enforcement (`EVIL_MAX_CONCURRENT_PIS`) lives in
    # `Execution.start_process_instance/1` as a soft client-side pre-check, NOT
    # on the supervisor itself. This lets `ResumeRunner` bypass the cap entirely
    # at boot — every `:running` PI from the DB is brought back online,
    # regardless of `EVIL_MAX_CONCURRENT_PIS`. The cap applies only to new starts
    # via the public API. See `docs/architecture/execution.md` Resume on Startup.
    children = [
      {Registry, keys: :unique, name: EvilEngine.Execution.Registry},
      {DynamicSupervisor,
       strategy: :one_for_one, name: EvilEngine.Execution.Supervisor, max_children: :infinity},
      {EvilEngine.Execution.TimerStartListener, []}
    ]

    opts = [strategy: :one_for_one, name: EvilEngine.Execution.ApplicationSupervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def prep_stop(state) do
    EngineEventBus.publish(%Event.EngineShutdown{
      engine_id: Application.get_env(:core_execution, :engine_id, "default"),
      reason: :shutdown,
      occurred_at: DateTime.utc_now()
    })

    # Drain all sinks synchronously before the application tree stops.
    #
    # `publish/1` above sends a cast to the bus. `shutdown_sinks/0` sends a
    # call that is queued *after* that cast in the bus mailbox. The bus
    # processes messages in FIFO order, so it fans the event out to every
    # worker before servicing the shutdown call. Each worker likewise
    # processes the queued `:event` cast before the `:shutdown` call, so
    # `handle_shutdown/1` runs only after the EngineShutdown event has been
    # delivered. Workers that are already down are caught by the
    # `catch :exit, _` guard inside `shutdown_sinks/0`.
    EngineEventBus.shutdown_sinks()

    state
  end
end

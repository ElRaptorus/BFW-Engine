defmodule EvilEngine.Timers.Application do
  @moduledoc """
  OTP application callback for `core_timers`.

  Starts the supervision tree containing `EvilEngine.Timers.Scheduler` and,
  when the configured persistence module exports `child_spec/1`, the
  persistence process (e.g. `EvilEngine.Timers.Persistence.NoOp` in test).
  """

  use Application

  alias EvilEngine.Timers.Scheduler
  alias EvilEngine.Timers.StartEventManager

  @impl true
  def start(_type, _args) do
    tick_interval_ms = Application.get_env(:core_timers, :tick_interval_ms, 1000)

    on_cycle_advance =
      {StartEventManager, :handle_cycle_advance, []}

    children =
      persistence_child() ++
        [
          {Scheduler, tick_interval_ms: tick_interval_ms, on_cycle_advance: on_cycle_advance}
        ]

    opts = [strategy: :one_for_one, name: EvilEngine.Timers.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp persistence_child do
    module =
      Application.get_env(:core_timers, :persistence_module, EvilEngine.Timers.Persistence.NoOp)

    case Code.ensure_loaded(module) do
      {:module, ^module} ->
        if function_exported?(module, :child_spec, 1), do: [module], else: []

      _ ->
        []
    end
  end
end

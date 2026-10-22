defmodule BfwEngine.Timers.Supervisor do
  @moduledoc """
  Supervision tree of the timer subsystem.

  Starts `BfwEngine.Timers.Scheduler` and, when the configured persistence
  module exports `child_spec/1`, the persistence process (e.g.
  `BfwEngine.Timers.Persistence.NoOp` in test).
  """

  use Supervisor

  alias BfwEngine.Timers.Scheduler
  alias BfwEngine.Timers.StartEventManager

  @spec start_link(term()) :: Supervisor.on_start()
  def start_link(_options), do: Supervisor.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    tick_interval_ms = Application.get_env(:bfw_engine, :tick_interval_ms, 1000)

    children =
      persistence_child() ++
        [
          {Scheduler,
           tick_interval_ms: tick_interval_ms,
           on_cycle_advance: {StartEventManager, :handle_cycle_advance, []},
           on_restart: {StartEventManager, :reload_start_schedules, []}}
        ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp persistence_child do
    module =
      Application.get_env(:bfw_engine, :persistence_module, BfwEngine.Timers.Persistence.NoOp)

    case Code.ensure_loaded(module) do
      {:module, ^module} ->
        if function_exported?(module, :child_spec, 1), do: [module], else: []

      _ ->
        []
    end
  end
end

defmodule Examples.Plugins.Combined.MetricsPipeline.FacadeStore do
  @moduledoc """
  Agent-backed stash for the `BfwEngine.EngineFacade` from `on_load/1` so the
  aggregator handler can call facade closures while executing a Service Task.

  Same indirection pattern as
  `Examples.Plugins.Combined.RabbitmqToEngine.FacadeStore`: registration runs
  under the plugin lifecycle, but `handle_enter/3` runs in a worker process
  that must retrieve the facade later.
  """

  use Agent

  @doc "Starts the Agent that will store the engine facade, optionally registering under a given name."
  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(options \\ []) do
    Agent.start_link(fn -> nil end, Keyword.take(options, [:name]))
  end

  @doc "Stores the engine facade from plugin load for later use by the metrics aggregator handler."
  @spec put(BfwEngine.EngineFacade.t()) :: :ok
  def put(engine_facade) do
    ensure_started()
    Agent.update(__MODULE__, fn _previous -> engine_facade end)
  end

  @doc "Returns the last stored facade, or nil before put/1 or in tests that omit registration."
  @spec get() :: BfwEngine.EngineFacade.t() | nil
  def get do
    ensure_started()
    Agent.get(__MODULE__, & &1)
  end

  defp ensure_started do
    case Process.whereis(__MODULE__) do
      nil -> start_link(name: __MODULE__)
      _registered -> :ok
    end
  end
end

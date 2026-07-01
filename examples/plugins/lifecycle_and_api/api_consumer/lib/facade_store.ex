defmodule Examples.Plugins.ApiConsumer.FacadeStore do
  @moduledoc """
  Agent-backed stash for the `EvilEngine.EngineFacade` received during `on_load/1`
  so asynchronous workers can reach the wired `facade.*` closures later on.
  """

  use Agent

  @doc "Starts the Agent with no stored facade, optionally registering under a given name."
  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(options \\ []) do
    Agent.start_link(fn -> nil end, Keyword.take(options, [:name]))
  end

  @doc "Stores the engine facade from plugin load so workers can reuse the wired closures."
  @spec put(EvilEngine.EngineFacade.t()) :: :ok
  def put(engine_facade) do
    ensure_started()
    Agent.update(__MODULE__, fn _previous -> engine_facade end)
  end

  @doc "Returns the stored engine facade after ensuring the Agent has been started."
  @spec get() :: EvilEngine.EngineFacade.t() | nil
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

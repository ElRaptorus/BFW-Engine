defmodule Examples.Plugins.ApiConsumer.ApiConsumerPlugin do
  @moduledoc """
  Stores the `EngineFacade` from `on_load/1` and spins up the demo worker from `on_ready/1`.
  """

  @behaviour BfwEngine.Plugin

  alias Examples.Plugins.ApiConsumer.{FacadeStore, Worker}

  @doc "Persists the engine facade so on_ready can start orchestration without passing it again."
  @impl true
  def on_load(engine_facade) do
    :ok = FacadeStore.put(engine_facade)
    :ok
  end

  @doc "Starts the demo worker GenServer using the facade previously stored during on_load."
  @impl true
  def on_ready(_engine_facade) do
    case FacadeStore.get() do
      nil ->
        {:error, :facade_missing_from_store}

      stored_facade ->
        case Worker.start_link(facade: stored_facade) do
          {:ok, _worker_pid} -> :ok
          {:error, reason} -> {:error, {:worker_start_failed, reason}}
        end
    end
  end
end

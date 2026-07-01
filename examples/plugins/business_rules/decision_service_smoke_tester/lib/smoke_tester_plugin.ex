defmodule Examples.BusinessRules.DecisionServiceSmokeTester.SmokeTesterPlugin do
  @moduledoc """
  Lifecycle plugin that smoke-tests every deployed DMN Decision Service on engine ready.
  """

  @behaviour EvilEngine.Plugin

  alias Examples.BusinessRules.DecisionServiceSmokeTester.{FacadeStore, SmokeTesterWorker}

  @doc "Persists the engine facade for the smoke tester worker started from on_ready/1."
  @impl true
  def on_load(engine_facade) do
    :ok = FacadeStore.put(engine_facade)
    :ok
  end

  @doc "Starts the smoke tester worker using the facade stored during on_load/1."
  @impl true
  def on_ready(_engine_facade) do
    case FacadeStore.get() do
      nil ->
        {:error, :facade_missing_from_store}

      stored_facade ->
        case SmokeTesterWorker.start_link(facade: stored_facade) do
          {:ok, _worker_pid} -> :ok
          {:error, reason} -> {:error, {:worker_start_failed, reason}}
        end
    end
  end
end

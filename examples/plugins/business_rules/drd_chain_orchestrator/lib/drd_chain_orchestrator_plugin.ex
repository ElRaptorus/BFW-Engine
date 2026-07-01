defmodule Examples.BusinessRules.DrdChainOrchestrator.DrdChainOrchestratorPlugin do
  @moduledoc """
  Lifecycle plugin that deploys a multi-decision credit-underwriting DRD,
  runs it through a Business Rule Task, and logs the full evaluation chain trace.
  """

  @behaviour EvilEngine.Plugin

  alias Examples.BusinessRules.DrdChainOrchestrator.{DrdChainOrchestratorWorker, FacadeStore}

  @doc "Persists the engine facade for the DRD chain worker started from on_ready/1."
  @impl true
  def on_load(engine_facade) do
    :ok = FacadeStore.put(engine_facade)
    :ok
  end

  @doc "Starts the DRD chain orchestrator worker using the facade stored during on_load/1."
  @impl true
  def on_ready(_engine_facade) do
    case FacadeStore.get() do
      nil ->
        {:error, :facade_missing_from_store}

      stored_facade ->
        case DrdChainOrchestratorWorker.start_link(facade: stored_facade) do
          {:ok, _worker_pid} -> :ok
          {:error, reason} -> {:error, {:worker_start_failed, reason}}
        end
    end
  end
end

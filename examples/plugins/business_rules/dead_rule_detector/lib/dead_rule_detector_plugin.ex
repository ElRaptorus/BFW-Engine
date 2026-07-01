defmodule Examples.BusinessRules.DeadRuleDetector.DeadRuleDetectorPlugin do
  @moduledoc """
  Lifecycle plugin that deploys employee-benefits DMN and BPMN fixtures, runs the
  process with varied inputs, and reports DMN rules that never matched.
  """

  @behaviour EvilEngine.Plugin

  alias Examples.BusinessRules.DeadRuleDetector.{DeadRuleDetectorWorker, FacadeStore}

  @doc "Persists the engine facade for the dead-rule detector worker started from on_ready/1."
  @impl true
  def on_load(engine_facade) do
    :ok = FacadeStore.put(engine_facade)
    :ok
  end

  @doc "Starts the dead-rule detector worker using the facade stored during on_load/1."
  @impl true
  def on_ready(_engine_facade) do
    case FacadeStore.get() do
      nil ->
        {:error, :facade_missing_from_store}

      stored_facade ->
        case DeadRuleDetectorWorker.start_link(facade: stored_facade) do
          {:ok, _worker_pid} -> :ok
          {:error, reason} -> {:error, {:worker_start_failed, reason}}
        end
    end
  end
end

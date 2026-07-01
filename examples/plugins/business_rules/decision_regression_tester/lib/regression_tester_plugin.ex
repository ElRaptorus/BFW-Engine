defmodule Examples.BusinessRules.DecisionRegressionTester.RegressionTesterPlugin do
  @moduledoc """
  Lifecycle plugin that deploys two DMN versions and compares evaluation results
  across a fixture input set for regression detection.
  """

  @behaviour EvilEngine.Plugin

  alias Examples.BusinessRules.DecisionRegressionTester.{FacadeStore, RegressionTesterWorker}

  @doc "Persists the engine facade for the regression worker started from on_ready/1."
  @impl true
  def on_load(engine_facade) do
    :ok = FacadeStore.put(engine_facade)
    :ok
  end

  @doc "Starts the regression tester worker using the facade stored during on_load/1."
  @impl true
  def on_ready(_engine_facade) do
    case FacadeStore.get() do
      nil ->
        {:error, :facade_missing_from_store}

      stored_facade ->
        case RegressionTesterWorker.start_link(facade: stored_facade) do
          {:ok, _worker_pid} -> :ok
          {:error, reason} -> {:error, {:worker_start_failed, reason}}
        end
    end
  end
end

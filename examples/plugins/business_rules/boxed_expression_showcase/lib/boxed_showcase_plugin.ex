defmodule Examples.BusinessRules.BoxedExpressionShowcase.BoxedShowcasePlugin do
  @moduledoc """
  Lifecycle plugin that deploys the expression-showcase DMN and BPMN fixtures,
  runs compensation evaluation, and logs a CL3 expression-type report.
  """

  @behaviour BfwEngine.Plugin

  alias Examples.BusinessRules.BoxedExpressionShowcase.{BoxedShowcaseWorker, FacadeStore}

  @doc "Persists the engine facade for the showcase worker started from on_ready/1."
  @impl true
  def on_load(engine_facade) do
    :ok = FacadeStore.put(engine_facade)
    :ok
  end

  @doc "Starts the boxed expression showcase worker using the facade stored during on_load/1."
  @impl true
  def on_ready(_engine_facade) do
    case FacadeStore.get() do
      nil ->
        {:error, :facade_missing_from_store}

      stored_facade ->
        case BoxedShowcaseWorker.start_link(facade: stored_facade) do
          {:ok, _worker_pid} -> :ok
          {:error, reason} -> {:error, {:worker_start_failed, reason}}
        end
    end
  end
end

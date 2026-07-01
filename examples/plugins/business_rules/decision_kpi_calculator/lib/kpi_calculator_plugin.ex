defmodule Examples.BusinessRules.KpiCalculator.KpiCalculatorPlugin do
  @moduledoc """
  Example plugin that registers the decision KPI calculator event sink.

  Observes DMN Business Rule Task completions via `EngineEventBus` and
  maintains in-memory latency, throughput, and rule-hit aggregates.
  """

  @behaviour EvilEngine.Plugin

  alias Examples.BusinessRules.KpiCalculator.Sink

  @doc "Registers the decision KPI calculator sink on engine load."
  @impl true
  def on_load(engine_facade) do
    engine_facade.register_event_sink.("decision_kpi_calculator", Sink, [])
    :ok
  end

  @doc "Performs no extra work once every plugin has finished loading."
  @impl true
  def on_ready(_engine_facade), do: :ok
end

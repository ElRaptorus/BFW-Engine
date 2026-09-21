defmodule Examples.BusinessRules.DecisionAnalytics.DecisionAnalyticsPlugin do
  @moduledoc """
  Example plugin that registers the decision analytics event sink and report scheduler.

  Observes DMN Business Rule Task completions via `EngineEventBus`, maintains
  in-memory latency histograms and rule-hit aggregates, flags rolling-window
  latency spikes, and periodically logs a JSON analytics report.
  """

  @behaviour BfwEngine.Plugin

  alias Examples.BusinessRules.DecisionAnalytics.AnalyticsSink
  alias Examples.BusinessRules.DecisionAnalytics.ReportScheduler

  @doc "Registers the decision analytics sink and starts the periodic report scheduler."
  @impl true
  def on_load(engine_facade) do
    engine_facade.register_event_sink.("decision_analytics", AnalyticsSink, [])

    case ReportScheduler.start_link([]) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> {:error, {:report_scheduler_start_failed, reason}}
    end
  end

  @doc "Performs no extra work once every plugin has finished loading."
  @impl true
  def on_ready(_engine_facade), do: :ok
end

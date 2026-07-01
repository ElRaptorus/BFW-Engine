defmodule Examples.BusinessRules.DecisionTracePublisher.TracePublisherPlugin do
  @moduledoc """
  Example plugin that registers the decision trace publisher event sink.

  Observes DMN Business Rule Task completions and publishes structured audit
  payloads via a configurable delivery function.
  """

  @behaviour EvilEngine.Plugin

  alias Examples.BusinessRules.DecisionTracePublisher.Sink

  @doc "Registers the decision trace publisher sink on engine load."
  @impl true
  def on_load(engine_facade) do
    engine_facade.register_event_sink.("decision_trace_publisher", Sink, [])
    :ok
  end

  @doc "Performs no extra work once every plugin has finished loading."
  @impl true
  def on_ready(_engine_facade), do: :ok
end

defmodule Examples.BusinessRules.DecisionAnalytics.AnalyticsSink do
  @moduledoc """
  Event sink that records DMN Business Rule Task analytics and flags latency spikes.

  Listens for `FlowNodeInstanceFinished` events where the flow node is a
  Business Rule Task in DMN mode. Extracts evaluation metadata from
  `type_properties` and forwards observations to `AnalyticsCollector`.
  After each record, `AnomalyDetector` checks the rolling latency window
  and logs a warning when a spike is detected.
  """

  @behaviour EvilEngine.Plugin.EventSink

  require Logger

  alias EvilEngine.Types.Event
  alias Examples.BusinessRules.DecisionAnalytics.AnalyticsCollector
  alias Examples.BusinessRules.DecisionAnalytics.AnomalyDetector

  @doc "Starts the analytics collector agent and stores its registered name in sink state."
  @impl true
  def init(options) do
    collector_name = Keyword.get(options, :collector_name, AnalyticsCollector)
    anomaly_detector = Keyword.get(options, :anomaly_detector, AnomalyDetector.new())

    case AnalyticsCollector.start_link(name: collector_name) do
      {:ok, _pid} ->
        {:ok, %{collector_name: collector_name, anomaly_detector: anomaly_detector}}

      {:error, {:already_started, _pid}} ->
        {:ok, %{collector_name: collector_name, anomaly_detector: anomaly_detector}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Returns true when the event is a finished DMN Business Rule Task."
  @impl true
  def accepts?(%Event.FlowNodeInstanceFinished{} = event) do
    event.flow_node_type == :business_rule_task and
      dmn_mode?(Map.get(event, :type_properties, %{}))
  end

  @impl true
  def accepts?(_event), do: false

  @doc "Records evaluation metrics and logs a warning when latency is a spike."
  @impl true
  def handle_event(%Event.FlowNodeInstanceFinished{} = event, state) do
    type_properties = Map.get(event, :type_properties, %{})
    decision_ref = property(type_properties, "decision_ref") || "unknown"
    duration_microseconds = property(type_properties, "duration_us") || 0

    previous_latencies =
      case AnalyticsCollector.get_stats_for_decision(decision_ref, name: state.collector_name) do
        %{latencies: latencies} -> latencies
        nil -> []
      end

    AnalyticsCollector.record(
      %{
        decision_ref: decision_ref,
        duration_us: duration_microseconds,
        matched_rules: property(type_properties, "matched_rules")
      },
      name: state.collector_name
    )

    maybe_log_anomaly(state, decision_ref, previous_latencies, duration_microseconds)
    {:ok, state}
  end

  @impl true
  def handle_event(_event, state), do: {:ok, state}

  @doc "Returns without flushing; aggregates remain in the agent until the node stops."
  @impl true
  def handle_shutdown(_state), do: :ok

  defp maybe_log_anomaly(state, decision_ref, previous_latencies, current_latency) do
    result =
      AnomalyDetector.detect(
        state.anomaly_detector,
        decision_ref,
        previous_latencies,
        current_latency
      )

    if result.is_anomaly do
      Logger.warning(
        "decision_analytics: latency spike decision_ref=#{decision_ref} " <>
          "current=#{result.current_latency}us rolling_average=#{result.rolling_average}us " <>
          "spike_factor=#{result.spike_factor}"
      )
    end
  end

  defp dmn_mode?(type_properties) when is_map(type_properties) do
    property(type_properties, "mode") == "dmn"
  end

  defp dmn_mode?(_invalid), do: false

  defp property(type_properties, key) when is_binary(key) do
    Map.get(type_properties, key) || Map.get(type_properties, String.to_atom(key))
  end
end

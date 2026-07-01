defmodule Examples.BusinessRules.KpiCalculator.Sink do
  @moduledoc """
  Event sink that records DMN Business Rule Task evaluation KPIs.

  Listens for `FlowNodeInstanceFinished` events where the flow node is a
  Business Rule Task in DMN mode. Extracts evaluation metadata from
  `type_properties` (forward-compatible via `Map.get/3`) and forwards
  observations to `KpiAggregator`.
  """

  @behaviour EvilEngine.Plugin.EventSink

  alias EvilEngine.Types.Event
  alias Examples.BusinessRules.KpiCalculator.KpiAggregator

  @doc "Starts the KPI aggregator agent and stores its registered name in sink state."
  @impl true
  def init(options) do
    aggregator_name =
      Keyword.get(options, :aggregator_name, KpiAggregator)

    case KpiAggregator.start_link(name: aggregator_name) do
      {:ok, _pid} -> {:ok, %{aggregator_name: aggregator_name}}
      {:error, {:already_started, _pid}} -> {:ok, %{aggregator_name: aggregator_name}}
      {:error, reason} -> {:error, reason}
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

  @doc "Extracts evaluation metrics from the event and records them in the aggregator."
  @impl true
  def handle_event(%Event.FlowNodeInstanceFinished{} = event, state) do
    type_properties = Map.get(event, :type_properties, %{})

    KpiAggregator.record(
      %{
        decision_ref: property(type_properties, "decision_ref"),
        duration_us: property(type_properties, "duration_us"),
        hit_policy: property(type_properties, "hit_policy"),
        matched_rule_count: matched_rule_count(type_properties),
        matched_rules: property(type_properties, "matched_rules"),
        process_instance_id: event.process_instance_id,
        occurred_at: event.occurred_at,
        terminal_state: event.terminal_state,
        total_rule_count: property(type_properties, "total_rule_count")
      },
      name: state.aggregator_name
    )

    {:ok, state}
  end

  @impl true
  def handle_event(_event, state), do: {:ok, state}

  @doc "Returns without flushing; aggregates remain in the agent until the node stops."
  @impl true
  def handle_shutdown(_state), do: :ok

  defp dmn_mode?(type_properties) when is_map(type_properties) do
    property(type_properties, "mode") == "dmn"
  end

  defp dmn_mode?(_invalid), do: false

  defp property(type_properties, key) when is_binary(key) do
    Map.get(type_properties, key) || Map.get(type_properties, String.to_atom(key))
  end

  defp matched_rule_count(type_properties) do
    matched_rules = property(type_properties, "matched_rules") || []

    if is_list(matched_rules) do
      length(matched_rules)
    else
      0
    end
  end
end

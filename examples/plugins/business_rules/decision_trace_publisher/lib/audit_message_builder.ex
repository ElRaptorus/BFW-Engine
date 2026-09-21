defmodule Examples.BusinessRules.DecisionTracePublisher.AuditMessageBuilder do
  @moduledoc """
  Builds structured audit payloads from `FlowNodeInstanceFinished` events.

  Pure functions only — no side effects.
  """

  alias BfwEngine.Types.Event

  @doc """
  Builds an audit message map from a finished flow node event.

  Reads DMN evaluation metadata from `type_properties` when present.
  Missing `trace` becomes an empty map; missing `type_properties` yields nil
  fields for decision-specific keys.
  """
  @spec build(Event.FlowNodeInstanceFinished.t()) :: map()
  def build(%Event.FlowNodeInstanceFinished{} = event) do
    type_properties = Map.get(event, :type_properties, %{})

    %{
      event_type: "dmn_decision_executed",
      timestamp: DateTime.utc_now(),
      process_instance_id: event.process_instance_id,
      flow_node_id: event.flow_node_id,
      decision_ref: property(type_properties, "decision_ref"),
      decision_version_id: property(type_properties, "decision_version_id"),
      hit_policy: property(type_properties, "hit_policy"),
      matched_rules: property(type_properties, "matched_rules"),
      duration_us: property(type_properties, "duration_us"),
      trace: trace_from_properties(type_properties)
    }
  end

  defp trace_from_properties(type_properties) when is_map(type_properties) do
    case property(type_properties, "trace") do
      nil -> %{}
      trace when is_map(trace) -> trace
      _other -> %{}
    end
  end

  defp trace_from_properties(_invalid), do: %{}

  defp property(type_properties, key) when is_binary(key) and is_map(type_properties) do
    Map.get(type_properties, key) || Map.get(type_properties, String.to_atom(key))
  end

  defp property(_type_properties, _key), do: nil
end

defmodule Examples.BusinessRules.DecisionAuditReporter.FniInspector do
  @moduledoc """
  Fetches persisted flow node instances through the facade and extracts DMN
  evaluation metadata from `type_properties`.
  """

  alias EvilEngine.EngineFacade

  @type flow_node_instance_details :: %{
          flow_node_instance_id: String.t(),
          decision_ref: String.t(),
          duration_us: non_neg_integer(),
          matched_rules: [String.t()],
          trace: map() | nil
        }

  @doc """
  Loads each flow node instance by ID. Missing or failing fetches are skipped.
  """
  @spec fetch_all(EngineFacade.t(), [String.t()]) :: [flow_node_instance_details()]
  def fetch_all(%EngineFacade{flow_node_instances: flow_node_instances}, flow_node_instance_ids) do
    Enum.flat_map(flow_node_instance_ids, fn flow_node_instance_id ->
      case fetch_one(flow_node_instances, flow_node_instance_id) do
        {:ok, details} -> [details]
        :skip -> []
      end
    end)
  end

  defp fetch_one(flow_node_instances, flow_node_instance_id) do
    try do
      case flow_node_instances.get.(flow_node_instance_id) do
        {:ok, flow_node_instance} when is_map(flow_node_instance) ->
          {:ok, details_from_flow_node_instance(flow_node_instance_id, flow_node_instance)}

        _missing ->
          :skip
      end
    rescue
      _exception -> :skip
    end
  end

  defp details_from_flow_node_instance(flow_node_instance_id, flow_node_instance) do
    type_properties =
      Map.get(flow_node_instance, :type_properties) ||
        Map.get(flow_node_instance, "typeProperties") ||
        %{}

    %{
      flow_node_instance_id: flow_node_instance_id,
      decision_ref: property(type_properties, "decision_ref") || "unknown",
      duration_us: property(type_properties, "duration_us") || 0,
      matched_rules: normalize_matched_rules(property(type_properties, "matched_rules") || []),
      trace: property(type_properties, "trace")
    }
  end

  defp property(type_properties, key) when is_map(type_properties) and is_binary(key) do
    Map.get(type_properties, key) || Map.get(type_properties, String.to_atom(key))
  end

  defp normalize_matched_rules(rules) when is_list(rules) do
    Enum.map(rules, &normalize_rule_identifier/1)
  end

  defp normalize_matched_rules(_invalid), do: []

  defp normalize_rule_identifier(rule_identifier) when is_binary(rule_identifier),
    do: rule_identifier

  defp normalize_rule_identifier(%{rule_id: rule_identifier}) when is_binary(rule_identifier),
    do: rule_identifier

  defp normalize_rule_identifier(%{"rule_id" => rule_identifier}) when is_binary(rule_identifier),
    do: rule_identifier

  defp normalize_rule_identifier(rule_identifier), do: inspect(rule_identifier)
end

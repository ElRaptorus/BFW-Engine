defmodule Examples.BusinessRules.DecisionAuditReporter.FniInspectorTest do
  use ExUnit.Case, async: true

  alias BfwEngine.EngineFacade
  alias Examples.BusinessRules.DecisionAuditReporter.FniInspector

  defp facade_with_get(get_fun) do
    %EngineFacade{
      engine_id: "test-engine-id",
      engine_name: "test-engine-name",
      version: "0.0.0-test",
      flow_node_instances: %EngineFacade.FlowNodeInstances{get: get_fun}
    }
  end

  test "queries FNI via facade and extracts type_properties" do
    facade =
      facade_with_get(fn "fni-1" ->
        {:ok,
         %{
           type_properties: %{
             decision_ref: "employee-benefits",
             duration_us: 2500,
             matched_rules: ["rule_1", "rule_2"],
             trace: %{decisions: []}
           }
         }}
      end)

    results = FniInspector.fetch_all(facade, ["fni-1"])

    assert results == [
             %{
               flow_node_instance_id: "fni-1",
               decision_ref: "employee-benefits",
               duration_us: 2500,
               matched_rules: ["rule_1", "rule_2"],
               trace: %{decisions: []}
             }
           ]
  end

  test "handles not-found FNI gracefully when facade returns error" do
    facade = facade_with_get(fn _id -> {:error, :not_found} end)
    assert FniInspector.fetch_all(facade, ["missing-fni"]) == []
  end

  test "handles missing type_properties with defaults" do
    facade = facade_with_get(fn "fni-2" -> {:ok, %{}} end)
    [result] = FniInspector.fetch_all(facade, ["fni-2"])

    assert result == %{
             flow_node_instance_id: "fni-2",
             decision_ref: "unknown",
             duration_us: 0,
             matched_rules: [],
             trace: nil
           }
  end

  test "skips FNIs that raise on fetch" do
    facade =
      facade_with_get(fn
        "fni-error" -> raise "connection lost"
        "fni-ok" -> {:ok, %{type_properties: %{decision_ref: "employee-benefits", duration_us: 100}}}
      end)

    results = FniInspector.fetch_all(facade, ["fni-error", "fni-ok"])

    assert length(results) == 1
    assert hd(results).flow_node_instance_id == "fni-ok"
  end
end

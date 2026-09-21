defmodule BfwEngine.Integration.DMN.DmnImportTraceIntegrationTest do
  @moduledoc """
  Integration test verifying import trace presence when a BRT evaluates
  a DMN model that uses cross-model imports (7H.2).
  """
  use BfwEngine.ExecutionCase, async: false

  @moduletag :integration

  describe "BRT + DMN with cross-model import trace" do
    test "FNI type_properties.trace contains import_traces with correct fields" do
      {201, _} = http_deploy_dmn("imported_helper.dmn")
      {201, _} = http_deploy_dmn("importing_model.dmn")
      {201, _} = http_deploy("brt_dmn_import.bpmn")

      {201, body} =
        http_start("BrtDmnImportProcess", %{"payload" => %{"base" => 5}})

      process_instance_id = body["processInstanceId"]
      wait_for_process_instance(process_instance_id)

      flow_node_instances = fetch_flow_node_instances(process_instance_id)
      brt_fni = Enum.find(flow_node_instances, &(&1.flow_node_id == "BRT_import_dmn"))

      assert brt_fni != nil
      trace = brt_fni.type_properties["trace"]
      assert is_map(trace)

      decision_with_import =
        Enum.find(trace["decisions"], fn decision ->
          is_list(decision["import_traces"]) and decision["import_traces"] != []
        end)

      assert decision_with_import != nil,
             "Expected at least one decision with non-empty import_traces"

      [import_trace | _] = decision_with_import["import_traces"]
      assert import_trace["namespace"] == "https://example.com/dmn/helpers"
      assert import_trace["decision_id"] == "Decision_double"
      assert import_trace["source_definitions_id"] == "definitions_helper"
      assert import_trace["result"] == 10
      assert is_integer(import_trace["duration_microseconds"])
      assert import_trace["duration_microseconds"] >= 0
      assert is_map(import_trace["evaluation_trace"])
      nested_decisions = import_trace["evaluation_trace"]["decisions"]
      assert nested_decisions != []
      nested = List.last(nested_decisions)
      assert nested["decision_model_id"] == "Decision_double"
      assert nested["result"] == 10
    end
  end

  describe "ad-hoc DMN evaluation with import trace" do
    test "REST response includes import_traces when model uses imports" do
      {201, _} = http_deploy_dmn("imported_helper.dmn")
      {201, _} = http_deploy_dmn("importing_model.dmn")

      {200, body} =
        http_evaluate_decision("definitions_importing", %{"base" => 5},
          decision_model_id: "Decision_final"
        )

      assert body["result"] == 20
      assert is_map(body["trace"])

      decision_with_import =
        Enum.find(body["trace"]["decisions"], fn decision ->
          is_list(decision["importTraces"]) and decision["importTraces"] != []
        end)

      assert decision_with_import != nil,
             "Expected importTraces in REST response trace"

      [import_trace | _] = decision_with_import["importTraces"]
      assert import_trace["namespace"] == "https://example.com/dmn/helpers"
      assert import_trace["decisionId"] == "Decision_double"
      assert import_trace["sourceDefinitionsId"] == "definitions_helper"
      assert import_trace["result"] == 10
    end
  end
end

defmodule EvilEngine.Integration.DMN.DmnBkmTraceIntegrationTest do
  @moduledoc """
  Integration test verifying BKM trace presence in FNI type_properties
  when a BRT evaluates a DMN model with BKM invocations (7H.1).
  """
  use EvilEngine.ExecutionCase, async: false

  @moduletag :integration

  describe "BRT + DMN with BKM trace" do
    test "FNI type_properties.trace contains bkm_traces with correct fields" do
      {201, _} = http_deploy_dmn("bkm_invocation_literal.dmn")
      {201, _} = http_deploy("brt_dmn_bkm.bpmn")

      {201, body} =
        http_start("BrtDmnBkmProcess", %{
          "payload" => %{"income" => 50_000, "taxRate" => 0.2}
        })

      process_instance_id = body["processInstanceId"]
      wait_for_process_instance(process_instance_id)

      flow_node_instances = fetch_flow_node_instances(process_instance_id)
      brt_fni = Enum.find(flow_node_instances, &(&1.flow_node_id == "BRT_bkm_dmn"))

      assert brt_fni != nil
      trace = brt_fni.type_properties["trace"]
      assert is_map(trace)
      assert is_list(trace["decisions"])

      decision_with_bkm =
        Enum.find(trace["decisions"], fn decision ->
          is_list(decision["bkm_traces"]) and decision["bkm_traces"] != []
        end)

      assert decision_with_bkm != nil,
             "Expected at least one decision with non-empty bkm_traces"

      [bkm_trace | _] = decision_with_bkm["bkm_traces"]
      assert bkm_trace["bkm_id"] == "BKM_tax"
      assert bkm_trace["bkm_name"] == "Tax Calculation"
      assert is_integer(bkm_trace["duration_microseconds"])
      assert bkm_trace["duration_microseconds"] >= 0
      assert bkm_trace["result"] == 10_000
      assert is_list(bkm_trace["formal_parameters"])

      param_names = Enum.map(bkm_trace["formal_parameters"], & &1["name"])
      assert "income" in param_names
      assert "taxRate" in param_names

      income_param =
        Enum.find(bkm_trace["formal_parameters"], &(&1["name"] == "income"))

      assert income_param["bound_value"] == 50_000
    end
  end

  describe "BRT + DMN without BKM" do
    test "FNI type_properties.trace has empty bkm_traces on decisions" do
      {201, _} = http_deploy_dmn("simple_unique.dmn")
      {201, _} = http_deploy("business_rule_task_dmn.bpmn")

      {201, body} =
        http_start("BrtDmnProcess", %{"payload" => %{"age" => 25}})

      process_instance_id = body["processInstanceId"]
      wait_for_process_instance(process_instance_id)

      flow_node_instances = fetch_flow_node_instances(process_instance_id)
      brt_fni = Enum.find(flow_node_instances, &(&1.flow_node_id == "BRT_dmn"))

      assert brt_fni != nil
      trace = brt_fni.type_properties["trace"]

      Enum.each(trace["decisions"], fn decision ->
        assert decision["bkm_traces"] == [],
               "Expected empty bkm_traces for decision without BKM, got: #{inspect(decision["bkm_traces"])}"
      end)
    end
  end
end

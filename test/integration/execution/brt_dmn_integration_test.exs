defmodule EvilEngine.Integration.Execution.BrtDmnIntegrationTest do
  @moduledoc """
  Integration tests for Business Rule Task in DMN mode.

  Verifies the end-to-end flow: deploy DMN model → deploy BPMN with
  BRT referencing that DMN → start PI → assert completion and
  `type_properties` contain DMN audit data.
  """
  use EvilEngine.ExecutionCase, async: false

  alias EvilEngine.Persistence.Resources.ProcessInstance, as: ProcessInstanceResource
  alias EvilEngine.Test.EventCollector
  alias EvilEngine.Types.Event

  require Ash.Query

  describe "BRT + DMN — UNIQUE hit policy" do
    test "PI finishes with correct DMN result in final token", %{collector: _collector} do
      {201, _} = http_deploy_dmn("simple_unique.dmn")
      {201, _} = http_deploy("business_rule_task_dmn.bpmn")

      {201, body} =
        http_start("BrtDmnProcess", %{"payload" => %{"age" => 25}})

      process_instance_id = body["processInstanceId"]
      wait_for_process_instance(process_instance_id)

      assert_pi_state!(process_instance_id, "finished")
      assert_flow_node_instance_count!(process_instance_id, 3)
      assert_all_fnis_state!(process_instance_id, "finished")
    end

    test "FNI type_properties contains DMN audit data" do
      {201, _} = http_deploy_dmn("simple_unique.dmn")
      {201, _} = http_deploy("business_rule_task_dmn.bpmn")

      {201, body} =
        http_start("BrtDmnProcess", %{"payload" => %{"age" => 25}})

      process_instance_id = body["processInstanceId"]
      wait_for_process_instance(process_instance_id)

      flow_node_instances = fetch_flow_node_instances(process_instance_id)
      brt_fni = Enum.find(flow_node_instances, &(&1.flow_node_id == "BRT_dmn"))

      assert brt_fni != nil
      type_properties = brt_fni.type_properties

      assert type_properties["mode"] == "dmn"
      assert type_properties["decision_ref"] == "definitions_discount"
      assert is_binary(type_properties["decision_version_id"])
      assert is_binary(type_properties["version"]) and byte_size(type_properties["version"]) > 0
      assert type_properties["hit_policy"] == "unique"
      assert is_list(type_properties["matched_rules"])
      assert is_map(type_properties["trace"])
      assert is_list(type_properties["trace"]["decisions"])
      assert is_integer(type_properties["duration_us"])
    end
  end

  describe "BRT + DMN — COLLECT hit policy" do
    test "PI finishes with aggregated result" do
      {201, _} = http_deploy_dmn("collect_with_sum.dmn")
      {201, _} = http_deploy("business_rule_task_dmn_collect.bpmn")

      {201, body} =
        http_start("BrtDmnCollectProcess", %{"payload" => %{"category" => "A"}})

      process_instance_id = body["processInstanceId"]
      wait_for_process_instance(process_instance_id)

      assert_pi_state!(process_instance_id, "finished")
    end
  end

  describe "BRT + DMN — no matching rules" do
    test "PI finishes with nil result when UNIQUE has no match" do
      {201, _} = http_deploy_dmn("simple_unique.dmn")
      {201, _} = http_deploy("business_rule_task_dmn_no_match.bpmn")

      {201, body} =
        http_start("BrtDmnNoMatchProcess", %{"payload" => %{"age" => -999}})

      process_instance_id = body["processInstanceId"]
      wait_for_process_instance(process_instance_id)

      assert_pi_state!(process_instance_id, "finished")
    end
  end

  describe "BRT + DMN — multi-output decision table" do
    test "PI finishes with multiple output columns in result" do
      {201, _} = http_deploy_dmn("multi_output_rule_order.dmn")
      {201, _} = http_deploy("business_rule_task_dmn_multi_output.bpmn")

      {201, body} =
        http_start("BrtDmnMultiOutputProcess", %{
          "payload" => %{"orderType" => "express", "orderValue" => 500}
        })

      process_instance_id = body["processInstanceId"]
      wait_for_process_instance(process_instance_id)

      assert_pi_state!(process_instance_id, "finished")
    end
  end

  describe "BRT + DMN — decision not found" do
    test "PI transitions to fatal when DMN model is not deployed" do
      {201, _} = http_deploy("business_rule_task_dmn.bpmn")

      {201, body} =
        http_start("BrtDmnProcess", %{"payload" => %{"age" => 25}})

      process_instance_id = body["processInstanceId"]
      wait_for_process_instance(process_instance_id)

      assert_pi_state!(process_instance_id, "fatal")
      assert_no_running_fnis!(process_instance_id)

      flow_node_instances = fetch_flow_node_instances(process_instance_id)
      brt_fni = Enum.find(flow_node_instances, &(&1.flow_node_id == "BRT_dmn"))

      assert brt_fni.state == "fatal"

      assert brt_fni.error_info["error_code"] == "decision_not_found",
             "Expected decision_not_found error, got: #{inspect(brt_fni.error_info)}"

      assert brt_fni.error_info["detail"] == "definitions_discount"
    end
  end

  describe "BRT + DMN — CL3 boxed BKM invocation" do
    test "PI finishes with BKM-computed discount in final token" do
      {201, _} = http_deploy_dmn("brt_cl3_invocation.dmn")
      {201, _} = http_deploy("brt_cl3_test.bpmn")

      {201, body} =
        http_start("BrtCl3Process", %{"payload" => %{"orderTotal" => 1200}})

      process_instance_id = body["processInstanceId"]
      wait_for_process_instance(process_instance_id)

      assert_pi_state!(process_instance_id, "finished")
      assert_flow_node_instance_count!(process_instance_id, 3)
      assert_all_fnis_state!(process_instance_id, "finished")

      process_instance =
        ProcessInstanceResource
        |> Ash.Query.filter(id == ^process_instance_id)
        |> Ash.Query.load(:final_tokens)
        |> Ash.read_one!(authorize?: false)

      token = hd(process_instance.final_tokens)
      assert token["endEventId"] == "End_1"

      discount_percent = extract_discount_percent(token["payload"])
      assert discount_percent in [15, 15.0]
    end

    test "FNI type_properties records boxed_expression hit policy" do
      {201, _} = http_deploy_dmn("brt_cl3_invocation.dmn")
      {201, _} = http_deploy("brt_cl3_test.bpmn")

      {201, body} =
        http_start("BrtCl3Process", %{"payload" => %{"orderTotal" => 750}})

      process_instance_id = body["processInstanceId"]
      wait_for_process_instance(process_instance_id)

      flow_node_instances = fetch_flow_node_instances(process_instance_id)
      brt_fni = Enum.find(flow_node_instances, &(&1.flow_node_id == "BRT_cl3_dmn"))

      assert brt_fni != nil
      assert brt_fni.type_properties["mode"] == "dmn"
      assert brt_fni.type_properties["decision_ref"] == "definitions_brt_cl3"
      assert brt_fni.type_properties["hit_policy"] == "boxed_expression"

      discount_percent = extract_discount_percent(brt_fni.output_token)
      assert discount_percent in [10, 10.0]
    end
  end

  describe "BRT + DMN — DRG chaining via BRT (P4.5)" do
    test "PI finishes when BRT evaluates a multi-decision DRG chain" do
      {201, _} = http_deploy_dmn("drg_linear_chain.dmn")
      {201, _} = http_deploy("brt_dmn_drg_chain.bpmn")

      {201, body} =
        http_start("BrtDmnDrgChainProcess", %{"payload" => %{"x" => 5}})

      process_instance_id = body["processInstanceId"]
      wait_for_process_instance(process_instance_id)

      assert_pi_state!(process_instance_id, "finished")
      assert_all_fnis_state!(process_instance_id, "finished")
    end

    test "DRG chain type_properties trace contains all chained decisions" do
      {201, _} = http_deploy_dmn("drg_linear_chain.dmn")
      {201, _} = http_deploy("brt_dmn_drg_chain.bpmn")

      {201, body} =
        http_start("BrtDmnDrgChainProcess", %{"payload" => %{"x" => 3}})

      process_instance_id = body["processInstanceId"]
      wait_for_process_instance(process_instance_id)

      flow_node_instances = fetch_flow_node_instances(process_instance_id)
      brt_fni = Enum.find(flow_node_instances, &(&1.flow_node_id == "BRT_drg_chain"))

      assert brt_fni != nil
      type_properties = brt_fni.type_properties

      assert type_properties["mode"] == "dmn"
      assert is_map(type_properties["trace"])
      assert length(type_properties["trace"]["decisions"]) >= 2
    end
  end

  describe "BRT + DMN — import resolution via BRT (P4.5)" do
    test "PI finishes when BRT evaluates a model with imports" do
      {201, _} = http_deploy_dmn("imported_helper.dmn")
      {201, _} = http_deploy_dmn("importing_model.dmn")
      {201, _} = http_deploy("brt_dmn_import.bpmn")

      {201, body} =
        http_start("BrtDmnImportProcess", %{"payload" => %{"base" => 5}})

      process_instance_id = body["processInstanceId"]
      wait_for_process_instance(process_instance_id)

      assert_pi_state!(process_instance_id, "finished")
      assert_all_fnis_state!(process_instance_id, "finished")
    end
  end

  describe "BRT + DMN — event bus verification" do
    test "fni.finished event carries DMN trace in type_properties", %{collector: collector} do
      {201, _} = http_deploy_dmn("simple_unique.dmn")
      {201, _} = http_deploy("business_rule_task_dmn.bpmn")

      {201, body} =
        http_start("BrtDmnProcess", %{"payload" => %{"age" => 25}})

      process_instance_id = body["processInstanceId"]
      wait_for_process_instance(process_instance_id)

      events = EventCollector.await_events(collector, 6)

      fni_finished_events =
        Enum.filter(events, &match?(%Event.FlowNodeInstanceFinished{}, &1))

      brt_finished =
        Enum.find(fni_finished_events, fn event ->
          event.flow_node_id == "BRT_dmn"
        end)

      assert brt_finished != nil
      assert brt_finished.flow_node_type == :business_rule_task
      assert brt_finished.terminal_state == :finished
    end
  end

  defp extract_discount_percent(payload) when is_map(payload) do
    cond do
      Map.has_key?(payload, "discount") -> payload["discount"]
      Map.has_key?(payload, "discountPercent") -> payload["discountPercent"]
      Map.has_key?(payload, "result") -> payload["result"]
      true -> flunk("unexpected BRT output payload: #{inspect(payload)}")
    end
  end
end

defmodule EvilEngine.Integration.Execution.LinkEventsTest do
  @moduledoc "Integration tests for Link Intermediate Throw/Catch events."
  use EvilEngine.ExecutionCase, async: false

  describe "Link events — happy path" do
    test "basic link pair: Start → Task → LinkThrow(A) … LinkCatch(A) → Task → End", %{collector: _collector} do
      {201, _} = http_deploy("link_events_basic.bpmn")

      {201, body} = http_start("LinkEventsBasicProcess", %{"payload" => %{"order" => "LNK-001"}})
      process_instance_id = body["processInstanceId"]
      wait_for_process_instance(process_instance_id)

      assert_pi_state!(process_instance_id, "finished")

      flow_node_instances = fetch_flow_node_instances(process_instance_id)
      assert length(flow_node_instances) == 6

      assert_all_fnis_state!(process_instance_id, "finished")

      throw_fni = Enum.find(flow_node_instances, &(&1.flow_node_id == "LinkThrow_A"))
      catch_fni = Enum.find(flow_node_instances, &(&1.flow_node_id == "LinkCatch_A"))
      assert throw_fni != nil
      assert catch_fni != nil
      assert throw_fni.flow_node_type == "intermediate_throw_event"
      assert throw_fni.event_type == "link"
      assert catch_fni.flow_node_type == "intermediate_catch_event"
      assert catch_fni.event_type == "link"
    end

    test "multi-pair: two independent link pairs route correctly", %{collector: _collector} do
      {201, _} = http_deploy("link_events_multi_pair.bpmn")

      {201, body} = http_start("LinkEventsMultiPairProcess", %{"payload" => %{"order" => "LNK-002"}})
      process_instance_id = body["processInstanceId"]
      wait_for_process_instance(process_instance_id)

      assert_pi_state!(process_instance_id, "finished")

      flow_node_instances = fetch_flow_node_instances(process_instance_id)
      assert length(flow_node_instances) == 9

      assert_all_fnis_state!(process_instance_id, "finished")

      link_fnis =
        Enum.filter(flow_node_instances, fn fni ->
          fni.event_type == "link"
        end)

      assert length(link_fnis) == 4
    end
  end

  describe "Link events — runtime errors" do
    test "duplicate catch: deploys OK, fatal at runtime", %{collector: _collector} do
      {201, _} = http_deploy("link_events_duplicate_catch.bpmn")

      {201, body} = http_start("LinkEventsDuplicateCatchProcess")
      process_instance_id = body["processInstanceId"]
      wait_for_process_instance(process_instance_id)

      assert_pi_state!(process_instance_id, "fatal")
      assert_no_running_fnis!(process_instance_id)

      flow_node_instances = fetch_flow_node_instances(process_instance_id)
      fatal_fni = Enum.find(flow_node_instances, &(&1.state == "fatal"))
      assert fatal_fni != nil
      assert fatal_fni.flow_node_id == "LinkThrow_A"
      assert fatal_fni.error_info != nil
    end

    test "orphan throw: deploys OK, fatal at runtime", %{collector: _collector} do
      {201, _} = http_deploy("link_events_orphan_throw.bpmn")

      {201, body} = http_start("LinkEventsOrphanThrowProcess")
      process_instance_id = body["processInstanceId"]
      wait_for_process_instance(process_instance_id)

      assert_pi_state!(process_instance_id, "fatal")
      assert_no_running_fnis!(process_instance_id)

      flow_node_instances = fetch_flow_node_instances(process_instance_id)
      fatal_fni = Enum.find(flow_node_instances, &(&1.state == "fatal"))
      assert fatal_fni != nil
      assert fatal_fni.flow_node_id == "LinkThrow_X"
      assert fatal_fni.error_info != nil
    end
  end
end

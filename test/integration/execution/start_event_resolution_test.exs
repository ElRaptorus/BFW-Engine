defmodule EvilEngine.Integration.Execution.StartEventResolutionTest do
  @moduledoc "Integration tests for multi-start-event disambiguation."
  use EvilEngine.ExecutionCase, async: false

  setup do
    {201, _} = http_deploy("multi_start_events.bpmn")
    :ok
  end

  describe "start event disambiguation" do
    test "start_event_id: Start_A → PI runs path A" do
      {201, body} =
        http_start("MultiStartEvents", %{
          "startEventId" => "Start_A",
          "payload" => %{"path" => "A"}
        })

      process_instance_id = body["processInstanceId"]
      wait_for_process_instance(process_instance_id)

      assert_pi_state!(process_instance_id, "finished")

      flow_node_instances = fetch_flow_node_instances(process_instance_id)
      flow_node_ids = Enum.map(flow_node_instances, & &1.flow_node_id) |> MapSet.new()

      assert MapSet.member?(flow_node_ids, "Start_A")
      assert MapSet.member?(flow_node_ids, "Task_A")
      assert MapSet.member?(flow_node_ids, "End_A")
      refute MapSet.member?(flow_node_ids, "Start_B")
      refute MapSet.member?(flow_node_ids, "Task_B")
    end

    test "start_event_id: Start_B → PI runs path B" do
      {201, body} =
        http_start("MultiStartEvents", %{
          "startEventId" => "Start_B",
          "payload" => %{"path" => "B"}
        })

      process_instance_id = body["processInstanceId"]
      wait_for_process_instance(process_instance_id)

      assert_pi_state!(process_instance_id, "finished")

      flow_node_instances = fetch_flow_node_instances(process_instance_id)
      flow_node_ids = Enum.map(flow_node_instances, & &1.flow_node_id) |> MapSet.new()

      assert MapSet.member?(flow_node_ids, "Start_B")
      assert MapSet.member?(flow_node_ids, "Task_B")
      assert MapSet.member?(flow_node_ids, "End_B")
      refute MapSet.member?(flow_node_ids, "Start_A")
      refute MapSet.member?(flow_node_ids, "Task_A")
    end

    test "no start_event_id with multiple starts → 422 error" do
      {422, body} = http_start("MultiStartEvents", %{"payload" => %{}})
      assert body["error"] == "ambiguous_start_event"
    end

    test "nonexistent start_event_id → 422 error" do
      {422, body} =
        http_start("MultiStartEvents", %{"startEventId" => "Nonexistent"})

      assert body["error"] == "start_event_not_found"
    end
  end
end

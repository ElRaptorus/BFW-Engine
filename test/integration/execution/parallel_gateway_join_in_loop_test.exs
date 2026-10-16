defmodule BfwEngine.Integration.Execution.ParallelGatewayJoinInLoopTest do
  @moduledoc "Regression: a parallel join inside a cycle fires on every pass of the same process instance (B1)."
  use BfwEngine.ExecutionCase, async: false

  describe "B1: loop back into a parallel join" do
    test "the join fires again on the second pass and the process instance finishes" do
      process_instance_id =
        http_deploy_and_start("parallel_gateway_join_in_loop.bpmn", "ParallelGatewayJoinInLoop")

      finish_result = await_process_instance_state(process_instance_id, "finished")
      flow_node_instances = fetch_flow_node_instances(process_instance_id)

      assert finished_count(flow_node_instances, "Gateway_Join") == 2
      assert finished_count(flow_node_instances, "Script_Increment") == 2
      assert finished_count(flow_node_instances, "End_1") == 1
      assert {:ok, _process_instance} = finish_result
    end
  end

  defp finished_count(flow_node_instances, flow_node_id) do
    Enum.count(
      flow_node_instances,
      &(&1.flow_node_id == flow_node_id and &1.state == "finished")
    )
  end
end

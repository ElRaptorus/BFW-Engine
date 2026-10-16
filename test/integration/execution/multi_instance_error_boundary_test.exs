defmodule BfwEngine.Integration.Execution.MultiInstanceErrorBoundaryTest do
  @moduledoc "Regression: an error boundary on a parallel Multi-Instance Call Activity fires once for the shell (F2)."
  use BfwEngine.ExecutionCase, async: false

  describe "F2: error boundary on a parallel Multi-Instance Call Activity" do
    test "child Error End takes the catch-all boundary once and interrupts the shell" do
      {201, _} = http_deploy("call_activity_multi_instance_parallel_error_boundary.bpmn")

      {201, start_body} =
        http_start("CallActivityMiParallelErrorBoundary", %{"payload" => %{"items" => [1, 2]}})

      process_instance_id = start_body["processInstanceId"]

      finish_result =
        await_process_instance_state(process_instance_id, "finished", timeout: 10_000)

      flow_node_instances = fetch_flow_node_instances(process_instance_id)

      assert finished_count(flow_node_instances, "Boundary_Error") == 1
      assert finished_count(flow_node_instances, "End_Error_Path") == 1
      assert finished_count(flow_node_instances, "End_Success") == 0

      shell =
        Enum.find(
          flow_node_instances,
          &(&1.flow_node_id == "Call_Child" and is_nil(&1.iteration_index))
        )

      assert shell.state == "interrupted"

      iteration_states =
        for flow_node_instance <- flow_node_instances,
            flow_node_instance.flow_node_id == "Call_Child",
            flow_node_instance.iteration_index != nil,
            do: flow_node_instance.state

      assert iteration_states == ["interrupted", "interrupted"]
      assert {:ok, _process_instance} = finish_result
    end
  end

  describe "F2: an error raised by the Multi-Instance shell itself" do
    test "is matched against the error boundaries of the activity" do
      {201, _} = http_deploy("mi_parallel_max_iterations_boundary.bpmn")

      {201, start_body} =
        http_start("mi-parallel-max-iterations-boundary", %{"payload" => %{"items" => [1, 2]}})

      process_instance_id = start_body["processInstanceId"]

      finish_result =
        await_process_instance_state(process_instance_id, "finished", timeout: 10_000)

      flow_node_instances = fetch_flow_node_instances(process_instance_id)

      assert match?({:ok, _process_instance}, finish_result),
             "process instance did not finish: " <>
               inspect(
                 Enum.map(
                   flow_node_instances,
                   &{&1.flow_node_id, &1.state, &1.type_properties, &1.error_info}
                 )
               )

      assert finished_count(flow_node_instances, "Boundary_Error") == 1
      assert finished_count(flow_node_instances, "End_Error") == 1
      assert find_fni_by_flow_node_id(process_instance_id, "Task_1").state == "interrupted"
    end
  end

  defp finished_count(flow_node_instances, flow_node_id) do
    Enum.count(
      flow_node_instances,
      &(&1.flow_node_id == flow_node_id and &1.state == "finished")
    )
  end
end

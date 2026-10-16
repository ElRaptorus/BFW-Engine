defmodule BfwEngine.Integration.Execution.JoinGatewayBookkeepingTest do
  @moduledoc """
  Join gateway bookkeeping (bug hunt Batch 2.1 and 2.2): joins fire again on
  every pass through a loop, arrivals are keyed by the incoming sequence flow,
  duplicate arrivals on an unfired join are fatal, a Complex Join's region
  cancel reaches boundary events, and resumed joins whose persisted arrivals
  carry no flow id still fire.
  """
  use BfwEngine.ExecutionCase, async: false

  alias BfwEngine.Execution.ResumeRunner
  alias BfwEngine.Persistence.Repo

  describe "B1: loop back into an inclusive or complex join" do
    test "the inclusive join fires on both passes" do
      process_instance_id =
        http_deploy_and_start("inclusive_gateway_join_in_loop.bpmn", "InclusiveGatewayJoinInLoop")

      assert {:ok, _process_instance} =
               await_process_instance_state(process_instance_id, "finished")

      flow_node_instances = fetch_flow_node_instances(process_instance_id)
      assert finished_count(flow_node_instances, "Gateway_Join") == 2
      assert finished_count(flow_node_instances, "Script_Increment") == 2
    end

    test "the complex join fires on both passes" do
      process_instance_id =
        http_deploy_and_start("complex_gateway_join_in_loop.bpmn", "ComplexGatewayJoinInLoop")

      assert {:ok, _process_instance} =
               await_process_instance_state(process_instance_id, "finished")

      flow_node_instances = fetch_flow_node_instances(process_instance_id)
      assert finished_count(flow_node_instances, "Gateway_Join") == 2
      assert finished_count(flow_node_instances, "Script_Increment") == 2
    end
  end

  describe "B6: two sequence flows from one fork into the same parallel join" do
    test "each flow counts as its own arrival and the join fires" do
      process_instance_id =
        http_deploy_and_start("parallel_gateway_twin_flows.bpmn", "ParallelGatewayTwinFlows")

      assert {:ok, _process_instance} =
               await_process_instance_state(process_instance_id, "finished")

      flow_node_instances = fetch_flow_node_instances(process_instance_id)
      assert finished_count(flow_node_instances, "Gateway_Join") == 1
      assert finished_count(flow_node_instances, "End_1") == 1
    end
  end

  describe "B5: duplicate arrival on an unfired parallel join" do
    test "the join fatals with duplicate_join_arrival" do
      process_instance_id =
        http_deploy_and_start(
          "parallel_gateway_duplicate_arrival.bpmn",
          "ParallelGatewayDuplicateArrival"
        )

      assert {:ok, _process_instance} =
               await_process_instance_state(process_instance_id, "fatal")

      join = find_fni_by_flow_node_id(process_instance_id, "Gateway_Join")
      assert join.state == "fatal"
      assert join.error_info["error_code"] == "duplicate_join_arrival"
      assert join.error_info["message"] =~ "Flow_Merged"
    end

    test "the arrival rows survive the fatal and a retry rebuilds the join" do
      process_instance_id =
        http_deploy_and_start(
          "parallel_gateway_duplicate_arrival.bpmn",
          "ParallelGatewayDuplicateArrival"
        )

      {:ok, _process_instance} = await_process_instance_state(process_instance_id, "fatal")
      join = find_fni_by_flow_node_id(process_instance_id, "Gateway_Join")

      assert [["Flow_Merged"]] =
               Repo.query!(
                 "SELECT source_branch_sequence_flow_id FROM gateway_pending_arrivals " <>
                   "WHERE gateway_flow_node_instance_id = $1",
                 [Ecto.UUID.dump!(join.id)]
               ).rows

      {204, _} = http_retry_process_instance(process_instance_id)
      {:ok, wait_task} = await_waiting_fni_by_node_id(process_instance_id, "UserTask_Wait")
      {204, _} = http_finish_user_task(wait_task.id, %{})

      assert {:ok, _process_instance} =
               await_process_instance_state(process_instance_id, "finished")

      flow_node_instances = fetch_flow_node_instances(process_instance_id)
      assert finished_count(flow_node_instances, "Gateway_Join") == 1
      assert finished_count(flow_node_instances, "End_1") == 1
    end
  end

  describe "B3: complex join region cancel" do
    test "interrupts the boundary events of the cancelled hosts" do
      process_instance_id =
        http_deploy_and_start(
          "complex_gateway_cancel_region_boundary.bpmn",
          "ComplexGatewayCancelRegionBoundary"
        )

      assert {:ok, _process_instance} =
               await_process_instance_state(process_instance_id, "finished")

      assert find_fni_by_flow_node_id(process_instance_id, "UserTask_B").state == "interrupted"
      assert find_fni_by_flow_node_id(process_instance_id, "Timer_B").state == "interrupted"
      refute find_fni_by_flow_node_id(process_instance_id, "End_Timeout")
    end
  end

  describe "B7: resumed inclusive join whose arrivals carry no flow id" do
    test "fires through dead-path elimination once the other branch is dead" do
      process_instance_id =
        http_deploy_and_start(
          "inclusive_join_resume_unknown_arrival.bpmn",
          "InclusiveJoinResumeUnknownArrival"
        )

      {:ok, _user_task} = await_waiting_fni_by_node_id(process_instance_id, "UserTask_B")
      {:ok, _join} = await_waiting_fni_by_node_id(process_instance_id, "InclusiveJoin")

      stop_all_process_instances()

      Repo.query!(
        "UPDATE gateway_pending_arrivals SET source_branch_sequence_flow_id = 'unknown' " <>
          "WHERE process_instance_id = $1",
        [Ecto.UUID.dump!(process_instance_id)]
      )

      {:ok, 1} = ResumeRunner.resume_all()
      {:ok, _process_instance_pid} = poll_pi_alive(process_instance_id)

      {:ok, user_task} = await_waiting_fni_by_node_id(process_instance_id, "UserTask_B")
      {204, _} = http_finish_user_task(user_task.id, %{"skip" => true})

      assert {:ok, _process_instance} =
               await_process_instance_state(process_instance_id, "finished")

      flow_node_instances = fetch_flow_node_instances(process_instance_id)
      assert finished_count(flow_node_instances, "InclusiveJoin") == 1
      assert finished_count(flow_node_instances, "End_1") == 1
      assert finished_count(flow_node_instances, "End_Skip") == 1
    end
  end

  defp finished_count(flow_node_instances, flow_node_id) do
    Enum.count(
      flow_node_instances,
      &(&1.flow_node_id == flow_node_id and &1.state == "finished")
    )
  end

  defp stop_all_process_instances do
    BfwEngine.Execution.Supervisor
    |> DynamicSupervisor.which_children()
    |> Enum.each(fn {_id, pid, _type, _modules} ->
      monitor_reference = Process.monitor(pid)
      DynamicSupervisor.terminate_child(BfwEngine.Execution.Supervisor, pid)
      assert_receive {:DOWN, ^monitor_reference, :process, ^pid, _reason}, 5_000
    end)
  end
end

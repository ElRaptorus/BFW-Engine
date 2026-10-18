defmodule BfwEngine.Integration.Execution.CrashedChildCleanupTest do
  @moduledoc """
  A child instance killed without running `terminate/3` is cleaned up by its
  parent's awaiting shell: live FNIs fatal, a state event, descendants fatal.
  """
  use BfwEngine.ExecutionCase, async: false

  alias BfwEngine.Execution
  alias BfwEngine.Test.EventCollector
  alias BfwEngine.Types.Event

  test "a killed child has its live rows, its event, and its running grandchild set fatal" do
    {:ok, collector} = EventCollector.start_link(self())

    process_instance_id =
      http_deploy_and_start("crashed_child_cleanup.bpmn", "CrashedChildParent")

    child_process_instance_id = called_instance_id(process_instance_id, "Call_Middle")
    {:ok, middle_task} = await_waiting_fni_by_node_id(child_process_instance_id, "UT_Middle")
    grandchild_process_instance_id = called_instance_id(child_process_instance_id, "Call_Leaf")
    {:ok, leaf_task} = await_waiting_fni_by_node_id(grandchild_process_instance_id, "UT_Leaf")

    {:ok, child_pid} = Execution.lookup_process_instance(child_process_instance_id)
    Process.exit(child_pid, :kill)

    assert {:ok, _parent} = await_process_instance_state(process_instance_id, "fatal")

    assert {:ok, child} = await_process_instance_state(child_process_instance_id, "fatal")
    assert child.error_info["error_code"] == "process_instance_crashed"

    assert {:ok, _grandchild} =
             await_process_instance_state(grandchild_process_instance_id, "fatal")

    assert [%{state: "fatal"}] = flow_node_instances_for(child_process_instance_id, "UT_Middle")
    assert [%{state: "fatal"}] = flow_node_instances_for(child_process_instance_id, "Call_Leaf")

    assert [%{state: "fatal"}] =
             flow_node_instances_for(grandchild_process_instance_id, "UT_Leaf")

    events = EventCollector.get_events(collector)
    middle_task_id = middle_task.id
    leaf_task_id = leaf_task.id

    assert Enum.any?(
             events,
             &match?(
               %Event.UserTaskFinished{flow_node_instance_id: ^middle_task_id, outcome: :aborted},
               &1
             )
           )

    assert Enum.any?(
             events,
             &match?(%Event.UserTaskFinished{flow_node_instance_id: ^leaf_task_id}, &1)
           )

    assert Enum.any?(
             events,
             &match?(
               %Event.ProcessInstanceStateChanged{
                 process_instance_id: ^child_process_instance_id,
                 process_model_id: "CrashedChildMiddle",
                 root_process_instance_id: ^process_instance_id,
                 new_state: :fatal
               },
               &1
             )
           )
  end

  test "a running grandchild without a process is written fatal with its live rows" do
    process_instance_id =
      http_deploy_and_start("crashed_child_cleanup.bpmn", "CrashedChildParent")

    child_process_instance_id = called_instance_id(process_instance_id, "Call_Middle")
    {:ok, _middle_task} = await_waiting_fni_by_node_id(child_process_instance_id, "UT_Middle")
    grandchild_process_instance_id = called_instance_id(child_process_instance_id, "Call_Leaf")
    {:ok, _leaf_task} = await_waiting_fni_by_node_id(grandchild_process_instance_id, "UT_Leaf")

    {:ok, child_pid} = Execution.lookup_process_instance(child_process_instance_id)
    {:ok, grandchild_pid} = Execution.lookup_process_instance(grandchild_process_instance_id)
    child_monitor = Process.monitor(child_pid)
    grandchild_monitor = Process.monitor(grandchild_pid)
    Process.exit(child_pid, :kill)
    Process.exit(grandchild_pid, :kill)
    assert_receive {:DOWN, ^child_monitor, :process, ^child_pid, :killed}, 5_000
    assert_receive {:DOWN, ^grandchild_monitor, :process, ^grandchild_pid, :killed}, 5_000

    assert {:ok, _parent} = await_process_instance_state(process_instance_id, "fatal")

    assert {:ok, grandchild} =
             await_process_instance_state(grandchild_process_instance_id, "fatal")

    assert grandchild.error_info["error_code"] == "process_instance_crashed"
    assert [%{state: "fatal"}] = flow_node_instances_for(grandchild_process_instance_id, "UT_Leaf")
  end

  defp called_instance_id(process_instance_id, call_activity_node_id) do
    {:ok, call_activity} =
      await_waiting_fni_by_node_id(process_instance_id, call_activity_node_id)

    call_activity.type_properties["child_process_instance_id"]
  end

  defp flow_node_instances_for(process_instance_id, flow_node_id) do
    process_instance_id
    |> fetch_flow_node_instances()
    |> Enum.filter(&(&1.flow_node_id == flow_node_id))
  end
end

defmodule BfwEngine.Integration.Execution.TaskRobustnessTest do
  @moduledoc """
  Task behaviour at its edges: the concurrency cap and internal child starts,
  User Task due dates, assignees and inbox event order, and Script / Business
  Rule Task results over the payload cap.
  """
  use BfwEngine.ExecutionCase, async: false

  alias BfwEngine.Execution
  alias BfwEngine.Test.EventCollector
  alias BfwEngine.Test.PayloadCapFixtures
  alias BfwEngine.Types.Event

  describe "E6: concurrency cap" do
    setup do
      previous_cap = Application.get_env(:core_execution, :max_concurrent_process_instances)

      on_exit(fn ->
        if previous_cap do
          Application.put_env(:core_execution, :max_concurrent_process_instances, previous_cap)
        else
          Application.delete_env(:core_execution, :max_concurrent_process_instances)
        end
      end)

      :ok
    end

    test "a Call Activity starts its child at the cap; a new public start is refused" do
      {201, _} = http_deploy("call_activity_resume_child.bpmn")
      {201, _} = http_deploy("call_activity_resume_parent.bpmn")

      Application.put_env(:core_execution, :max_concurrent_process_instances, Execution.count_active() + 1)

      {201, body} = http_start("CallActivityResumeParent")
      parent_process_instance_id = body["processInstanceId"]

      [child_process_instance_id] = await_child_process_instance_ids(parent_process_instance_id)
      child_user_task = poll_fni_state(child_process_instance_id, "user_task", "waiting")

      Application.put_env(:core_execution, :max_concurrent_process_instances, Execution.count_active())
      assert {503, %{"error" => "engine_at_capacity"}} = http_start("CallActivityResumeParent")

      {204, _} = http_finish_user_task(child_user_task.id, %{"result" => "done"})

      poll_pi_state(parent_process_instance_id, "finished")
      assert find_fni_by_flow_node_id(parent_process_instance_id, "CA_1").state == "finished"
    end
  end

  describe "E9 / E10: User Task due date and assignees" do
    test "a FEEL dueDate and the assignees are evaluated against the mapped input; a literal dueDate is kept" do
      process_instance_id =
        http_deploy_and_start("user_task_due_date_and_assignees.bpmn", "UserTaskDueDateAndAssignees", %{
          "payload" => %{"requester" => "alice", "deadline" => "2027-01-15T09:00:00Z"}
        })

      feel_task = poll_fni_state(process_instance_id, "user_task", "waiting")

      assert feel_task.flow_node_id == "UserTask_Feel"
      assert feel_task.type_properties["due_date"] == "2027-01-16T09:00:00Z"
      assert feel_task.type_properties["assignees"] == ["alice"]

      {204, _} = http_finish_user_task(feel_task.id)

      literal_task = poll_waiting_flow_node_instance(process_instance_id, "UserTask_Literal")
      assert literal_task.type_properties["due_date"] == "2026-12-31T23:59:59Z"
    end

    test "a dueDate that is neither an ISO 8601 date-time nor yields one fatals with a diagnostic" do
      process_instance_id =
        http_deploy_and_start("user_task_due_date_invalid.bpmn", "UserTaskDueDateInvalid")

      poll_pi_state(process_instance_id, "fatal")
      user_task = find_fni_by_flow_node_id(process_instance_id, "UserTask_BadDueDate")

      assert user_task.state == "fatal"
      assert user_task.error_info["error_code"] == "user_task_due_date_failed"
      assert user_task.error_info["message"] =~ "UserTask_BadDueDate"
      assert user_task.error_info["message"] =~ "bfw:dueDate"
    end
  end

  describe "E11: inbox event order" do
    test "UserTaskCreated is published after the task is waiting, so finishing on the event succeeds",
         %{collector: collector} do
      process_instance_id = http_deploy_and_start("user_task_simple.bpmn", "UserTaskSimple")
      user_task = poll_fni_state(process_instance_id, "user_task", "waiting")

      assert_created_after_waiting(collector, user_task.id)

      {204, _} = http_finish_user_task(user_task.id)
      poll_pi_state(process_instance_id, "finished")
    end

    test "a confirming Manual Task publishes UserTaskCreated after it is waiting", %{collector: collector} do
      process_instance_id = http_deploy_and_start("manual_task_confirm.bpmn", "ManualTaskConfirm")
      manual_task = poll_fni_state(process_instance_id, "manual_task", "waiting")

      assert_created_after_waiting(collector, manual_task.id)

      {204, _} = http_confirm_manual_task(manual_task.id)
      poll_pi_state(process_instance_id, "finished")
    end
  end

  describe "E13: Script and Business Rule Task result over the payload cap" do
    test "the oversized result fails each task through its error boundary instead of hanging" do
      process_instance_id =
        http_deploy_and_start("task_result_oversize_boundaries.bpmn", "TaskResultOversizeBoundaries", %{
          "context" => %{"text" => PayloadCapFixtures.mint_payload(40_000)["blob"]}
        })

      poll_pi_state(process_instance_id, "finished")

      assert inspect(find_fni_by_flow_node_id(process_instance_id, "BusinessRuleTask_Big").input_token) =~
               "payload_too_large"

      assert inspect(find_fni_by_flow_node_id(process_instance_id, "End_Caught").input_token) =~
               "payload_too_large"
    end
  end

  defp poll_waiting_flow_node_instance(process_instance_id, flow_node_id, attempts \\ 100) do
    case Enum.find(
           fetch_flow_node_instances(process_instance_id),
           &(&1.flow_node_id == flow_node_id and &1.state == "waiting")
         ) do
      nil when attempts > 0 ->
        Process.sleep(50)
        poll_waiting_flow_node_instance(process_instance_id, flow_node_id, attempts - 1)

      flow_node_instance ->
        flow_node_instance
    end
  end

  defp assert_created_after_waiting(collector, flow_node_instance_id) do
    events = await_user_task_created(collector, flow_node_instance_id)

    waiting_index =
      Enum.find_index(
        events,
        &match?(
          %Event.FlowNodeInstanceStateChanged{new_state: :waiting, flow_node_instance_id: ^flow_node_instance_id},
          &1
        )
      )

    created_index =
      Enum.find_index(events, &match?(%Event.UserTaskCreated{flow_node_instance_id: ^flow_node_instance_id}, &1))

    assert is_integer(waiting_index)
    assert is_integer(created_index)
    assert waiting_index < created_index
  end

  defp await_user_task_created(collector, flow_node_instance_id, attempts \\ 100) do
    events = EventCollector.get_events(collector)

    if Enum.any?(events, &match?(%Event.UserTaskCreated{flow_node_instance_id: ^flow_node_instance_id}, &1)) or
         attempts == 0 do
      events
    else
      Process.sleep(20)
      await_user_task_created(collector, flow_node_instance_id, attempts - 1)
    end
  end
end

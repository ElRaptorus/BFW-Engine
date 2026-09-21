defmodule BfwEngine.Integration.Execution.CompensationEventTest do
  @moduledoc """
  Umbrella-level integration tests for Compensation Events (COMP-1–COMP-10).

  Uses real BPMN XML fixtures deployed via the HTTP API. Verifies
  PI state, FNI states, compensation handler execution, LIFO ordering,
  activity-targeted compensation, and correct event/telemetry emission
  against a real database.

  Scenarios covered:
  - COMP-1: Basic broadcast compensation throw — single handler fires
  - COMP-2: Compensation End Event — PI reaches :compensated
  - COMP-3: LIFO ordering with two compensable tasks
  - COMP-4: Activity-specific compensation (activityRef)
  - COMP-5: Compensation throw with no registered targets — passthrough
  - COMP-6: Error in embedded subprocess + error boundary → compensation
  - COMP-7: Escalation in embedded subprocess + escalation boundary → compensation
  - COMP-8: ESP precedence — broadcast compensation fires ESP, skips boundary handlers
  - COMP-9: Targeted compensation skips ESP — boundary handler wins
  - COMP-10: Unfinished activity not compensated — only completed activities
  """
  use BfwEngine.ExecutionCase, async: false

  alias BfwEngine.Test.EventCollector
  alias BfwEngine.Types.Event

  # ---------------------------------------------------------------------------
  # COMP-1: Basic broadcast compensation throw
  # ---------------------------------------------------------------------------

  describe "COMP-1: basic broadcast compensation throw" do
    test "handler fires, PI finishes normally", %{collector: collector} do
      {201, _} = http_deploy("compensation_basic_throw.bpmn")

      {201, body} = http_start("CompensationBasicThrow")
      process_instance_id = body["processInstanceId"]

      wait_for_process_instance(process_instance_id, 10_000)

      assert_pi_state!(process_instance_id, "finished")

      flow_node_instances = fetch_flow_node_instances(process_instance_id)

      start_fni = Enum.find(flow_node_instances, &(&1.flow_node_id == "Start_1"))
      task_a_fni = Enum.find(flow_node_instances, &(&1.flow_node_id == "Task_A"))
      throw_fni = Enum.find(flow_node_instances, &(&1.flow_node_id == "Throw_Compensation"))
      handler_fni = Enum.find(flow_node_instances, &(&1.flow_node_id == "Task_CompHandler_A"))
      end_fni = Enum.find(flow_node_instances, &(&1.flow_node_id == "End_1"))

      assert start_fni != nil
      assert start_fni.state == "finished"

      assert task_a_fni != nil
      assert task_a_fni.state == "finished"

      assert throw_fni != nil
      assert throw_fni.state == "finished"

      assert handler_fni != nil,
             "Compensation handler FNI must be created and executed"
      assert handler_fni.state == "finished"

      assert end_fni != nil
      assert end_fni.state == "finished"

      events = EventCollector.get_events(collector)

      compensation_triggered =
        Enum.find(events, &(&1.__struct__ == Event.CompensationTriggered))

      assert compensation_triggered != nil,
             "CompensationTriggered event should have been emitted"
      assert compensation_triggered.throw_type == :throw

      activity_compensated =
        Enum.find(events, &(&1.__struct__ == Event.ActivityCompensated))

      assert activity_compensated != nil,
             "ActivityCompensated event should have been emitted"
    end
  end

  # ---------------------------------------------------------------------------
  # COMP-2: Compensation End Event — PI :compensated
  # ---------------------------------------------------------------------------

  describe "COMP-2: compensation end event" do
    test "handler fires, PI reaches :compensated terminal state", %{collector: collector} do
      {201, _} = http_deploy("compensation_basic_end.bpmn")

      {201, body} = http_start("CompensationBasicEnd")
      process_instance_id = body["processInstanceId"]

      wait_for_process_instance(process_instance_id, 10_000)

      assert_pi_state!(process_instance_id, "compensated")

      flow_node_instances = fetch_flow_node_instances(process_instance_id)

      task_a_fni = Enum.find(flow_node_instances, &(&1.flow_node_id == "Task_A"))
      end_compensate_fni = Enum.find(flow_node_instances, &(&1.flow_node_id == "End_Compensate"))
      handler_fni = Enum.find(flow_node_instances, &(&1.flow_node_id == "Task_CompHandler_A"))

      assert task_a_fni != nil
      assert task_a_fni.state == "finished"

      assert end_compensate_fni != nil

      assert handler_fni != nil,
             "Compensation handler FNI must have been created"
      assert handler_fni.state == "finished"

      events = EventCollector.get_events(collector)

      compensation_triggered =
        Enum.find(events, &(&1.__struct__ == Event.CompensationTriggered))

      assert compensation_triggered != nil
      assert compensation_triggered.throw_type == :end

      pi_state_events =
        Enum.filter(events, &(&1.__struct__ == Event.ProcessInstanceStateChanged))

      compensated_transition =
        Enum.find(pi_state_events, &(&1.new_state == :compensated))

      assert compensated_transition != nil,
             "PI must transition to :compensated state"
    end

    test "compensated PI is not retryable" do
      {201, _} = http_deploy("compensation_basic_end.bpmn")

      {201, body} = http_start("CompensationBasicEnd")
      process_instance_id = body["processInstanceId"]

      wait_for_process_instance(process_instance_id, 10_000)

      assert_pi_state!(process_instance_id, "compensated")

      {status, error_body} = http_retry_process_instance(process_instance_id)

      assert status == 422,
             "Retrying a compensated PI should return 422, got: #{status}"

      assert error_body["error"] == "process_instance_not_retriable",
             "Expected process_instance_not_retriable error, got: #{inspect(error_body)}"
    end
  end

  # ---------------------------------------------------------------------------
  # COMP-3: LIFO ordering with two compensable tasks
  # ---------------------------------------------------------------------------

  describe "COMP-3: LIFO ordering" do
    test "Task_B handler fires before Task_A handler", %{collector: collector} do
      {201, _} = http_deploy("compensation_lifo_two_tasks.bpmn")

      {201, body} = http_start("CompensationLifoTwoTasks")
      process_instance_id = body["processInstanceId"]

      wait_for_process_instance(process_instance_id, 10_000)

      assert_pi_state!(process_instance_id, "finished")

      flow_node_instances = fetch_flow_node_instances(process_instance_id)

      handler_a_fni = Enum.find(flow_node_instances, &(&1.flow_node_id == "Task_CompHandler_A"))
      handler_b_fni = Enum.find(flow_node_instances, &(&1.flow_node_id == "Task_CompHandler_B"))

      assert handler_a_fni != nil, "Handler A must have executed"
      assert handler_b_fni != nil, "Handler B must have executed"
      assert handler_a_fni.state == "finished"
      assert handler_b_fni.state == "finished"

      events = EventCollector.get_events(collector)

      activity_compensated_events =
        events
        |> Enum.filter(&(&1.__struct__ == Event.ActivityCompensated))
        |> Enum.sort_by(& &1.occurred_at)

      assert length(activity_compensated_events) == 2,
             "Expected 2 ActivityCompensated events, got #{length(activity_compensated_events)}"

      [first_compensated, second_compensated] = activity_compensated_events

      assert first_compensated.handler_activity_id == "Task_CompHandler_B",
             "LIFO: Task_B's handler (completed last) should fire first, " <>
               "got #{first_compensated.handler_activity_id}"

      assert second_compensated.handler_activity_id == "Task_CompHandler_A",
             "LIFO: Task_A's handler (completed first) should fire second, " <>
               "got #{second_compensated.handler_activity_id}"
    end
  end

  # ---------------------------------------------------------------------------
  # COMP-4: Activity-specific compensation (activityRef)
  # ---------------------------------------------------------------------------

  describe "COMP-4: targeted compensation via activityRef" do
    test "only Task_A handler fires, Task_B handler does not" do
      {201, _} = http_deploy("compensation_activity_ref.bpmn")

      {201, body} = http_start("CompensationActivityRef")
      process_instance_id = body["processInstanceId"]

      wait_for_process_instance(process_instance_id, 10_000)

      assert_pi_state!(process_instance_id, "finished")

      flow_node_instances = fetch_flow_node_instances(process_instance_id)

      handler_a_fni = Enum.find(flow_node_instances, &(&1.flow_node_id == "Task_CompHandler_A"))
      handler_b_fni = Enum.find(flow_node_instances, &(&1.flow_node_id == "Task_CompHandler_B"))

      assert handler_a_fni != nil, "Handler A must have executed (targeted)"
      assert handler_a_fni.state == "finished"

      assert handler_b_fni == nil,
             "Handler B must NOT have been created (activityRef targets only Task_A)"
    end
  end

  # ---------------------------------------------------------------------------
  # COMP-5: No registered compensation targets — passthrough
  # ---------------------------------------------------------------------------

  describe "COMP-5: compensation throw with no targets" do
    test "PI finishes normally, no handler FNIs created" do
      {201, _} = http_deploy("compensation_no_targets_throw.bpmn")

      {201, body} = http_start("CompensationNoTargetsThrow")
      process_instance_id = body["processInstanceId"]

      wait_for_process_instance(process_instance_id, 10_000)

      assert_pi_state!(process_instance_id, "finished")

      flow_node_instances = fetch_flow_node_instances(process_instance_id)

      compensation_handler_fnis =
        Enum.filter(flow_node_instances, fn fni ->
          String.contains?(fni.flow_node_id, "CompHandler")
        end)

      assert compensation_handler_fnis == [],
             "No compensation handler FNIs should exist when there are no targets"
    end
  end

  # ---------------------------------------------------------------------------
  # COMP-6: Error in embedded subprocess → error boundary → compensation
  # ---------------------------------------------------------------------------

  describe "COMP-6: error in subprocess then compensation" do
    test "error caught by boundary, compensation fires for parent-level task, PI finishes",
         %{collector: collector} do
      {201, _} = http_deploy("compensation_error_then_compensate.bpmn")

      {201, body} = http_start("CompensationErrorThenCompensate")
      process_instance_id = body["processInstanceId"]

      wait_for_process_instance(process_instance_id, 10_000)

      assert_pi_state!(process_instance_id, "finished")

      flow_node_instances = fetch_flow_node_instances(process_instance_id)

      task_a_fni = Enum.find(flow_node_instances, &(&1.flow_node_id == "Task_A"))
      subprocess_fni = Enum.find(flow_node_instances, &(&1.flow_node_id == "SubProcess_1"))
      error_boundary_fni = Enum.find(flow_node_instances, &(&1.flow_node_id == "BE_Error"))
      throw_fni = Enum.find(flow_node_instances, &(&1.flow_node_id == "Throw_Compensation"))
      handler_fni = Enum.find(flow_node_instances, &(&1.flow_node_id == "Task_CompHandler_A"))
      end_fni = Enum.find(flow_node_instances, &(&1.flow_node_id == "End_Compensated"))

      assert task_a_fni != nil
      assert task_a_fni.state == "finished"

      assert subprocess_fni != nil

      assert error_boundary_fni != nil
      assert error_boundary_fni.state == "finished"

      assert throw_fni != nil
      assert throw_fni.state == "finished"

      assert handler_fni != nil,
             "Compensation handler at parent level must have executed"
      assert handler_fni.state == "finished"

      assert end_fni != nil
      assert end_fni.state == "finished"

      events = EventCollector.get_events(collector)

      compensation_triggered =
        Enum.find(events, &(&1.__struct__ == Event.CompensationTriggered))

      assert compensation_triggered != nil,
             "CompensationTriggered event should have been emitted"

      activity_compensated =
        Enum.find(events, &(&1.__struct__ == Event.ActivityCompensated))

      assert activity_compensated != nil,
             "ActivityCompensated event should have been emitted for Task_A"
    end
  end

  # ---------------------------------------------------------------------------
  # COMP-7: Escalation in embedded subprocess → escalation boundary → compensation
  # ---------------------------------------------------------------------------

  describe "COMP-7: escalation in subprocess then compensation" do
    test "escalation caught by boundary, compensation fires for parent-level task, PI finishes",
         %{collector: collector} do
      {201, _} = http_deploy("compensation_escalation_then_compensate.bpmn")

      {201, body} = http_start("CompensationEscalationThenCompensate")
      process_instance_id = body["processInstanceId"]

      wait_for_process_instance(process_instance_id, 10_000)

      process_instance = fetch_process_instance!(process_instance_id)

      if process_instance.state != "finished" do
        fnis = fetch_flow_node_instances(process_instance_id)

        fni_dump =
          Enum.map(fnis, fn f ->
            err = if f.error_info, do: " err=#{inspect(f.error_info)}", else: ""
            "#{f.flow_node_id}(#{f.flow_node_type})=#{f.state}#{err}"
          end)
          |> Enum.join(", ")

        flunk(
          "PI state=#{process_instance.state}, error=#{inspect(process_instance.error_info)}, FNIs=[#{fni_dump}]"
        )
      end

      flow_node_instances = fetch_flow_node_instances(process_instance_id)

      task_a_fni = Enum.find(flow_node_instances, &(&1.flow_node_id == "Task_A"))
      subprocess_fni = Enum.find(flow_node_instances, &(&1.flow_node_id == "SubProcess_1"))
      escalation_boundary_fni = Enum.find(flow_node_instances, &(&1.flow_node_id == "BE_Escalation"))
      throw_fni = Enum.find(flow_node_instances, &(&1.flow_node_id == "Throw_Compensation"))
      handler_fni = Enum.find(flow_node_instances, &(&1.flow_node_id == "Task_CompHandler_A"))
      end_fni = Enum.find(flow_node_instances, &(&1.flow_node_id == "End_Compensated"))

      assert task_a_fni != nil
      assert task_a_fni.state == "finished"

      assert subprocess_fni != nil

      assert escalation_boundary_fni != nil
      assert escalation_boundary_fni.state == "finished"

      assert throw_fni != nil
      assert throw_fni.state == "finished"

      assert handler_fni != nil,
             "Compensation handler at parent level must have executed"
      assert handler_fni.state == "finished"

      assert end_fni != nil
      assert end_fni.state == "finished"

      events = EventCollector.get_events(collector)

      escalation_raised =
        Enum.find(events, &(&1.__struct__ == Event.EscalationRaised))

      assert escalation_raised != nil,
             "EscalationRaised event should have been emitted"

      compensation_triggered =
        Enum.find(events, &(&1.__struct__ == Event.CompensationTriggered))

      assert compensation_triggered != nil,
             "CompensationTriggered event should have been emitted"

      activity_compensated =
        Enum.find(events, &(&1.__struct__ == Event.ActivityCompensated))

      assert activity_compensated != nil,
             "ActivityCompensated event should have been emitted for Task_A"
    end
  end

  # ---------------------------------------------------------------------------
  # COMP-8: ESP precedence — broadcast compensation triggers ESP, not boundary
  # ---------------------------------------------------------------------------

  describe "COMP-8: ESP precedence over boundary handlers" do
    test "broadcast compensation fires ESP, boundary handler does NOT fire",
         %{collector: collector} do
      {201, _} = http_deploy("compensation_esp_precedence.bpmn")

      {201, body} = http_start("CompensationEspPrecedence")
      process_instance_id = body["processInstanceId"]

      wait_for_process_instance(process_instance_id, 10_000)

      assert_pi_state!(process_instance_id, "finished")

      flow_node_instances = fetch_flow_node_instances(process_instance_id)

      boundary_handler_fni =
        Enum.find(flow_node_instances, &(&1.flow_node_id == "Task_CompHandler_A"))

      esp_shell_fni =
        Enum.find(flow_node_instances, &(&1.flow_node_id == "ESP_Compensation"))

      assert boundary_handler_fni == nil,
             "Boundary compensation handler must NOT fire when a compensation ESP exists"

      assert esp_shell_fni != nil,
             "ESP_Compensation shell FNI must have been dispatched"
      assert esp_shell_fni.state == "finished"

      events = EventCollector.get_events(collector)

      esp_child_started =
        Enum.find(events, fn event ->
          event.__struct__ == Event.SubProcessChildStarted and
            event.is_event_subprocess == true
        end)

      assert esp_child_started != nil,
             "SubProcessChildStarted with is_event_subprocess=true must be emitted"

      compensation_triggered =
        Enum.find(events, &(&1.__struct__ == Event.CompensationTriggered))

      assert compensation_triggered != nil,
             "CompensationTriggered event should have been emitted"
    end
  end

  # ---------------------------------------------------------------------------
  # COMP-9: Targeted compensation skips ESP — boundary handler wins
  # ---------------------------------------------------------------------------

  describe "COMP-9: targeted compensation skips ESP" do
    test "activityRef targets boundary handler, ESP does NOT fire",
         %{collector: collector} do
      {201, _} = http_deploy("compensation_esp_targeted_skips_esp.bpmn")

      {201, body} = http_start("CompensationEspTargetedSkipsEsp")
      process_instance_id = body["processInstanceId"]

      wait_for_process_instance(process_instance_id, 10_000)

      assert_pi_state!(process_instance_id, "finished")

      flow_node_instances = fetch_flow_node_instances(process_instance_id)

      boundary_handler_fni =
        Enum.find(flow_node_instances, &(&1.flow_node_id == "Task_CompHandler_A"))

      esp_shell_fni =
        Enum.find(flow_node_instances, &(&1.flow_node_id == "ESP_Compensation"))

      assert boundary_handler_fni != nil,
             "Boundary compensation handler must fire for targeted compensation"
      assert boundary_handler_fni.state == "finished"

      assert esp_shell_fni == nil,
             "ESP_Compensation shell must NOT be dispatched for targeted compensation"

      events = EventCollector.get_events(collector)

      activity_compensated =
        Enum.find(events, &(&1.__struct__ == Event.ActivityCompensated))

      assert activity_compensated != nil,
             "ActivityCompensated event should have been emitted for targeted handler"

      esp_child_events =
        Enum.filter(events, fn event ->
          event.__struct__ == Event.SubProcessChildStarted and
            event.is_event_subprocess == true and
            event.subprocess_node_id == "ESP_Compensation"
        end)

      assert esp_child_events == [],
             "No ESP child should have been started for targeted compensation"
    end
  end

  # ---------------------------------------------------------------------------
  # COMP-10: Unfinished activity is NOT compensated
  # ---------------------------------------------------------------------------

  describe "COMP-10: unfinished activity not compensated" do
    test "compensation throw ignores waiting user task, handler does NOT fire",
         %{collector: collector} do
      {201, _} = http_deploy("compensation_unfinished_activity.bpmn")

      {201, body} = http_start("CompensationUnfinishedActivity")
      process_instance_id = body["processInstanceId"]

      {:ok, user_task_fni} =
        await_waiting_flow_node_instance(process_instance_id, "user_task")

      assert user_task_fni != nil, "UserTask_B must be in waiting state"

      Process.sleep(500)

      flow_node_instances = fetch_flow_node_instances(process_instance_id)

      throw_fni = Enum.find(flow_node_instances, &(&1.flow_node_id == "Throw_Compensation"))
      handler_b_fni = Enum.find(flow_node_instances, &(&1.flow_node_id == "Task_CompHandler_B"))

      assert throw_fni != nil
      assert throw_fni.state == "finished",
             "Compensation throw must finish (0 targets, passthrough)"

      assert handler_b_fni == nil,
             "Handler B must NOT fire — UserTask_B has not completed"

      events = EventCollector.get_events(collector)

      compensation_triggered =
        Enum.find(events, &(&1.__struct__ == Event.CompensationTriggered))

      assert compensation_triggered != nil
      assert compensation_triggered.target_count == 0,
             "Target count must be 0 — no completed compensable activities"

      {204, _} = http_finish_user_task(user_task_fni.id)

      wait_for_process_instance(process_instance_id, 10_000)

      assert_pi_state!(process_instance_id, "finished")

      final_fnis = fetch_flow_node_instances(process_instance_id)

      user_task_final = Enum.find(final_fnis, &(&1.flow_node_id == "UserTask_B"))
      assert user_task_final.state == "finished"

      handler_b_final = Enum.find(final_fnis, &(&1.flow_node_id == "Task_CompHandler_B"))
      assert handler_b_final == nil,
             "Handler B must still not exist — compensation already completed before UserTask_B finished"
    end
  end

end

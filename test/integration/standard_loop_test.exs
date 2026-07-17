defmodule EvilEngine.Integration.StandardLoopTest do
  @moduledoc """
  Umbrella-level integration tests for Standard Loop (while-do and do-while)
  execution via the lightweight iteration scope architecture.
  """
  use EvilEngine.ExecutionCase, async: false

  alias EvilEngine.Test.EventCollector
  alias EvilEngine.Types.Event

  @default_timeout 15_000

  # ===================================================================
  # Section 1: While-Do Loop
  # ===================================================================

  describe "Section 1 — while-do loop" do
    test "1.1 while-do script loop — condition checked before first iteration",
         %{collector: collector} do
      {201, _deploy_body} = http_deploy("loop_while_do_script.bpmn")

      {201, start_body} = http_start("loop-while-do-script")
      process_instance_id = start_body["processInstanceId"]

      wait_for_process_instance(process_instance_id, @default_timeout)

      assert_pi_state!(process_instance_id, "finished")
      assert_all_fnis_terminal!(process_instance_id)

      flow_node_instances = fetch_flow_node_instances(process_instance_id)

      iteration_fnis =
        Enum.filter(flow_node_instances, fn flow_node_instance ->
          flow_node_instance.flow_node_id == "Task_1" and
            flow_node_instance.multi_instance_id != nil
        end)

      assert length(iteration_fnis) == 3,
             "Expected 3 iteration FNIs (loop.completed < 3), got #{length(iteration_fnis)}"

      Enum.each(iteration_fnis, fn flow_node_instance ->
        assert flow_node_instance.state == "finished"
      end)

      events = EventCollector.get_events(collector)

      multi_instance_started_events =
        Enum.filter(events, &match?(%Event.MultiInstanceStarted{}, &1))

      assert length(multi_instance_started_events) >= 1

      started_event = List.first(multi_instance_started_events)
      assert started_event.loop_type == "standard_loop"
      assert started_event.total_iterations == nil
      assert started_event.flow_node_id == "Task_1"
    end

    test "1.2 zero iterations — testBefore=true, condition false from start",
         %{collector: collector} do
      {201, _deploy_body} = http_deploy("loop_zero_iterations.bpmn")

      {201, start_body} = http_start("loop-zero-iterations")
      process_instance_id = start_body["processInstanceId"]

      wait_for_process_instance(process_instance_id, @default_timeout)

      assert_pi_state!(process_instance_id, "finished")
      assert_all_fnis_terminal!(process_instance_id)

      flow_node_instances = fetch_flow_node_instances(process_instance_id)

      iteration_fnis =
        Enum.filter(flow_node_instances, fn flow_node_instance ->
          flow_node_instance.flow_node_id == "Task_1" and
            flow_node_instance.multi_instance_id != nil and
            flow_node_instance.iteration_index != nil
        end)

      assert iteration_fnis == [],
             "Expected zero iteration FNIs when condition is false from start, " <>
               "got #{length(iteration_fnis)}"

      events = EventCollector.get_events(collector)

      multi_instance_completed_events =
        Enum.filter(events, &match?(%Event.MultiInstanceCompleted{}, &1))

      completed_event =
        Enum.find(multi_instance_completed_events, fn event ->
          event.flow_node_id == "Task_1"
        end)

      if completed_event do
        assert completed_event.completed_iterations == 0
      end
    end
  end

  # ===================================================================
  # Section 2: Do-While Loop
  # ===================================================================

  describe "Section 2 — do-while loop" do
    test "2.1 do-while user task loop — at least one iteration runs" do
      {201, _deploy_body} = http_deploy("loop_do_while_user_task.bpmn")

      {201, start_body} = http_start("loop-do-while-user-task")
      process_instance_id = start_body["processInstanceId"]

      {:ok, first_user_task_fni} =
        await_waiting_flow_node_instance(process_instance_id, "user_task",
          timeout: @default_timeout
        )

      {204, _} = http_finish_user_task(first_user_task_fni.id, %{"confirmed" => true})

      {:ok, second_user_task_fni} =
        await_waiting_flow_node_instance(process_instance_id, "user_task",
          timeout: @default_timeout
        )

      assert second_user_task_fni.id != first_user_task_fni.id

      {204, _} = http_finish_user_task(second_user_task_fni.id, %{"confirmed" => true})

      wait_for_process_instance(process_instance_id, @default_timeout)

      assert_pi_state!(process_instance_id, "finished")
      assert_all_fnis_terminal!(process_instance_id)

      flow_node_instances = fetch_flow_node_instances(process_instance_id)

      iteration_fnis =
        Enum.filter(flow_node_instances, fn flow_node_instance ->
          flow_node_instance.flow_node_id == "Task_1" and
            flow_node_instance.multi_instance_id != nil
        end)

      assert length(iteration_fnis) == 2,
             "Expected 2 iteration FNIs (do-while with loop.completed < 2), " <>
               "got #{length(iteration_fnis)}"
    end
  end

  # ===================================================================
  # Section 3: Loop Controls
  # ===================================================================

  describe "Section 3 — loop controls" do
    test "3.1 loop maximum cap — stops at loopMaximum even when condition stays true",
         %{collector: collector} do
      {201, _deploy_body} = http_deploy("loop_with_maximum.bpmn")

      {201, start_body} = http_start("loop-with-maximum")
      process_instance_id = start_body["processInstanceId"]

      wait_for_process_instance(process_instance_id, @default_timeout)

      assert_pi_state!(process_instance_id, "finished")
      assert_all_fnis_terminal!(process_instance_id)

      flow_node_instances = fetch_flow_node_instances(process_instance_id)

      iteration_fnis =
        Enum.filter(flow_node_instances, fn flow_node_instance ->
          flow_node_instance.flow_node_id == "Task_1" and
            flow_node_instance.multi_instance_id != nil
        end)

      assert length(iteration_fnis) == 5,
             "Expected exactly 5 iterations (loopMaximum=5 with condition=true), " <>
               "got #{length(iteration_fnis)}"

      events = EventCollector.get_events(collector)

      multi_instance_completed_events =
        Enum.filter(events, fn event ->
          match?(%Event.MultiInstanceCompleted{}, event) and event.flow_node_id == "Task_1"
        end)

      assert length(multi_instance_completed_events) >= 1

      completed_event = List.first(multi_instance_completed_events)
      assert completed_event.completed_iterations == 5
      assert completed_event.early_break == true
    end

    test "3.2 loop interval delay — iterations spaced by PT1S" do
      {201, _deploy_body} = http_deploy("loop_with_interval.bpmn")

      {201, start_body} = http_start("loop-with-interval")
      process_instance_id = start_body["processInstanceId"]

      started_at = System.monotonic_time(:millisecond)

      wait_for_process_instance(process_instance_id, 30_000)

      elapsed_milliseconds = System.monotonic_time(:millisecond) - started_at

      assert_pi_state!(process_instance_id, "finished")
      assert_all_fnis_terminal!(process_instance_id)

      flow_node_instances = fetch_flow_node_instances(process_instance_id)

      iteration_fnis =
        Enum.filter(flow_node_instances, fn flow_node_instance ->
          flow_node_instance.flow_node_id == "Task_1" and
            flow_node_instance.multi_instance_id != nil
        end)

      assert length(iteration_fnis) == 3,
             "Expected 3 iterations with interval, got #{length(iteration_fnis)}"

      assert elapsed_milliseconds >= 2_000,
             "Expected at least 2s elapsed (3 iterations with PT1S interval between them), " <>
               "got #{elapsed_milliseconds}ms"
    end
  end

  # ===================================================================
  # Section 4: MI Events for Standard Loop
  # ===================================================================

  describe "Section 4 — MI events for standard loop" do
    test "4.1 standard loop emits MultiInstanceStarted with loopType standard_loop",
         %{collector: collector} do
      {201, _deploy_body} = http_deploy("loop_while_do_script.bpmn")

      {201, start_body} = http_start("loop-while-do-script")
      process_instance_id = start_body["processInstanceId"]

      wait_for_process_instance(process_instance_id, @default_timeout)

      assert_pi_state!(process_instance_id, "finished")

      events = EventCollector.get_events(collector)

      multi_instance_started_events =
        Enum.filter(events, fn event ->
          match?(%Event.MultiInstanceStarted{}, event) and
            event.process_instance_id == process_instance_id
        end)

      assert length(multi_instance_started_events) == 1,
             "Expected exactly 1 MultiInstanceStarted event, " <>
               "got #{length(multi_instance_started_events)}"

      started_event = List.first(multi_instance_started_events)
      assert started_event.loop_type == "standard_loop"
      assert started_event.total_iterations == nil
      assert started_event.flow_node_id == "Task_1"
      assert started_event.process_instance_id == process_instance_id

      multi_instance_completed_events =
        Enum.filter(events, fn event ->
          match?(%Event.MultiInstanceCompleted{}, event) and
            event.process_instance_id == process_instance_id
        end)

      assert length(multi_instance_completed_events) == 1,
             "Expected exactly 1 MultiInstanceCompleted event, " <>
               "got #{length(multi_instance_completed_events)}"

      completed_event = List.first(multi_instance_completed_events)
      assert completed_event.loop_type == "standard_loop"
      assert completed_event.completed_iterations == 3
      assert completed_event.early_break == false
      assert completed_event.flow_node_id == "Task_1"
    end

    test "4.2 loopMaximum triggers early_break in MultiInstanceCompleted",
         %{collector: collector} do
      {201, _deploy_body} = http_deploy("loop_with_maximum.bpmn")

      {201, start_body} = http_start("loop-with-maximum")
      process_instance_id = start_body["processInstanceId"]

      wait_for_process_instance(process_instance_id, @default_timeout)

      assert_pi_state!(process_instance_id, "finished")

      events = EventCollector.get_events(collector)

      multi_instance_completed_events =
        Enum.filter(events, fn event ->
          match?(%Event.MultiInstanceCompleted{}, event) and
            event.process_instance_id == process_instance_id
        end)

      assert length(multi_instance_completed_events) == 1

      completed_event = List.first(multi_instance_completed_events)
      assert completed_event.loop_type == "standard_loop"
      assert completed_event.completed_iterations == 5
      assert completed_event.early_break == true
    end
  end
end

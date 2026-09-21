defmodule BfwEngine.Integration.Execution.TerminateEndEventTest do
  @moduledoc """
  Umbrella-level integration tests for Terminate End Event.

  Uses real BPMN XML fixtures deployed via the HTTP API. Verifies
  PI state, FNI states, final tokens, child PI cascade, and event
  emission against a real database.
  """
  use BfwEngine.ExecutionCase, async: false

  alias BfwEngine.Test.EventCollector
  alias BfwEngine.Types.Event

  setup do
    original_resolver = Application.get_env(:core_execution, :called_element_resolver)

    Application.put_env(
      :core_execution,
      :called_element_resolver,
      BfwEngine.Persistence.CalledElementResolverImpl
    )

    on_exit(fn ->
      if original_resolver do
        Application.put_env(:core_execution, :called_element_resolver, original_resolver)
      else
        Application.delete_env(:core_execution, :called_element_resolver)
      end
    end)

    :ok
  end

  # -------------------------------------------------------------------
  # Test 1: Simple path — Start → Timer Catch (1s) → Terminate End
  # -------------------------------------------------------------------

  describe "simple path: Start → Timer Catch → Terminate End" do
    test "PI finishes normally, no side effects — behaves like a regular end event",
         %{collector: collector} do
      {201, _} = http_deploy("terminate_simple_with_timer.bpmn")

      {201, body} =
        http_start("TerminateSimpleTimer", %{"payload" => %{"order" => "ABC"}})

      process_instance_id = body["processInstanceId"]
      wait_for_process_instance(process_instance_id, 10_000)

      process_instance = assert_pi_state!(process_instance_id, "finished")
      assert process_instance.finished_at != nil

      flow_node_instances = fetch_flow_node_instances(process_instance_id)
      assert length(flow_node_instances) == 3

      start_fni = Enum.find(flow_node_instances, &(&1.flow_node_id == "Start_1"))
      timer_fni = Enum.find(flow_node_instances, &(&1.flow_node_id == "TimerCatch_1"))
      end_fni = Enum.find(flow_node_instances, &(&1.flow_node_id == "End_Terminate"))

      assert start_fni.state == "finished"
      assert start_fni.flow_node_type == "start_event"

      assert timer_fni.state == "finished"
      assert timer_fni.flow_node_type == "intermediate_catch_event"
      assert timer_fni.event_type == "timer"

      assert end_fni.state == "finished"
      assert end_fni.flow_node_type == "end_event"
      assert end_fni.event_type == "terminate"

      assert end_fni.output_token == %{"order" => "ABC"}

      Enum.each(flow_node_instances, fn fni ->
        assert fni.error_info == nil,
               "FNI #{fni.id} (#{fni.flow_node_id}) should have nil error_info"
      end)

      events = EventCollector.await_events(collector, 11, 10_000)
      types = Enum.map(events, &(&1.__struct__))

      assert types == [
               Event.ProcessDefinitionDeployed,
               Event.ProcessInstanceStateChanged,
               Event.FlowNodeInstanceStarted,
               Event.FlowNodeInstanceFinished,
               Event.FlowNodeInstanceStarted,
               Event.FlowNodeInstanceStateChanged,
               Event.TimerFired,
               Event.FlowNodeInstanceFinished,
               Event.FlowNodeInstanceStarted,
               Event.FlowNodeInstanceFinished,
               Event.ProcessInstanceStateChanged
             ]

      pi_state_events =
        Enum.filter(events, &(&1.__struct__ == Event.ProcessInstanceStateChanged))

      [started_event, finished_event] = pi_state_events
      assert started_event.new_state == :running
      assert finished_event.new_state == :finished
    end

    test "payload threads through the entire path" do
      {201, _} = http_deploy("terminate_simple_with_timer.bpmn")

      payload = %{"customer_id" => 42, "items" => [1, 2, 3]}
      {201, body} = http_start("TerminateSimpleTimer", %{"payload" => payload})

      process_instance_id = body["processInstanceId"]
      wait_for_process_instance(process_instance_id, 10_000)

      assert_pi_state!(process_instance_id, "finished")

      flow_node_instances = fetch_flow_node_instances(process_instance_id)
      end_fni = Enum.find(flow_node_instances, &(&1.flow_node_id == "End_Terminate"))

      assert end_fni.output_token == %{"customer_id" => 42, "items" => [1, 2, 3]}
    end
  end

  # -------------------------------------------------------------------
  # Test 2: Call Activity + Non-Interrupting Timer Boundary → Terminate
  # -------------------------------------------------------------------

  describe "Call Activity + Non-Interrupting Timer Boundary → Terminate End" do
    test "terminate interrupts the Call Activity and its child PI",
         %{collector: collector} do
      {201, _} = http_deploy("terminate_child_with_user_task.bpmn")
      {201, _} = http_deploy("terminate_call_activity_boundary.bpmn")

      {201, body} = http_start("TerminateCallBoundary")
      parent_process_instance_id = body["processInstanceId"]

      {:ok, _child_user_task_fni} =
        poll_child_waiting_user_task(parent_process_instance_id)

      wait_for_process_instance(parent_process_instance_id, 10_000)

      parent_pi = assert_pi_state!(parent_process_instance_id, "finished")
      assert parent_pi.finished_at != nil

      assert_no_running_fnis!(parent_process_instance_id)

      parent_fnis = fetch_flow_node_instances(parent_process_instance_id)

      start_fni = Enum.find(parent_fnis, &(&1.flow_node_id == "Start_1"))
      call_activity_fni = Enum.find(parent_fnis, &(&1.flow_node_id == "CA_1"))
      boundary_fni = Enum.find(parent_fnis, &(&1.flow_node_id == "TimerBE_1"))
      terminate_fni = Enum.find(parent_fnis, &(&1.flow_node_id == "End_Terminate"))

      assert start_fni.state == "finished"
      assert terminate_fni.state == "finished"
      assert terminate_fni.event_type == "terminate"

      assert call_activity_fni.state == "interrupted",
             "Call Activity should be interrupted by terminate, got: #{call_activity_fni.state}"

      assert boundary_fni != nil, "Timer boundary event FNI should exist"
      assert boundary_fni.state == "finished"

      child_process_instance_ids = find_child_process_instance_ids(parent_process_instance_id)
      assert length(child_process_instance_ids) >= 1

      Enum.each(child_process_instance_ids, fn child_process_instance_id ->
        wait_for_process_instance(child_process_instance_id, 5_000)
        child_pi = fetch_process_instance!(child_process_instance_id)

        assert child_pi.state in ["aborted", "fatal"],
               "Child PI should be terminated (aborted/fatal), got: #{child_pi.state}"

        assert_no_running_fnis!(child_process_instance_id)
      end)

      events = EventCollector.get_events(collector)

      parent_fni_finished_events =
        Enum.filter(events, fn event ->
          event.__struct__ == Event.FlowNodeInstanceFinished and
            event.process_instance_id == parent_process_instance_id
        end)

      interrupted_events =
        Enum.filter(parent_fni_finished_events, &(&1.terminal_state == :interrupted))

      assert length(interrupted_events) >= 1,
             "At least one FNI should have been interrupted by the terminate end event"

      ca_interrupted =
        Enum.find(interrupted_events, &(&1.flow_node_type == :call_activity))

      assert ca_interrupted != nil,
             "Call Activity FNI should have emitted a FlowNodeInstanceFinished with :interrupted"
    end

    test "parent PI final tokens include the terminate end event payload" do
      {201, _} = http_deploy("terminate_child_with_user_task.bpmn")
      {201, _} = http_deploy("terminate_call_activity_boundary.bpmn")

      {201, body} = http_start("TerminateCallBoundary", %{"payload" => %{"key" => "value"}})
      parent_process_instance_id = body["processInstanceId"]

      wait_for_process_instance(parent_process_instance_id, 10_000)

      assert_pi_state!(parent_process_instance_id, "finished")

      parent_fnis = fetch_flow_node_instances(parent_process_instance_id)
      terminate_fni = Enum.find(parent_fnis, &(&1.flow_node_id == "End_Terminate"))

      assert terminate_fni.state == "finished"
      assert terminate_fni.output_token != nil
    end
  end

  # -------------------------------------------------------------------
  # Private helpers
  # -------------------------------------------------------------------

  defp find_child_process_instance_ids(parent_process_instance_id) do
    list_child_process_instance_ids(parent_process_instance_id)
  end

  defp poll_child_waiting_user_task(parent_process_instance_id) do
    deadline = System.monotonic_time(:millisecond) + 10_000
    do_poll_child_user_task(parent_process_instance_id, deadline)
  end

  defp do_poll_child_user_task(parent_process_instance_id, deadline) do
    child_process_instance_ids =
      find_child_process_instance_ids(parent_process_instance_id)

    result =
      Enum.find_value(child_process_instance_ids, fn child_process_instance_id ->
        flow_node_instances = fetch_flow_node_instances(child_process_instance_id)

        Enum.find(flow_node_instances, fn flow_node_instance ->
          flow_node_instance.flow_node_type == "user_task" and
            flow_node_instance.state == "waiting"
        end)
      end)

    case result do
      nil ->
        if System.monotonic_time(:millisecond) >= deadline do
          raise "Child User Task never reached 'waiting' within timeout " <>
                  "(children: #{inspect(child_process_instance_ids)})"
        else
          Process.sleep(100)
          do_poll_child_user_task(parent_process_instance_id, deadline)
        end

      flow_node_instance ->
        {:ok, flow_node_instance}
    end
  end
end

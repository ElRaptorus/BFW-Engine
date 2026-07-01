defmodule EvilEngine.Integration.Execution.ErrorEndEventTest do
  @moduledoc """
  Umbrella-level integration tests for Error End Event (EE-1 through EE-6).

  Uses real BPMN XML fixtures deployed via the HTTP API. Verifies
  PI state, FNI states (including the new :error terminal state),
  error propagation through Call Activities, boundary catch semantics,
  and event emission against a real database.
  """
  use EvilEngine.ExecutionCase, async: false

  alias EvilEngine.Test.EventCollector
  alias EvilEngine.Types.Event

  setup do
    original_resolver = Application.get_env(:core_execution, :called_element_resolver)

    Application.put_env(
      :core_execution,
      :called_element_resolver,
      EvilEngine.Persistence.CalledElementResolverImpl
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
  # Test 1: Error End Event in standalone process (EE-4, EE-6)
  # -------------------------------------------------------------------

  describe "standalone process with Error End Event" do
    test "PI reaches :error state, Error End Event FNI is in :error state",
         %{collector: collector} do
      {201, _} = http_deploy("error_end_event_standalone.bpmn")

      {201, body} =
        http_start("ErrorEndStandalone", %{"payload" => %{"data" => "test"}})

      process_instance_id = body["processInstanceId"]
      wait_for_process_instance(process_instance_id, 10_000)

      process_instance = assert_pi_state!(process_instance_id, "error")
      assert process_instance.finished_at != nil

      flow_node_instances = fetch_flow_node_instances(process_instance_id)
      assert length(flow_node_instances) == 2

      start_fni = Enum.find(flow_node_instances, &(&1.flow_node_id == "Start_1"))
      error_end_fni = Enum.find(flow_node_instances, &(&1.flow_node_id == "End_Error"))

      assert start_fni.state == "finished"
      assert error_end_fni.state == "error"
      assert error_end_fni.flow_node_type == "end_event"
      assert error_end_fni.event_type == "error"
      assert error_end_fni.output_token == %{"data" => "test"}

      type_props = error_end_fni.type_properties
      assert type_props["end_event_id"] == "End_Error"
      assert type_props["end_event_name"] == "Error Out"
      assert type_props["error_code"] == "STANDALONE_ERROR"
      assert type_props["error_message"] == "Process encountered an error condition"

      events = EventCollector.await_events(collector, 6, 10_000)

      pi_state_events =
        Enum.filter(events, &(&1.__struct__ == Event.ProcessInstanceStateChanged))

      assert length(pi_state_events) == 2
      [started_event, error_event] = pi_state_events
      assert started_event.new_state == :running
      assert error_event.new_state == :error

      fni_finished_events =
        Enum.filter(events, &(&1.__struct__ == Event.FlowNodeInstanceFinished))

      error_end_finished =
        Enum.find(fni_finished_events, &(&1.flow_node_id == "End_Error"))

      assert error_end_finished != nil
      assert error_end_finished.terminal_state == :error
      assert error_end_finished.event_type == "error"
    end

    test "payload threads through to the Error End Event output" do
      {201, _} = http_deploy("error_end_event_standalone.bpmn")

      payload = %{"order_id" => "ORD-42", "items" => [1, 2, 3]}
      {201, body} = http_start("ErrorEndStandalone", %{"payload" => payload})

      process_instance_id = body["processInstanceId"]
      wait_for_process_instance(process_instance_id, 10_000)

      assert_pi_state!(process_instance_id, "error")

      flow_node_instances = fetch_flow_node_instances(process_instance_id)
      error_end_fni = Enum.find(flow_node_instances, &(&1.flow_node_id == "End_Error"))

      assert error_end_fni.output_token == %{"order_id" => "ORD-42", "items" => [1, 2, 3]}
    end
  end

  # -------------------------------------------------------------------
  # Test 2: Error End Event + Call Activity + Boundary Catch (EE-1 to EE-6)
  # -------------------------------------------------------------------

  describe "Call Activity with Error End Event child + boundary catch" do
    test "parent PI finishes via boundary path, child PI state is :error",
         %{collector: collector} do
      {201, _} = http_deploy("error_end_event_child.bpmn")
      {201, _} = http_deploy("error_end_event_ca_boundary.bpmn")

      {201, body} = http_start("ErrorEndCABoundary")
      parent_process_instance_id = body["processInstanceId"]

      wait_for_process_instance(parent_process_instance_id, 10_000)

      parent_pi = assert_pi_state!(parent_process_instance_id, "finished")
      assert parent_pi.finished_at != nil

      parent_fnis = fetch_flow_node_instances(parent_process_instance_id)

      start_fni = Enum.find(parent_fnis, &(&1.flow_node_id == "Start_1"))
      ca_fni = Enum.find(parent_fnis, &(&1.flow_node_id == "CA_1"))
      end_caught_fni = Enum.find(parent_fnis, &(&1.flow_node_id == "End_Caught"))

      assert start_fni.state == "finished"
      assert ca_fni != nil
      assert ca_fni.state == "interrupted",
             "Call Activity should be interrupted by boundary catch, got: #{ca_fni.state}"
      assert end_caught_fni != nil, "End_Caught FNI should exist — boundary path was taken"
      assert end_caught_fni.state == "finished"

      end_normal_fni = Enum.find(parent_fnis, &(&1.flow_node_id == "End_Normal"))
      assert end_normal_fni == nil, "End_Normal should NOT be reached — boundary path was taken"

      child_process_instance_ids = find_child_process_instance_ids(parent_process_instance_id)
      assert length(child_process_instance_ids) >= 1

      Enum.each(child_process_instance_ids, fn child_process_instance_id ->
        child_pi = fetch_process_instance!(child_process_instance_id)
        assert child_pi.state == "error",
               "Child PI should be in error state, got: #{child_pi.state}"

        child_fnis = fetch_flow_node_instances(child_process_instance_id)
        error_end_fni = Enum.find(child_fnis, &(&1.flow_node_id == "End_Error"))
        assert error_end_fni != nil
        assert error_end_fni.state == "error"
      end)

      events = EventCollector.get_events(collector)

      child_pi_error =
        Enum.find(events, fn event ->
          event.__struct__ == Event.ProcessInstanceStateChanged and
            event.process_instance_id != parent_process_instance_id and
            event.new_state == :error
        end)

      assert child_pi_error != nil, "Child PI should have emitted :error state change"
    end
  end

  # -------------------------------------------------------------------
  # Test 3: Catch-all boundary (no error_code filter)
  # -------------------------------------------------------------------

  describe "Call Activity with catch-all Error Boundary" do
    test "catch-all boundary catches untyped Error End Event" do
      {201, _} = http_deploy("error_end_event_child_catchall.bpmn")
      {201, _} = http_deploy("error_end_event_ca_catchall.bpmn")

      {201, body} = http_start("ErrorEndCACatchall")
      parent_process_instance_id = body["processInstanceId"]

      wait_for_process_instance(parent_process_instance_id, 10_000)

      parent_pi = assert_pi_state!(parent_process_instance_id, "finished")
      assert parent_pi.finished_at != nil

      parent_fnis = fetch_flow_node_instances(parent_process_instance_id)

      end_caught_fni = Enum.find(parent_fnis, &(&1.flow_node_id == "End_Caught"))
      assert end_caught_fni != nil, "Catch-all boundary should catch any error"
      assert end_caught_fni.state == "finished"

      end_normal_fni = Enum.find(parent_fnis, &(&1.flow_node_id == "End_Normal"))
      assert end_normal_fni == nil, "Normal path should NOT be taken"
    end
  end

  # -------------------------------------------------------------------
  # Test 4: No matching boundary — parent PI goes to error state
  # BPMN errors propagate as errors (not fatals) through the PI chain.
  # -------------------------------------------------------------------

  describe "Call Activity with Error End Event child + no boundary" do
    test "parent PI goes to error state when child throws uncaught BPMN error" do
      {201, _} = http_deploy("error_end_event_child.bpmn")
      {201, _} = http_deploy("error_end_event_ca_no_boundary.bpmn")

      {201, body} = http_start("ErrorEndCANoBoundary")
      parent_process_instance_id = body["processInstanceId"]

      {:ok, _} =
        await_process_instance_state(parent_process_instance_id, "error", timeout: 10_000)

      parent_pi = fetch_process_instance!(parent_process_instance_id)

      assert parent_pi.state == "error",
             "Parent PI should be in error state when child BPMN error is uncaught, got: #{parent_pi.state}"

      child_process_instance_ids = find_child_process_instance_ids(parent_process_instance_id)
      assert length(child_process_instance_ids) >= 1

      Enum.each(child_process_instance_ids, fn child_process_instance_id ->
        child_pi = fetch_process_instance!(child_process_instance_id)

        assert child_pi.state == "error",
               "Child PI should be in error state, got: #{child_pi.state}"
      end)
    end
  end

  # -------------------------------------------------------------------
  # Test 5: Error ref resolution
  # -------------------------------------------------------------------

  describe "Error End Event with errorRef to global <bpmn:error>" do
    test "error_code is resolved from global ErrorDefinition" do
      {201, _} = http_deploy("error_end_event_error_ref_child.bpmn")

      {201, body} = http_start("ErrorRefChild")
      process_instance_id = body["processInstanceId"]

      wait_for_process_instance(process_instance_id, 10_000)

      assert_pi_state!(process_instance_id, "error")

      flow_node_instances = fetch_flow_node_instances(process_instance_id)
      error_end_fni = Enum.find(flow_node_instances, &(&1.flow_node_id == "End_Error"))

      assert error_end_fni.state == "error"

      type_props = error_end_fni.type_properties
      assert type_props["error_code"] == "PAYMENT_FAILED",
             "error_code should be resolved from global <bpmn:error>, got: #{inspect(type_props["error_code"])}"
    end
  end

  # -------------------------------------------------------------------
  # Test 6: Concurrent branches — Error End Event interrupts siblings
  # -------------------------------------------------------------------

  describe "concurrent branches: User Task + Non-Interrupting Timer → Error End Event" do
    test "Error End Event interrupts waiting User Task, PI reaches :error",
         %{collector: collector} do
      {201, _} = http_deploy("error_end_event_concurrent.bpmn")

      {201, body} = http_start("ErrorEndConcurrent")
      process_instance_id = body["processInstanceId"]

      wait_for_process_instance(process_instance_id, 10_000)

      process_instance = assert_pi_state!(process_instance_id, "error")
      assert process_instance.finished_at != nil

      flow_node_instances = fetch_flow_node_instances(process_instance_id)

      start_fni = Enum.find(flow_node_instances, &(&1.flow_node_id == "Start_1"))
      user_task_fni = Enum.find(flow_node_instances, &(&1.flow_node_id == "UserTask_1"))
      timer_be_fni = Enum.find(flow_node_instances, &(&1.flow_node_id == "TimerBE_1"))
      error_end_fni = Enum.find(flow_node_instances, &(&1.flow_node_id == "End_Error"))

      assert start_fni.state == "finished"

      assert error_end_fni != nil
      assert error_end_fni.state == "error",
             "Error End Event FNI should be in :error state, got: #{error_end_fni.state}"

      assert user_task_fni.state == "error",
             "Waiting User Task should be in :error state (cascade from Error End Event), got: #{user_task_fni.state}"

      assert timer_be_fni != nil
      assert timer_be_fni.state == "finished"

      events = EventCollector.get_events(collector)

      fni_finished_events =
        Enum.filter(events, fn event ->
          event.__struct__ == Event.FlowNodeInstanceFinished and
            event.process_instance_id == process_instance_id
        end)

      error_end_finished =
        Enum.find(fni_finished_events, &(&1.flow_node_id == "End_Error"))

      assert error_end_finished != nil
      assert error_end_finished.terminal_state == :error

      error_cascade_events =
        Enum.filter(fni_finished_events, &(&1.terminal_state == :error))

      user_task_error =
        Enum.find(error_cascade_events, &(&1.flow_node_type == :user_task))

      assert user_task_error != nil,
             "User Task FNI should have emitted FlowNodeInstanceFinished with :error (cascade from Error End Event)"
    end
  end

  # -------------------------------------------------------------------
  # Private helpers
  # -------------------------------------------------------------------

  defp find_child_process_instance_ids(parent_process_instance_id) do
    require Ash.Query

    EvilEngine.Persistence.Resources.ProcessInstance
    |> Ash.Query.filter(parent_process_instance_id == ^parent_process_instance_id)
    |> Ash.read!(domain: EvilEngine.Persistence.Api, authorize?: false)
    |> Enum.map(& &1.id)
  end
end

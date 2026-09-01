defmodule EvilEngine.Integration.EmbeddedSubprocessTest do
  @moduledoc """
  Umbrella-level integration tests for embedded `<bpmn:subProcess>` execution.

  Exercises the full HTTP deploy → start → interact → assert lifecycle against
  real PostgreSQL persistence, covering happy paths, error boundaries, terminate
  scoping, abort cascade, resume, and data object isolation.
  """
  use EvilEngine.ExecutionCase, async: false

  alias EvilEngine.Test.EventCollector
  alias EvilEngine.Types.Event

  @default_timeout 15_000

  # ===================================================================
  # Section 1: Happy Paths
  # ===================================================================

  describe "Section 1 — happy paths" do
    test "1.1 basic subprocess execution — deploy + start → finished", %{collector: collector} do
      {201, _} = http_deploy("embedded_subprocess_happy_path.bpmn")

      {201, body} = http_start("EmbeddedSubprocessHappyPath")
      parent_process_instance_id = body["processInstanceId"]

      wait_for_process_instance(parent_process_instance_id, @default_timeout)

      assert_pi_state!(parent_process_instance_id, "finished")
      assert_flow_node_instance_count!(parent_process_instance_id, 3)
      assert_all_fnis_terminal!(parent_process_instance_id)

      [child_process_instance_id] =
        find_child_process_instance_ids(parent_process_instance_id)

      assert_pi_state!(child_process_instance_id, "finished")
      assert_flow_node_instance_count!(child_process_instance_id, 3)
      assert_all_fnis_terminal!(child_process_instance_id)

      events = EventCollector.get_events(collector)

      subprocess_child_started =
        Enum.find(events, &match?(%Event.SubProcessChildStarted{}, &1))

      assert subprocess_child_started != nil
      assert subprocess_child_started.parent_process_instance_id == parent_process_instance_id
      assert subprocess_child_started.child_process_instance_id == child_process_instance_id
      assert subprocess_child_started.subprocess_node_id == "SubProcess_1"
    end

    test "1.2 user task inside subprocess — interactive completion" do
      {201, _} = http_deploy("embedded_subprocess_user_task.bpmn")

      {201, body} = http_start("EmbeddedSubprocessUserTask")
      parent_process_instance_id = body["processInstanceId"]

      child_process_instance_id = await_child_process_instance(parent_process_instance_id)

      {:ok, user_task_fni} =
        await_waiting_flow_node_instance(child_process_instance_id, "user_task",
          timeout: @default_timeout
        )

      {204, _} = http_finish_user_task(user_task_fni.id, %{"approved" => true})

      wait_for_process_instance(child_process_instance_id, @default_timeout)
      wait_for_process_instance(parent_process_instance_id, @default_timeout)

      assert_pi_state!(parent_process_instance_id, "finished")
      assert_pi_state!(child_process_instance_id, "finished")
    end

    test "1.3 input/output mappings transform payload" do
      {201, _} = http_deploy("embedded_subprocess_input_output_mappings.bpmn")

      {201, body} =
        http_start("EmbeddedSubprocessInputOutputMappings", %{
          "payload" => %{"order_id" => "ORD-123"}
        })

      parent_process_instance_id = body["processInstanceId"]

      wait_for_process_instance(parent_process_instance_id, @default_timeout)

      assert_pi_state!(parent_process_instance_id, "finished")

      subprocess_fni = find_fni_by_flow_node_id(parent_process_instance_id, "SubProcess_1")
      assert subprocess_fni != nil
      assert subprocess_fni.state == "finished"
      assert subprocess_fni.output_token["mapped_result"] == "ORD-123"
    end

    test "1.4 nested subprocess — two levels execute correctly" do
      {201, _} = http_deploy("embedded_subprocess_nested.bpmn")

      {201, body} = http_start("EmbeddedSubprocessNested")
      parent_process_instance_id = body["processInstanceId"]

      wait_for_process_instance(parent_process_instance_id, @default_timeout)

      assert_pi_state!(parent_process_instance_id, "finished")

      [outer_child_process_instance_id] =
        find_child_process_instance_ids(parent_process_instance_id)

      assert_pi_state!(outer_child_process_instance_id, "finished")

      [grandchild_process_instance_id] =
        find_child_process_instance_ids(outer_child_process_instance_id)

      assert_pi_state!(grandchild_process_instance_id, "finished")
    end
  end

  # ===================================================================
  # Section 2: Error Paths
  # ===================================================================

  describe "Section 2 — error paths" do
    test "2.1 error boundary on subprocess shell catches inner error" do
      {201, _} = http_deploy("embedded_subprocess_error_boundary.bpmn")

      {201, body} = http_start("EmbeddedSubprocessErrorBoundary")
      parent_process_instance_id = body["processInstanceId"]

      wait_for_process_instance(parent_process_instance_id, @default_timeout)

      assert_pi_state!(parent_process_instance_id, "finished")

      [child_process_instance_id] =
        find_child_process_instance_ids(parent_process_instance_id)

      assert_pi_state!(child_process_instance_id, "error")

      end_error_fni = find_fni_by_flow_node_id(parent_process_instance_id, "End_Error")
      assert end_error_fni != nil
      assert end_error_fni.state == "finished"

      end_ok_fni = find_fni_by_flow_node_id(parent_process_instance_id, "End_OK")
      assert end_ok_fni == nil or end_ok_fni.state != "finished"
    end

    test "2.2 WIP diagram — invalid subprocess never reached" do
      {201, _} = http_deploy("embedded_subprocess_wip_never_reached.bpmn")

      {201, body} = http_start("EmbeddedSubprocessWipNeverReached", %{"payload" => %{}})
      parent_process_instance_id = body["processInstanceId"]

      wait_for_process_instance(parent_process_instance_id, @default_timeout)

      assert_pi_state!(parent_process_instance_id, "finished")
      assert find_child_process_instance_ids(parent_process_instance_id) == []

      end_ok_fni = find_fni_by_flow_node_id(parent_process_instance_id, "End_OK")
      assert end_ok_fni != nil
      assert end_ok_fni.state == "finished"
    end
  end

  # ===================================================================
  # Section 3: Terminate End Event Scoping
  # ===================================================================

  describe "Section 3 — terminate end event scoping" do
    test "3.1 terminate inside subprocess only kills child scope" do
      {201, _} = http_deploy("embedded_subprocess_terminate_scoped.bpmn")

      {201, body} = http_start("EmbeddedSubprocessTerminateScoped")
      parent_process_instance_id = body["processInstanceId"]

      wait_for_process_instance(parent_process_instance_id, @default_timeout)

      assert_pi_state!(parent_process_instance_id, "finished")

      [child_process_instance_id] =
        find_child_process_instance_ids(parent_process_instance_id)

      assert_pi_state!(child_process_instance_id, "finished")
      assert_all_fnis_terminal!(child_process_instance_id)
    end

    test "3.2 terminate with parallel branches — scoped kill" do
      {201, _} = http_deploy("embedded_subprocess_terminate_with_parallel.bpmn")

      {201, body} = http_start("EmbeddedSubprocessTerminateParallel")
      parent_process_instance_id = body["processInstanceId"]

      child_process_instance_id = await_child_process_instance(parent_process_instance_id)

      {:ok, _} =
        await_process_instance_state(child_process_instance_id, "finished",
          timeout: @default_timeout
        )

      {:ok, _} =
        await_process_instance_state(parent_process_instance_id, "finished",
          timeout: @default_timeout
        )

      assert_all_fnis_terminal!(child_process_instance_id)
    end
  end

  # ===================================================================
  # Section 4: Cascade and Abort
  # ===================================================================

  describe "Section 4 — cascade and abort" do
    test "4.1 parent abort cascades to running subprocess child" do
      {201, _} = http_deploy("embedded_subprocess_abort_cascade.bpmn")

      {201, body} = http_start("EmbeddedSubprocessAbortCascade")
      parent_process_instance_id = body["processInstanceId"]

      child_process_instance_id = await_child_process_instance(parent_process_instance_id)

      {:ok, _user_task_fni} =
        await_waiting_flow_node_instance(child_process_instance_id, "user_task",
          timeout: @default_timeout
        )

      abort_claims = %{"abort_process_instance" => "all"}

      {204, _} =
        http_abort_process_instance(parent_process_instance_id, "test_abort", abort_claims)

      {:ok, _} =
        await_process_instance_state(parent_process_instance_id, "aborted",
          timeout: @default_timeout
        )

      {:ok, _} =
        await_process_instance_state(child_process_instance_id, "aborted",
          timeout: @default_timeout
        )

      assert_no_running_fnis!(parent_process_instance_id)
      assert_no_running_fnis!(child_process_instance_id)
    end
  end

  # ===================================================================
  # Section 5: Resume (Persistence Round-Trip)
  # ===================================================================

  describe "Section 5 — resume (persistence round-trip)" do
    test "5.1 complete user task in subprocess child after it has been persisted" do
      {201, _} = http_deploy("embedded_subprocess_resume.bpmn")

      {201, body} = http_start("EmbeddedSubprocessResume")
      parent_process_instance_id = body["processInstanceId"]

      child_process_instance_id = await_child_process_instance(parent_process_instance_id)

      {:ok, user_task_fni} =
        await_waiting_flow_node_instance(child_process_instance_id, "user_task",
          timeout: @default_timeout
        )

      assert_pi_state!(parent_process_instance_id, "running")
      assert_pi_state!(child_process_instance_id, "running")
      assert user_task_fni.state == "waiting"

      {204, _} = http_finish_user_task(user_task_fni.id, %{"approved" => true})

      wait_for_process_instance(child_process_instance_id, @default_timeout)
      wait_for_process_instance(parent_process_instance_id, @default_timeout)

      assert_pi_state!(parent_process_instance_id, "finished")
      assert_pi_state!(child_process_instance_id, "finished")
      assert_all_fnis_terminal!(parent_process_instance_id)
      assert_all_fnis_terminal!(child_process_instance_id)
    end
  end

  # ===================================================================
  # Section 6: Data Objects
  # ===================================================================

  describe "Section 6 — data objects" do
    test "6.1 inner data objects are scoped to subprocess", %{collector: collector} do
      {201, _} = http_deploy("embedded_subprocess_data_objects.bpmn")

      {201, body} =
        http_start("EmbeddedSubprocessDataObjects", %{"payload" => %{"value" => 10}})

      parent_process_instance_id = body["processInstanceId"]

      wait_for_process_instance(parent_process_instance_id, @default_timeout)

      assert_pi_state!(parent_process_instance_id, "finished")

      [child_process_instance_id] =
        find_child_process_instance_ids(parent_process_instance_id)

      assert_pi_state!(child_process_instance_id, "finished")

      inner_data_object = fetch_data_object(child_process_instance_id, "DO_Inner")
      assert inner_data_object != nil
      assert inner_data_object.value["inner_value"] == 11

      parent_inner_data_object = fetch_data_object(parent_process_instance_id, "DO_Inner")
      assert parent_inner_data_object == nil

      events = EventCollector.get_events(collector)

      data_object_written_events =
        Enum.filter(events, &match?(%Event.DataObjectWritten{}, &1))

      child_write_events =
        Enum.filter(data_object_written_events, fn event ->
          event.process_instance_id == child_process_instance_id and
            event.data_object_id == "DO_Inner"
        end)

      assert length(child_write_events) == 1

      parent_write_events =
        Enum.filter(data_object_written_events, fn event ->
          event.process_instance_id == parent_process_instance_id and
            event.data_object_id == "DO_Inner"
        end)

      assert parent_write_events == []
    end
  end

  # ===================================================================
  # Section 7: Deep Nesting and Mixed Hierarchies
  # ===================================================================

  describe "Section 7 — deep nesting and mixed hierarchies" do
    test "7.1 three-level nested subprocess — 4 PIs all finish" do
      {201, _} = http_deploy("embedded_subprocess_3level_nested.bpmn")

      {201, body} = http_start("EmbeddedSubprocess3LevelNested")
      parent_process_instance_id = body["processInstanceId"]

      wait_for_process_instance(parent_process_instance_id, @default_timeout)

      assert_pi_state!(parent_process_instance_id, "finished")

      [level1_id] = await_child_process_instance_ids(parent_process_instance_id)
      assert_pi_state!(level1_id, "finished")

      [level2_id] = await_child_process_instance_ids(level1_id)
      assert_pi_state!(level2_id, "finished")

      [level3_id] = await_child_process_instance_ids(level2_id)
      assert_pi_state!(level3_id, "finished")
    end

    test "7.2 call activity inside embedded subprocess" do
      {201, _} = http_deploy("simple_callable_process.bpmn")
      {201, _} = http_deploy("embedded_subprocess_with_call_activity.bpmn")

      {201, body} = http_start("EmbeddedSubprocessWithCallActivity")
      parent_process_instance_id = body["processInstanceId"]

      wait_for_process_instance(parent_process_instance_id, @default_timeout)

      assert_pi_state!(parent_process_instance_id, "finished")

      [subprocess_child_id] = await_child_process_instance_ids(parent_process_instance_id)
      assert_pi_state!(subprocess_child_id, "finished")

      [ca_child_id] = await_child_process_instance_ids(subprocess_child_id)
      assert_pi_state!(ca_child_id, "finished")
    end
  end

  # ===================================================================
  # Section 8: Unhandled Error Propagation (All Fatal)
  # ===================================================================

  describe "Section 8 — unhandled error propagation" do
    test "8.1 unhandled fatal in subprocess — both parent and child go fatal" do
      {201, _} = http_deploy("embedded_subprocess_unhandled_error_both_fatal.bpmn")

      {201, body} = http_start("EmbeddedSubprocessUnhandledError")
      parent_process_instance_id = body["processInstanceId"]

      {:ok, _} =
        await_process_instance_state(parent_process_instance_id, "fatal",
          timeout: @default_timeout
        )

      [child_process_instance_id] =
        find_child_process_instance_ids(parent_process_instance_id)

      assert_pi_state!(child_process_instance_id, "fatal")
    end

    test "8.2 fatal with error boundary on subprocess — parent finishes via boundary path" do
      {201, _} = http_deploy("embedded_subprocess_fatal_with_boundary.bpmn")

      {201, body} = http_start("EmbeddedSubprocessFatalWithBoundary")
      parent_process_instance_id = body["processInstanceId"]

      wait_for_process_instance(parent_process_instance_id, @default_timeout)

      assert_pi_state!(parent_process_instance_id, "finished")

      [child_process_instance_id] =
        find_child_process_instance_ids(parent_process_instance_id)

      assert_pi_state!(child_process_instance_id, "fatal")

      end_error_fni = find_fni_by_flow_node_id(parent_process_instance_id, "End_Error")
      assert end_error_fni != nil
      assert end_error_fni.state == "finished"
    end
  end

  # ===================================================================
  # Section 9: Timer Boundary Event on Embedded Subprocess
  # ===================================================================

  describe "Section 9 — timer boundary event" do
    test "9.1 interrupting timer fires after 2s — subprocess interrupted, parent continues" do
      {201, _} = http_deploy("embedded_subprocess_timer_boundary.bpmn")

      {201, body} = http_start("EmbeddedSubprocessTimerBoundary")
      parent_process_instance_id = body["processInstanceId"]

      wait_for_process_instance(parent_process_instance_id, @default_timeout)

      assert_pi_state!(parent_process_instance_id, "finished")

      [child_process_instance_id] =
        find_child_process_instance_ids(parent_process_instance_id)

      child_pi = fetch_process_instance!(child_process_instance_id)
      assert child_pi.state in ["aborted", "fatal"]

      end_timeout_fni = find_fni_by_flow_node_id(parent_process_instance_id, "End_Timeout")
      assert end_timeout_fni != nil
      assert end_timeout_fni.state == "finished"
    end
  end

  # ===================================================================
  # Section 10: Nested Fatal Error Chains
  # ===================================================================

  describe "Section 10 — nested fatal error chains" do
    test "10.1 two nested subprocesses — bottom fatal, all three PIs go fatal" do
      {201, _} = http_deploy("embedded_subprocess_2nested_bottom_fatal.bpmn")

      {201, body} = http_start("EmbeddedSubprocess2NestedBottomFatal")
      parent_process_instance_id = body["processInstanceId"]

      {:ok, _} =
        await_process_instance_state(parent_process_instance_id, "fatal",
          timeout: @default_timeout
        )

      [outer_child_id] = await_child_process_instance_ids(parent_process_instance_id)
      assert_pi_state!(outer_child_id, "fatal")

      [inner_child_id] = await_child_process_instance_ids(outer_child_id)
      assert_pi_state!(inner_child_id, "fatal")
    end

    test "10.2 embedded subprocess with call activity — CA child fatal, all go fatal" do
      {201, _} = http_deploy("call_activity_failing_child.bpmn")
      {201, _} = http_deploy("embedded_subprocess_ca_child_fatal.bpmn")

      {201, body} = http_start("EmbeddedSubprocessCAChildFatal")
      parent_process_instance_id = body["processInstanceId"]

      {:ok, _} =
        await_process_instance_state(parent_process_instance_id, "fatal",
          timeout: @default_timeout
        )

      [subprocess_child_id] = await_child_process_instance_ids(parent_process_instance_id)
      assert_pi_state!(subprocess_child_id, "fatal")

      [ca_child_id] = await_child_process_instance_ids(subprocess_child_id)
      assert_pi_state!(ca_child_id, "fatal")
    end

    test "10.3 two nested — bottom fatal + root boundary catches" do
      {201, _} = http_deploy("embedded_subprocess_2nested_bottom_fatal_root_boundary.bpmn")

      {201, body} = http_start("EmbeddedSubprocess2NestedFatalRootBoundary")
      parent_process_instance_id = body["processInstanceId"]

      wait_for_process_instance(parent_process_instance_id, @default_timeout)

      assert_pi_state!(parent_process_instance_id, "finished")

      [outer_child_id] = await_child_process_instance_ids(parent_process_instance_id)
      assert_pi_state!(outer_child_id, "fatal")

      [inner_child_id] = await_child_process_instance_ids(outer_child_id)
      assert_pi_state!(inner_child_id, "fatal")

      end_error_fni = find_fni_by_flow_node_id(parent_process_instance_id, "End_Error")
      assert end_error_fni != nil
      assert end_error_fni.state == "finished"
    end

    test "10.4 embedded subprocess + CA child fatal + root boundary catches" do
      {201, _} = http_deploy("call_activity_failing_child.bpmn")
      {201, _} = http_deploy("embedded_subprocess_ca_fatal_root_boundary.bpmn")

      {201, body} = http_start("EmbeddedSubprocessCAFatalRootBoundary")
      parent_process_instance_id = body["processInstanceId"]

      wait_for_process_instance(parent_process_instance_id, @default_timeout)

      assert_pi_state!(parent_process_instance_id, "finished")

      [subprocess_child_id] = await_child_process_instance_ids(parent_process_instance_id)
      assert_pi_state!(subprocess_child_id, "fatal")

      [ca_child_id] = await_child_process_instance_ids(subprocess_child_id)
      assert_pi_state!(ca_child_id, "fatal")

      end_error_fni = find_fni_by_flow_node_id(parent_process_instance_id, "End_Error")
      assert end_error_fni != nil
      assert end_error_fni.state == "finished"
    end
  end

  # ===================================================================
  # Section 11: Nested BPMN Error End Event Chains
  # ===================================================================

  describe "Section 11 — nested BPMN error end event chains" do
    test "11.1 two nested — bottom Error End + root boundary catches, both SPs 'error'" do
      {201, _} = http_deploy("embedded_subprocess_2nested_bottom_error_end_root_boundary.bpmn")

      {201, body} = http_start("EmbeddedSubprocess2NestedErrorEndRootBoundary")
      parent_process_instance_id = body["processInstanceId"]

      wait_for_process_instance(parent_process_instance_id, @default_timeout)

      assert_pi_state!(parent_process_instance_id, "finished")

      [outer_child_id] = await_child_process_instance_ids(parent_process_instance_id)
      assert_pi_state!(outer_child_id, "error")

      [inner_child_id] = await_child_process_instance_ids(outer_child_id)
      assert_pi_state!(inner_child_id, "error")

      end_error_fni = find_fni_by_flow_node_id(parent_process_instance_id, "End_Error")
      assert end_error_fni != nil
      assert end_error_fni.state == "finished"
    end

    test "11.2 embedded SP + CA child Error End + root boundary catches" do
      {201, _} = http_deploy("error_end_simple_child.bpmn")
      {201, _} = http_deploy("embedded_subprocess_ca_error_end_root_boundary.bpmn")

      {201, body} = http_start("EmbeddedSubprocessCAErrorEndRootBoundary")
      parent_process_instance_id = body["processInstanceId"]

      wait_for_process_instance(parent_process_instance_id, @default_timeout)

      assert_pi_state!(parent_process_instance_id, "finished")

      [subprocess_child_id] = await_child_process_instance_ids(parent_process_instance_id)
      assert_pi_state!(subprocess_child_id, "error")

      [ca_child_id] = await_child_process_instance_ids(subprocess_child_id)
      assert_pi_state!(ca_child_id, "error")

      end_error_fni = find_fni_by_flow_node_id(parent_process_instance_id, "End_Error")
      assert end_error_fni != nil
      assert end_error_fni.state == "finished"
    end

    test "11.3 two nested — bottom Error End, no boundary, all three PIs go 'error'" do
      {201, _} = http_deploy("embedded_subprocess_2nested_bottom_error_end_no_boundary.bpmn")

      {201, body} = http_start("EmbeddedSubprocess2NestedErrorEndNoBoundary")
      parent_process_instance_id = body["processInstanceId"]

      {:ok, _} =
        await_process_instance_state(parent_process_instance_id, "error",
          timeout: @default_timeout
        )

      [outer_child_id] = await_child_process_instance_ids(parent_process_instance_id)
      assert_pi_state!(outer_child_id, "error")

      [inner_child_id] = await_child_process_instance_ids(outer_child_id)
      assert_pi_state!(inner_child_id, "error")
    end
  end

  # ===================================================================
  # Section 12: WebSocket Event Fan-Out Verification
  # ===================================================================

  describe "Section 12 — WS event fan-out via root_process_instance_id" do
    test "12.1 embedded subprocess child events carry root PI's ID for fan-out",
         %{collector: collector} do
      {201, _} = http_deploy("embedded_subprocess_happy_path.bpmn")

      {201, body} = http_start("EmbeddedSubprocessHappyPath")
      parent_process_instance_id = body["processInstanceId"]

      wait_for_process_instance(parent_process_instance_id, @default_timeout)

      events = EventCollector.get_events(collector)

      child_fni_events =
        events
        |> Enum.filter(fn event ->
          match?(%Event.FlowNodeInstanceStarted{}, event) or
            match?(%Event.FlowNodeInstanceFinished{}, event)
        end)
        |> Enum.filter(fn event ->
          event.process_instance_id != parent_process_instance_id
        end)

      assert length(child_fni_events) > 0,
             "Expected child FNI events from subprocess child PI"

      Enum.each(child_fni_events, fn event ->
        assert event.root_process_instance_id == parent_process_instance_id,
               "Child FNI event should have root_process_instance_id == parent PI, " <>
                 "got: #{inspect(event.root_process_instance_id)}"
      end)
    end

    test "12.2 call activity grandchild events inherit the root PI id (SP-13 fan-out)",
         %{collector: collector} do
      {201, _} = http_deploy("simple_callable_process.bpmn")
      {201, _} = http_deploy("embedded_subprocess_with_call_activity.bpmn")

      {201, body} = http_start("EmbeddedSubprocessWithCallActivity")
      parent_process_instance_id = body["processInstanceId"]

      wait_for_process_instance(parent_process_instance_id, @default_timeout)

      [subprocess_child_id] = await_child_process_instance_ids(parent_process_instance_id)
      [ca_child_id] = await_child_process_instance_ids(subprocess_child_id)

      events = EventCollector.get_events(collector)

      ca_child_fni_events =
        events
        |> Enum.filter(fn event ->
          match?(%Event.FlowNodeInstanceStarted{}, event) or
            match?(%Event.FlowNodeInstanceFinished{}, event)
        end)
        |> Enum.filter(&(&1.process_instance_id == ca_child_id))

      assert length(ca_child_fni_events) > 0

      Enum.each(ca_child_fni_events, fn event ->
        assert event.root_process_instance_id == parent_process_instance_id,
               "CA grandchild FNI events inherit the root PI id (SP-13), " <>
                 "got: #{inspect(event.root_process_instance_id)}, expected: #{parent_process_instance_id}"
      end)

      subprocess_child_fni_events =
        events
        |> Enum.filter(fn event ->
          match?(%Event.FlowNodeInstanceStarted{}, event) or
            match?(%Event.FlowNodeInstanceFinished{}, event)
        end)
        |> Enum.filter(&(&1.process_instance_id == subprocess_child_id))

      Enum.each(subprocess_child_fni_events, fn event ->
        assert event.root_process_instance_id == parent_process_instance_id,
               "Subprocess child events should have root_process_instance_id == root PI " <>
                 "(embedded subprocess preserves fan-out)"
      end)
    end
  end

  # -------------------------------------------------------------------
  # Private helpers
  # -------------------------------------------------------------------

  defp find_child_process_instance_ids(parent_process_instance_id) do
    list_child_process_instance_ids(parent_process_instance_id)
  end

  defp await_child_process_instance(parent_process_instance_id, timeout \\ @default_timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_child(parent_process_instance_id, deadline)
  end

  defp do_await_child(parent_process_instance_id, deadline) do
    case find_child_process_instance_ids(parent_process_instance_id) do
      [child_process_instance_id | _] ->
        child_process_instance_id

      [] ->
        if System.monotonic_time(:millisecond) >= deadline do
          raise "No child PI found for parent #{parent_process_instance_id} within timeout"
        else
          Process.sleep(50)
          do_await_child(parent_process_instance_id, deadline)
        end
    end
  end
end

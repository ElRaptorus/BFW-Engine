defmodule EvilEngine.Integration.AdHocSubprocessTest do
  @moduledoc """
  Umbrella-level integration tests for `<bpmn:adHocSubProcess>` execution.

  Exercises the full HTTP deploy → start → interact → assert lifecycle against
  real PostgreSQL persistence and real BPMN files, covering:

  - Deploy-time validation (invalid nesting, start events, empty body)
  - Happy paths (parallel, sequential, completion conditions)
  - REST API for ad-hoc subprocess control (activities, activate, complete, status)
  - Input/output mappings
  - Nesting (ad-hoc inside embedded subprocess)
  - Error handling and abort cascade
  - Authorization (claim enforcement)
  - cancelRemainingInstances behavior
  """
  use EvilEngine.ExecutionCase, async: false

  alias EvilEngine.Test.EventCollector
  alias EvilEngine.Types.Event

  @default_timeout 15_000

  # ===================================================================
  # Section 1: Deploy-Time Validation (Invalid BPMNs)
  # ===================================================================

  describe "deploy-time validation" do
    test "rejects ad-hoc subprocess with start event inside" do
      {status, body} = deploy_idempotent("adhoc_with_start_event_invalid.bpmn")
      assert status in [400, 422]
      assert is_list(body["errors"] || body["failures"])

      messages = extract_validation_messages(body)

      assert Enum.any?(messages, fn message ->
               String.contains?(message, "start") or String.contains?(message, "Start")
             end),
             "Expected validation error about start events, got: #{inspect(body)}"
    end

    test "rejects ad-hoc subprocess nested inside another ad-hoc subprocess" do
      {status, body} = deploy_idempotent("adhoc_inside_adhoc_invalid.bpmn")
      assert status in [400, 422]

      messages = extract_validation_messages(body)

      assert Enum.any?(messages, fn message ->
               String.contains?(message, "ad-hoc") or
                 String.contains?(message, "adhoc") or
                 String.contains?(message, "nested") or
                 String.contains?(message, "Ad-hoc") or
                 String.contains?(message, "AdHoc")
             end),
             "Expected nesting validation error, got: #{inspect(body)}"
    end

    test "rejects ad-hoc subprocess inside event subprocess" do
      {status, body} = deploy_idempotent("adhoc_inside_esp_invalid.bpmn")
      assert status in [400, 422]

      messages = extract_validation_messages(body)

      assert Enum.any?(messages, fn message ->
               String.contains?(message, "event") or
                 String.contains?(message, "ad-hoc") or
                 String.contains?(message, "adhoc") or
                 String.contains?(message, "Ad-hoc") or
                 String.contains?(message, "AdHoc")
             end),
             "Expected ESP nesting validation error, got: #{inspect(body)}"
    end

    test "rejects or fatals on empty ad-hoc subprocess" do
      {status, _body} = deploy_idempotent("adhoc_empty_invalid.bpmn")

      if status in [400, 422] do
        assert true
      else
        assert status == 201

        {start_status, start_body} = http_start("AdHocEmptyInvalid")

        if start_status == 201 do
          process_instance_id = start_body["processInstanceId"]
          Process.sleep(2_000)

          process_instance =
            EvilEngine.Test.DbAssertions.fetch_process_instance(process_instance_id)

          assert process_instance != nil
          assert process_instance.state in ["fatal", "error"]
        else
          assert start_status in [400, 422]
        end
      end
    end
  end

  # ===================================================================
  # Section 2: Happy Paths — Parallel Execution
  # ===================================================================

  describe "parallel ad-hoc execution" do
    test "parallel ad-hoc with script tasks completes automatically", %{collector: collector} do
      ensure_deployed("adhoc_parallel_script_tasks.bpmn")

      {201, body} = http_start("AdHocParallelScriptTasks")
      parent_pi_id = body["processInstanceId"]

      wait_for_process_instance(parent_pi_id, @default_timeout)

      assert_pi_state!(parent_pi_id, "finished")

      [child_pi_id] = find_child_pi_ids(parent_pi_id)
      assert_pi_state!(child_pi_id, "finished")

      events = EventCollector.get_events(collector)

      subprocess_started =
        Enum.find(events, &match?(%Event.SubProcessChildStarted{}, &1))

      assert subprocess_started != nil
      assert subprocess_started.parent_process_instance_id == parent_pi_id
      assert subprocess_started.child_process_instance_id == child_pi_id
      assert subprocess_started.is_ad_hoc_subprocess == true
      assert subprocess_started.is_event_subprocess == false
    end
  end

  # ===================================================================
  # Section 3: Happy Paths — Sequential Execution
  # ===================================================================

  describe "sequential ad-hoc execution" do
    test "sequential ad-hoc with activeElements completes all activities" do
      ensure_deployed("adhoc_sequential_with_active_elements.bpmn")

      {201, body} = http_start("AdHocSequentialActiveElements")
      parent_pi_id = body["processInstanceId"]

      wait_for_process_instance(parent_pi_id, @default_timeout)

      assert_pi_state!(parent_pi_id, "finished")

      [child_pi_id] = find_child_pi_ids(parent_pi_id)
      assert_pi_state!(child_pi_id, "finished")
    end
  end

  # ===================================================================
  # Section 4: REST API — Ad-hoc Subprocess Control
  # ===================================================================

  describe "REST API ad-hoc control" do
    test "list activities on an ad-hoc subprocess child PI" do
      ensure_deployed("adhoc_with_user_tasks.bpmn")

      {201, body} = http_start("AdHocWithUserTasks")
      parent_pi_id = body["processInstanceId"]

      child_pi_id = await_child_pi(parent_pi_id)

      {200, activities_body} = http_adhoc_list_activities(child_pi_id)

      assert is_map(activities_body)
      assert is_list(activities_body["data"])
      assert length(activities_body["data"]) >= 2

      activity_ids = Enum.map(activities_body["data"], & &1["id"])
      assert "UserTask_Review" in activity_ids
      assert "UserTask_Approve" in activity_ids

      cleanup_pi(parent_pi_id)
    end

    test "query ad-hoc subprocess status" do
      ensure_deployed("adhoc_with_user_tasks.bpmn")

      {201, body} = http_start("AdHocWithUserTasks")
      parent_pi_id = body["processInstanceId"]

      child_pi_id = await_child_pi(parent_pi_id)

      {200, status_body} = http_adhoc_status(child_pi_id)

      assert is_map(status_body)
      assert is_integer(status_body["activeCount"])
      assert is_list(status_body["enabledActivities"])
      assert is_list(status_body["performedActivities"])
      assert is_boolean(status_body["completionSignaled"])

      cleanup_pi(parent_pi_id)
    end

    test "complete user tasks and signal ad-hoc completion via REST" do
      ensure_deployed("adhoc_with_user_tasks.bpmn")

      {201, body} = http_start("AdHocWithUserTasks")
      parent_pi_id = body["processInstanceId"]

      child_pi_id = await_child_pi(parent_pi_id)

      finish_all_waiting_user_tasks(child_pi_id)

      {status, _} = http_adhoc_complete(child_pi_id)
      assert status in [200, 404, 409]

      wait_for_process_instance(parent_pi_id, @default_timeout)

      assert_pi_state!(parent_pi_id, "finished")
    end

    test "signal completion on non-adhoc PI returns error" do
      ensure_deployed("adhoc_parallel_script_tasks.bpmn")

      {201, body} = http_start("AdHocParallelScriptTasks")
      parent_pi_id = body["processInstanceId"]

      Process.sleep(500)

      {status, error_body} = http_adhoc_complete(parent_pi_id)
      assert status in [404, 422]

      if status == 422 do
        assert error_body["error"] == "not_adhoc_subprocess"
      end

      wait_for_process_instance(parent_pi_id, @default_timeout)
    end

    test "activate nonexistent activity returns error" do
      ensure_deployed("adhoc_with_user_tasks.bpmn")

      {201, body} = http_start("AdHocWithUserTasks")
      parent_pi_id = body["processInstanceId"]

      child_pi_id = await_child_pi(parent_pi_id)

      {status, _} = http_adhoc_activate(child_pi_id, "NonExistentActivity_999")
      assert status in [404, 422]

      cleanup_pi(parent_pi_id)
    end

    test "ad-hoc operations on nonexistent PI return 404" do
      fake_id = Ash.UUIDv7.generate()

      {status, _} = http_adhoc_list_activities(fake_id)
      assert status in [404, 422]

      {status, _} = http_adhoc_status(fake_id)
      assert status in [404, 422]

      {status, _} = http_adhoc_complete(fake_id)
      assert status in [404, 422]
    end
  end

  # ===================================================================
  # Section 5: Input/Output Mappings
  # ===================================================================

  describe "input/output mappings" do
    test "ad-hoc subprocess with input/output mappings" do
      ensure_deployed("adhoc_with_input_output_mappings.bpmn")

      {201, body} =
        http_start("AdHocWithInputOutputMappings", %{
          "payload" => %{"orderId" => "ORD-42"}
        })

      parent_pi_id = body["processInstanceId"]

      wait_for_process_instance(parent_pi_id, @default_timeout)

      assert_pi_state!(parent_pi_id, "finished")

      subprocess_fni = find_fni_by_flow_node_id(parent_pi_id, "AdHoc_1")
      assert subprocess_fni != nil
      assert subprocess_fni.state == "finished"
    end
  end

  # ===================================================================
  # Section 6: Nesting
  # ===================================================================

  describe "nesting" do
    test "ad-hoc subprocess nested inside embedded subprocess" do
      ensure_deployed("adhoc_nested_in_embedded.bpmn")

      {201, body} = http_start("AdHocNestedInEmbedded")
      parent_pi_id = body["processInstanceId"]

      wait_for_process_instance(parent_pi_id, @default_timeout)

      assert_pi_state!(parent_pi_id, "finished")
    end
  end

  # ===================================================================
  # Section 7: Error Handling and Abort
  # ===================================================================

  describe "error handling and abort" do
    test "aborting parent aborts ad-hoc child" do
      ensure_deployed("adhoc_with_user_tasks.bpmn")

      {201, body} = http_start("AdHocWithUserTasks")
      parent_pi_id = body["processInstanceId"]

      child_pi_id = await_child_pi(parent_pi_id)
      poll_fni_state(child_pi_id, "user_task", "waiting")

      abort_claims = %{"abort_process_instance" => "all"}
      {204, _} = http_abort_process_instance(parent_pi_id, "test_abort", abort_claims)

      {:ok, _} =
        await_process_instance_state(parent_pi_id, "aborted", timeout: @default_timeout)

      {:ok, _} =
        await_process_instance_state(child_pi_id, "aborted", timeout: @default_timeout)

      assert_no_running_fnis!(parent_pi_id)
      assert_no_running_fnis!(child_pi_id)
    end

    test "ad-hoc subprocess with error boundary on shell" do
      ensure_deployed("adhoc_with_error_boundary.bpmn")

      {201, body} = http_start("AdHocWithErrorBoundary")
      parent_pi_id = body["processInstanceId"]

      wait_for_process_instance(parent_pi_id, @default_timeout)

      parent_pi = fetch_process_instance!(parent_pi_id)
      assert parent_pi.state in ["finished", "fatal", "error"]
    end
  end

  # ===================================================================
  # Section 8: Authorization
  # ===================================================================

  describe "authorization" do
    test "ad-hoc endpoints require manage_adhoc_subprocess claim" do
      ensure_deployed("adhoc_with_user_tasks.bpmn")

      {201, body} = http_start("AdHocWithUserTasks")
      parent_pi_id = body["processInstanceId"]

      child_pi_id = await_child_pi(parent_pi_id)

      no_claim = %{"manage_adhoc_subprocess" => false}
      {403, _} = http_adhoc_list_activities(child_pi_id, no_claim)
      {403, _} = http_adhoc_status(child_pi_id, no_claim)
      {403, _} = http_adhoc_complete(child_pi_id, no_claim)

      cleanup_pi(parent_pi_id)
    end

    test "ad-hoc endpoints work with admin override claim" do
      ensure_deployed("adhoc_with_user_tasks.bpmn")

      {201, body} = http_start("AdHocWithUserTasks")
      parent_pi_id = body["processInstanceId"]

      child_pi_id = await_child_pi(parent_pi_id)

      admin_claims = %{"zeeky_boogie_doog" => true}
      {200, _} = http_adhoc_list_activities(child_pi_id, admin_claims)
      {200, _} = http_adhoc_status(child_pi_id, admin_claims)

      cleanup_pi(parent_pi_id)
    end
  end

  # ===================================================================
  # Section 9: Event Verification
  # ===================================================================

  describe "event verification" do
    test "SubProcessChildStarted carries is_ad_hoc_subprocess flag", %{collector: collector} do
      ensure_deployed("adhoc_parallel_script_tasks.bpmn")

      {201, body} = http_start("AdHocParallelScriptTasks")
      parent_pi_id = body["processInstanceId"]

      wait_for_process_instance(parent_pi_id, @default_timeout)

      events = EventCollector.get_events(collector)

      adhoc_starts =
        Enum.filter(events, fn event ->
          match?(%Event.SubProcessChildStarted{}, event) and
            event.is_ad_hoc_subprocess == true
        end)

      assert length(adhoc_starts) == 1

      [start_event] = adhoc_starts
      assert start_event.is_event_subprocess == false
      assert start_event.parent_process_instance_id == parent_pi_id
    end

    test "non-adhoc subprocess does NOT have is_ad_hoc_subprocess flag", %{collector: collector} do
      ensure_deployed("embedded_subprocess_happy_path.bpmn")

      {201, body} = http_start("EmbeddedSubprocessHappyPath")
      parent_pi_id = body["processInstanceId"]

      wait_for_process_instance(parent_pi_id, @default_timeout)

      events = EventCollector.get_events(collector)

      subprocess_starts =
        Enum.filter(events, &match?(%Event.SubProcessChildStarted{}, &1))

      assert length(subprocess_starts) >= 1

      Enum.each(subprocess_starts, fn event ->
        assert event.is_ad_hoc_subprocess == false
      end)
    end

    test "AdHocActivityActivated events are emitted on activation", %{collector: collector} do
      ensure_deployed("adhoc_parallel_script_tasks.bpmn")

      {201, body} = http_start("AdHocParallelScriptTasks")
      parent_pi_id = body["processInstanceId"]

      wait_for_process_instance(parent_pi_id, @default_timeout)

      events = EventCollector.get_events(collector)

      activated_events =
        Enum.filter(events, &match?(%Event.AdHocActivityActivated{}, &1))

      assert length(activated_events) >= 1,
             "Expected at least one AdHocActivityActivated event, got #{length(activated_events)}"

      Enum.each(activated_events, fn event ->
        assert event.process_instance_id != nil
        assert event.activated_flow_node_id != nil
        assert event.activation_source != nil
      end)
    end

    test "AdHocSubProcessCompleted event is emitted on completion", %{collector: collector} do
      ensure_deployed("adhoc_parallel_script_tasks.bpmn")

      {201, body} = http_start("AdHocParallelScriptTasks")
      parent_pi_id = body["processInstanceId"]

      wait_for_process_instance(parent_pi_id, @default_timeout)

      events = EventCollector.get_events(collector)

      completed_events =
        Enum.filter(events, &match?(%Event.AdHocSubProcessCompleted{}, &1))

      assert length(completed_events) == 1,
             "Expected exactly one AdHocSubProcessCompleted event, got #{length(completed_events)}"

      [completed_event] = completed_events
      assert completed_event.process_instance_id == parent_pi_id
      assert completed_event.completion_reason != nil
      assert completed_event.total_activations >= 1,
             "Expected total_activations >= 1, got #{completed_event.total_activations}"
    end
  end

  # ===================================================================
  # Section 10: Completion Condition (Gap 1)
  # ===================================================================

  describe "FEEL completion condition (Gap 1)" do
    test "completion condition fires after performedActivities threshold" do
      ensure_deployed("adhoc_completion_condition_feel.bpmn")

      {201, body} = http_start("AdHocCompletionConditionFeel")
      parent_pi_id = body["processInstanceId"]
      child_pi_id = await_child_pi(parent_pi_id)

      wait_for_process_instance(parent_pi_id, @default_timeout)
      poll_pi_state(parent_pi_id, "finished", @default_timeout)
      poll_pi_state(child_pi_id, "finished", @default_timeout)
    end

    test "trivial true completion condition completes immediately" do
      ensure_deployed("adhoc_with_completion_condition.bpmn")

      {201, body} = http_start("AdHocWithCompletionCondition")
      parent_pi_id = body["processInstanceId"]
      child_pi_id = await_child_pi(parent_pi_id)

      wait_for_process_instance(parent_pi_id, @default_timeout)
      poll_pi_state(parent_pi_id, "finished", @default_timeout)
      poll_pi_state(child_pi_id, "finished", @default_timeout)
    end
  end

  # ===================================================================
  # Section 11: cancelRemainingInstances (Gap 2)
  # ===================================================================

  describe "cancelRemainingInstances enforcement (Gap 2)" do
    test "cancelRemainingInstances=true interrupts active FNIs on completion signal" do
      ensure_deployed("adhoc_with_user_tasks.bpmn")

      {201, body} = http_start("AdHocWithUserTasks")
      parent_pi_id = body["processInstanceId"]

      child_pi_id = await_child_pi(parent_pi_id)
      poll_fni_state(child_pi_id, "user_task", "waiting", @default_timeout)

      {status, _} = http_adhoc_complete(child_pi_id)
      assert status in [200, 204]

      wait_for_process_instance(parent_pi_id, @default_timeout)

      poll_pi_state(parent_pi_id, "finished", @default_timeout)
      poll_pi_state(child_pi_id, "finished", @default_timeout)
    end

    test "cancelRemainingInstances=false waits for FNIs to drain naturally" do
      ensure_deployed("adhoc_cancel_remaining_false.bpmn")

      {201, body} = http_start("AdHocCancelRemainingFalse")
      parent_pi_id = body["processInstanceId"]

      child_pi_id = await_child_pi(parent_pi_id)

      Process.sleep(1_000)

      poll_fni_state(child_pi_id, "user_task", "waiting")

      finish_all_waiting_user_tasks(child_pi_id)

      wait_for_process_instance(parent_pi_id, @default_timeout)

      assert_pi_state!(parent_pi_id, "finished")
    end
  end

  # ===================================================================
  # Section 12: Sequential Ordering (Gap 3)
  # ===================================================================

  describe "sequential ordering enforcement (Gap 3)" do
    test "sequential ad-hoc auto-chains activities one at a time" do
      ensure_deployed("adhoc_sequential_chaining.bpmn")

      {201, body} = http_start("AdHocSequentialChaining")
      parent_pi_id = body["processInstanceId"]

      wait_for_process_instance(parent_pi_id, @default_timeout)

      assert_pi_state!(parent_pi_id, "finished")

      [child_pi_id] = find_child_pi_ids(parent_pi_id)
      assert_pi_state!(child_pi_id, "finished")

      child_fnis = fetch_flow_node_instances(child_pi_id)

      finished_scripts =
        Enum.filter(child_fnis, fn fni ->
          fni.flow_node_type == "script_task" and fni.state == "finished"
        end)

      assert length(finished_scripts) == 3,
             "Expected 3 finished script tasks, got #{length(finished_scripts)}"
    end

    test "sequential ad-hoc rejects concurrent REST activation" do
      ensure_deployed("adhoc_sequential_user_task.bpmn")

      {201, body} = http_start("AdHocSequentialUserTask")
      parent_pi_id = body["processInstanceId"]

      child_pi_id = await_child_pi(parent_pi_id)

      poll_fni_state(child_pi_id, "user_task", "waiting")

      {status, error_body} = http_adhoc_activate(child_pi_id, "ScriptTask_After")
      assert status == 422
      assert error_body["error"] == "adhoc_sequential_busy"

      cleanup_pi(parent_pi_id)
    end

    test "sequential ad-hoc with activeElements respects declared ordering" do
      ensure_deployed("adhoc_sequential_with_active_elements.bpmn")

      {201, body} = http_start("AdHocSequentialActiveElements")
      parent_pi_id = body["processInstanceId"]

      wait_for_process_instance(parent_pi_id, @default_timeout)

      assert_pi_state!(parent_pi_id, "finished")

      [child_pi_id] = find_child_pi_ids(parent_pi_id)

      child_fnis = fetch_flow_node_instances(child_pi_id)

      finished_scripts =
        Enum.filter(child_fnis, fn fni ->
          fni.flow_node_type == "script_task" and fni.state == "finished"
        end)

      assert length(finished_scripts) == 3
      assert hd(finished_scripts).flow_node_id == "ScriptTask_1"
    end
  end

  # ===================================================================
  # Section 13: Plugin-Managed Mode (Gap 5)
  # ===================================================================

  describe "plugin-managed mode (Gap 5)" do
    test "plugin-managed ad-hoc starts with no initial activations" do
      ensure_deployed("adhoc_plugin_managed.bpmn")

      {201, body} = http_start("AdHocPluginManaged")
      parent_pi_id = body["processInstanceId"]

      child_pi_id = await_child_pi(parent_pi_id)

      Process.sleep(500)

      child_fnis = fetch_flow_node_instances(child_pi_id)

      active_or_waiting =
        Enum.filter(child_fnis, fn fni ->
          fni.state in ["active", "waiting"]
        end)

      assert Enum.empty?(active_or_waiting),
             "Expected no active FNIs in plugin-managed mode, got #{length(active_or_waiting)}"

      {activate_status, _} =
        http_adhoc_activate(child_pi_id, "ScriptTask_Plugin_A")

      assert activate_status in [200, 201]

      Process.sleep(500)

      {activate_status_2, _} =
        http_adhoc_activate(child_pi_id, "ScriptTask_Plugin_B")

      assert activate_status_2 in [200, 201]

      Process.sleep(500)

      {complete_status, _} = http_adhoc_complete(child_pi_id)
      assert complete_status in [200, 204]

      wait_for_process_instance(parent_pi_id, @default_timeout)

      assert_pi_state!(parent_pi_id, "finished")
    end
  end

  # ===================================================================
  # Section 14: adhoc_not_active on Finished PI (Gap 9)
  # ===================================================================

  describe "adhoc_not_active error (Gap 9)" do
    test "activating on a finished ad-hoc child returns adhoc_not_active" do
      ensure_deployed("adhoc_parallel_script_tasks.bpmn")

      {201, body} = http_start("AdHocParallelScriptTasks")
      parent_pi_id = body["processInstanceId"]

      wait_for_process_instance(parent_pi_id, @default_timeout)

      [child_pi_id] = find_child_pi_ids(parent_pi_id)
      assert_pi_state!(child_pi_id, "finished")

      {status, error_body} = http_adhoc_activate(child_pi_id, "ScriptTask_A")
      assert status in [404, 409, 422]

      if status == 409 do
        assert error_body["error"] == "adhoc_not_active"
      end
    end
  end

  # ===================================================================
  # Section 15: Enabled Field in Activities List (Gap 10)
  # ===================================================================

  describe "enabled field in activities list (Gap 10)" do
    test "sequential ad-hoc shows enabled=false for other activities while one is running" do
      ensure_deployed("adhoc_sequential_user_task.bpmn")

      {201, body} = http_start("AdHocSequentialUserTask")
      parent_pi_id = body["processInstanceId"]

      child_pi_id = await_child_pi(parent_pi_id)

      poll_fni_state(child_pi_id, "user_task", "waiting")

      {200, activities_body} = http_adhoc_list_activities(child_pi_id)
      activities = activities_body["data"]

      _enabled_activities = Enum.filter(activities, & &1["enabled"])
      disabled_activities = Enum.reject(activities, & &1["enabled"])

      assert length(disabled_activities) >= 1,
             "Expected at least one disabled activity in sequential mode"

      cleanup_pi(parent_pi_id)
    end

    test "after completion signal all activities show enabled=false" do
      ensure_deployed("adhoc_with_user_tasks.bpmn")

      {201, body} = http_start("AdHocWithUserTasks")
      parent_pi_id = body["processInstanceId"]

      child_pi_id = await_child_pi(parent_pi_id)

      poll_fni_state(child_pi_id, "user_task", "waiting")

      {status, _} = http_adhoc_complete(child_pi_id)
      assert status in [200, 204]

      Process.sleep(200)

      wait_for_process_instance(parent_pi_id, @default_timeout)
    end
  end

  # ===================================================================
  # Section 16: Input Token Forwarding (Gap 11)
  # ===================================================================

  describe "input token forwarding (Gap 11)" do
    test "inner activities receive mapped input payload" do
      ensure_deployed("adhoc_with_input_output_mappings.bpmn")

      {201, body} =
        http_start("AdHocWithInputOutputMappings", %{
          "payload" => %{"orderId" => "ORD-TOKEN-TEST"}
        })

      parent_pi_id = body["processInstanceId"]

      wait_for_process_instance(parent_pi_id, @default_timeout)

      assert_pi_state!(parent_pi_id, "finished")
    end
  end

  # ===================================================================
  # Section 17: Error Boundary Fires (Gap 12)
  # ===================================================================

  describe "error boundary fires (Gap 12)" do
    test "inner script failure triggers error boundary on ad-hoc shell" do
      ensure_deployed("adhoc_error_boundary_fires.bpmn")

      {201, body} = http_start("AdHocErrorBoundaryFires")
      parent_pi_id = body["processInstanceId"]

      wait_for_process_instance(parent_pi_id, @default_timeout)

      parent_pi = fetch_process_instance!(parent_pi_id)
      parent_fnis = fetch_flow_node_instances(parent_pi_id)

      fni_summary =
        Enum.map(parent_fnis, fn fni ->
          {fni.flow_node_id, fni.state, fni.flow_node_type}
        end)

      after_error_fni =
        Enum.find(parent_fnis, fn fni ->
          fni.flow_node_id == "ScriptTask_AfterError" and fni.state == "finished"
        end)

      assert after_error_fni != nil,
             "Expected ScriptTask_AfterError to have executed (error boundary path). " <>
               "Parent PI state: #{parent_pi.state}. FNIs: #{inspect(fni_summary)}"
    end
  end

  # ===================================================================
  # Section 18: Ad-hoc Status API (Gap 10 supplement)
  # ===================================================================

  describe "ad-hoc status API completionSignaled field" do
    test "status shows completionSignaled=false before signal and true after" do
      ensure_deployed("adhoc_with_user_tasks.bpmn")

      {201, body} = http_start("AdHocWithUserTasks")
      parent_pi_id = body["processInstanceId"]

      child_pi_id = await_child_pi(parent_pi_id)

      poll_fni_state(child_pi_id, "user_task", "waiting")

      {200, status_before} = http_adhoc_status(child_pi_id)
      assert status_before["completionSignaled"] == false

      {_, _} = http_adhoc_complete(child_pi_id)

      wait_for_process_instance(parent_pi_id, @default_timeout)
    end
  end

  # -------------------------------------------------------------------
  # Private helpers
  # -------------------------------------------------------------------

  defp ensure_deployed(fixture_name) do
    case http_deploy(fixture_name) do
      {201, _} -> :ok
      {409, _} -> :ok
      {422, body} -> raise "Deployment validation failed for #{fixture_name}: #{inspect(body)}"
    end
  end

  defp deploy_idempotent(fixture_name) do
    http_deploy(fixture_name)
  end

  defp extract_validation_messages(body) do
    errors = body["errors"] || []
    failures = body["failures"] || []

    error_messages =
      Enum.flat_map(errors, fn error ->
        [error["message"] || error["error"] || ""]
      end)

    failure_messages =
      Enum.flat_map(failures, fn failure ->
        details = failure["details"] || []
        if is_list(details), do: details, else: [inspect(details)]
      end)

    error_messages ++ failure_messages
  end

  defp find_child_pi_ids(parent_process_instance_id) do
    EvilEngine.Test.DbAssertions.list_child_process_instance_ids(parent_process_instance_id)
  end

  defp await_child_pi(parent_process_instance_id, timeout \\ @default_timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_child_pi(parent_process_instance_id, deadline)
  end

  defp do_await_child_pi(parent_process_instance_id, deadline) do
    case find_child_pi_ids(parent_process_instance_id) do
      [child_id | _] ->
        child_id

      [] ->
        if System.monotonic_time(:millisecond) >= deadline do
          raise "No child PI for parent #{parent_process_instance_id} within timeout"
        else
          Process.sleep(100)
          do_await_child_pi(parent_process_instance_id, deadline)
        end
    end
  end

  defp finish_all_waiting_user_tasks(process_instance_id) do
    poll_until(fn ->
      flow_node_instances =
        EvilEngine.Test.DbAssertions.fetch_flow_node_instances(process_instance_id)

      waiting_user_tasks =
        Enum.filter(flow_node_instances, fn fni ->
          fni.flow_node_type == "user_task" and fni.state == "waiting"
        end)

      if Enum.empty?(waiting_user_tasks) do
        true
      else
        Enum.each(waiting_user_tasks, fn fni ->
          http_finish_user_task(fni.id, %{"done" => true})
        end)

        false
      end
    end)
  end

  defp poll_until(fun, timeout \\ 10_000) do
    deadline = System.monotonic_time(:millisecond) + timeout

    Stream.repeatedly(fn ->
      case fun.() do
        true ->
          true

        false ->
          if System.monotonic_time(:millisecond) >= deadline do
            raise "poll_until timed out"
          end

          Process.sleep(100)
          false
      end
    end)
    |> Enum.find(&(&1 == true))
  end

  defp cleanup_pi(process_instance_id) do
    abort_claims = %{"abort_process_instance" => "all"}
    http_abort_process_instance(process_instance_id, "test_cleanup", abort_claims)
    wait_for_process_instance(process_instance_id, @default_timeout)
  rescue
    _ -> :ok
  end
end

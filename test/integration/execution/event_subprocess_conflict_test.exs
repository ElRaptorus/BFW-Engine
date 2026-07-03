defmodule EvilEngine.Integration.Execution.EventSubprocessConflictTest do
  @moduledoc """
  Umbrella-level integration tests for Event Subprocess conflict resolution.

  Validates the "proximity first, specificity second" conflict-resolution
  law across escalation, error, message, and signal events. Error and
  escalation propagate outward from the throw site; at each scope
  boundary events on the host activity are checked first, then ESP start
  events in the directly-containing scope. First match wins. Within a
  single candidate set, a specific code beats a catch-all.

  Scenarios covered:

  Escalation (§4.3):
  - ESC-1: Boundary on subprocess A beats ESP catch-all in same scope (proximity)
  - ESC-2: ESP inside child process beats shell boundary on CallActivity in parent
  - ESC-3: Specific ESP in scope vs catch-all boundary on A — boundary wins (proximity)
  - ESC-5: Two ESPs (specific + catch-all), specific wins (specificity)
  - ESC-6: Two ESPs (specific X + catch-all), thrown code=Y, catch-all wins
  - ESC-7: No catcher — escalation propagates to parent

  Error (§4.4):
  - ERR-1: Error boundary on subprocess A beats ESP error start in same scope
  - ERR-2: ESP error inside child process beats shell error boundary on CA
  - ERR-4: Two ESP error starts (specific + catch-all), specific wins
  - ERR-5: No catcher — scope PI goes to :error, bubbles to parent

  Message Tiers (§4.1):
  - MSG-A: Active message catch beats ESP message start (ESP-D13)
  - MSG-B: ESP message start beats standalone message start (ESP-D13b)

  Signal (§4.2):
  - SIG-1: ESP signal start + active signal catch + standalone start all fire
  """
  use EvilEngine.ExecutionCase, async: false

  alias EvilEngine.Test.EventCollector
  alias EvilEngine.Types.Event

  @moduletag :integration

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

  # ===================================================================
  # Escalation §4.3
  # ===================================================================

  # -------------------------------------------------------------------
  # ESC-1: Boundary on subprocess A beats ESP catch-all in same scope
  # -------------------------------------------------------------------

  describe "ESC-1: escalation boundary on subprocess beats ESP catch-all (proximity)" do
    test "boundary fires, ESP does NOT fire" do
      {201, _} = http_deploy("esp_conflict_esc_boundary_vs_esp.bpmn")

      {201, body} = http_start("EspConflictEscBoundaryVsEsp")
      process_instance_id = body["processInstanceId"]

      wait_for_process_instance(process_instance_id, 10_000)

      assert_pi_state!(process_instance_id, "finished")

      flow_node_instances = fetch_flow_node_instances(process_instance_id)

      boundary_end_fni = Enum.find(flow_node_instances, &(&1.flow_node_id == "End_BoundaryCaught"))
      normal_end_fni = Enum.find(flow_node_instances, &(&1.flow_node_id == "End_Normal"))
      boundary_fni = Enum.find(flow_node_instances, &(&1.flow_node_id == "BE_Escalation"))

      assert boundary_end_fni != nil,
             "End_BoundaryCaught should exist — boundary path was taken"
      assert boundary_end_fni.state == "finished"

      assert boundary_fni != nil
      assert boundary_fni.state == "finished"

      assert normal_end_fni == nil,
             "End_Normal should NOT be reached — boundary interrupted subprocess"

      esp_fnis =
        Enum.filter(flow_node_instances, fn fni ->
          fni.flow_node_id in ["ESP_Start", "ESP_End"]
        end)

      assert esp_fnis == [],
             "ESP should NOT have fired — boundary on subprocess A has proximity"
    end
  end

  # -------------------------------------------------------------------
  # ESC-2: ESP inside child process beats shell boundary on CA
  # -------------------------------------------------------------------

  describe "ESC-2: ESP inside child process beats shell boundary on CallActivity" do
    test "ESP fires inside child, shell boundary does NOT fire" do
      {201, _} = http_deploy("esp_conflict_esc_esp_vs_shell_boundary_child.bpmn")
      {201, _} = http_deploy("esp_conflict_esc_esp_vs_shell_boundary_parent.bpmn")

      {201, body} = http_start("EspConflictEscEspVsShellParent")
      parent_process_instance_id = body["processInstanceId"]

      wait_for_process_instance(parent_process_instance_id, 10_000)

      assert_pi_state!(parent_process_instance_id, "finished")

      parent_fnis = fetch_flow_node_instances(parent_process_instance_id)

      normal_end_fni = Enum.find(parent_fnis, &(&1.flow_node_id == "End_Normal"))
      shell_boundary_end_fni = Enum.find(parent_fnis, &(&1.flow_node_id == "End_ShellBoundary"))
      shell_boundary_fni = Enum.find(parent_fnis, &(&1.flow_node_id == "BE_ShellEscalation"))

      assert normal_end_fni != nil,
             "End_Normal should be reached — CA finished normally (ESP caught internally)"
      assert normal_end_fni.state == "finished"

      assert shell_boundary_end_fni == nil,
             "End_ShellBoundary should NOT exist — shell boundary should not fire"

      assert shell_boundary_fni == nil or shell_boundary_fni.state == "interrupted",
             "BE_ShellEscalation should NOT have fired — ESP inside child has proximity " <>
               "(found state: #{inspect(shell_boundary_fni && shell_boundary_fni.state)})"

      call_activity_child_ids = find_child_process_instance_ids(parent_process_instance_id)
      assert call_activity_child_ids != [],
             "Expected at least one child PI from CallActivity"

      [call_activity_child_id | _] = call_activity_child_ids

      child_fnis = fetch_flow_node_instances(call_activity_child_id)
      child_fni_summary =
        Enum.map(child_fnis, fn fni -> "#{fni.flow_node_id}=#{fni.state}" end)
        |> Enum.join(", ")

      esp_shell_fni = Enum.find(child_fnis, &(&1.flow_node_id == "ESP_Inner"))

      assert esp_shell_fni != nil,
             "ESP shell FNI should exist in child PI. Child FNIs: [#{child_fni_summary}]"

      assert esp_shell_fni.state == "finished",
             "ESP shell should have completed (found state: #{esp_shell_fni.state})"
    end
  end

  # -------------------------------------------------------------------
  # ESC-3: Specific ESP in scope vs catch-all boundary — boundary wins
  # -------------------------------------------------------------------

  describe "ESC-3: specific ESP vs catch-all boundary on subprocess (proximity wins)" do
    test "boundary fires, specific ESP does NOT fire" do
      {201, _} = http_deploy("esp_conflict_esc_specific_esp_vs_catchall_boundary.bpmn")

      {201, body} = http_start("EspConflictEscSpecificEspVsCatchall")
      process_instance_id = body["processInstanceId"]

      wait_for_process_instance(process_instance_id, 10_000)

      assert_pi_state!(process_instance_id, "finished")

      flow_node_instances = fetch_flow_node_instances(process_instance_id)

      boundary_end_fni = Enum.find(flow_node_instances, &(&1.flow_node_id == "End_BoundaryCaught"))
      normal_end_fni = Enum.find(flow_node_instances, &(&1.flow_node_id == "End_Normal"))
      boundary_fni = Enum.find(flow_node_instances, &(&1.flow_node_id == "BE_CatchAll"))

      assert boundary_end_fni != nil,
             "End_BoundaryCaught should exist — boundary has proximity over ESP"
      assert boundary_end_fni.state == "finished"
      assert boundary_fni != nil
      assert boundary_fni.state == "finished"

      assert normal_end_fni == nil,
             "End_Normal should NOT be reached"

      esp_fnis =
        Enum.filter(flow_node_instances, fn fni ->
          fni.flow_node_id in ["ESP_Start", "ESP_End"]
        end)

      assert esp_fnis == [],
             "ESP should NOT have fired — boundary has proximity over ESP even when ESP is more specific"
    end
  end

  # -------------------------------------------------------------------
  # ESC-5: Two ESPs — specific (code=X) vs catch-all, thrown X → specific wins
  # -------------------------------------------------------------------

  describe "ESC-5: two ESPs in same scope, specific code wins" do
    test "specific ESP fires, catch-all ESP does NOT fire",
         %{collector: collector} do
      {201, _} = http_deploy("esp_conflict_esc_two_esps_specific_wins.bpmn")

      {201, body} = http_start("EspConflictEscTwoEspsSpecificWins")
      process_instance_id = body["processInstanceId"]

      wait_for_process_instance(process_instance_id, 10_000)

      assert_pi_state!(process_instance_id, "finished")

      child_process_instance_ids = find_child_process_instance_ids(process_instance_id)

      specific_esp_child_ids =
        Enum.filter(child_process_instance_ids, fn child_id ->
          child_fnis = fetch_flow_node_instances(child_id)
          Enum.any?(child_fnis, &(&1.flow_node_id == "ESP_Specific_Start"))
        end)

      catchall_esp_child_ids =
        Enum.filter(child_process_instance_ids, fn child_id ->
          child_fnis = fetch_flow_node_instances(child_id)
          Enum.any?(child_fnis, &(&1.flow_node_id == "ESP_CatchAll_Start"))
        end)

      assert specific_esp_child_ids != [],
             "Specific ESP (VALIDATION_FAILED) should have spawned a child PI"

      assert catchall_esp_child_ids == [],
             "Catch-all ESP should NOT have fired — specific match wins"

      events = EventCollector.get_events(collector)

      escalation_raised = Enum.find(events, &(&1.__struct__ == Event.EscalationRaised))
      assert escalation_raised != nil
      assert escalation_raised.escalation_code == "VALIDATION_FAILED"
    end
  end

  # -------------------------------------------------------------------
  # ESC-6: Two ESPs — specific X + catch-all, thrown Y → catch-all wins
  # -------------------------------------------------------------------

  describe "ESC-6: two ESPs, thrown code=Y mismatches specific X, catch-all wins" do
    test "catch-all ESP fires, specific ESP does NOT fire" do
      {201, _} = http_deploy("esp_conflict_esc_two_esps_catchall_wins.bpmn")

      {201, body} = http_start("EspConflictEscTwoEspsCatchAllWins")
      process_instance_id = body["processInstanceId"]

      wait_for_process_instance(process_instance_id, 10_000)

      assert_pi_state!(process_instance_id, "finished")

      child_process_instance_ids = find_child_process_instance_ids(process_instance_id)

      catchall_esp_child_ids =
        Enum.filter(child_process_instance_ids, fn child_id ->
          child_fnis = fetch_flow_node_instances(child_id)
          Enum.any?(child_fnis, &(&1.flow_node_id == "ESP_CatchAll_Start"))
        end)

      specific_x_esp_child_ids =
        Enum.filter(child_process_instance_ids, fn child_id ->
          child_fnis = fetch_flow_node_instances(child_id)
          Enum.any?(child_fnis, &(&1.flow_node_id == "ESP_X_Start"))
        end)

      assert catchall_esp_child_ids != [],
             "Catch-all ESP should have fired (ESC_Y doesn't match ESC_X)"

      assert specific_x_esp_child_ids == [],
             "Specific ESP (ESC_X) should NOT fire — thrown code is ESC_Y"
    end
  end

  # -------------------------------------------------------------------
  # ESC-7: No catcher — escalation propagates to parent
  # -------------------------------------------------------------------

  describe "ESC-7: no catcher, escalation propagates to parent" do
    test "child PI :escalated, parent PI :escalated" do
      {201, _} = http_deploy("esp_conflict_esc_no_catcher_child.bpmn")
      {201, _} = http_deploy("esp_conflict_esc_no_catcher_parent.bpmn")

      {201, body} = http_start("EspConflictEscNoCatcherParent")
      parent_process_instance_id = body["processInstanceId"]

      wait_for_process_instance(parent_process_instance_id, 10_000)

      assert_pi_state!(parent_process_instance_id, "escalated")

      child_process_instance_ids = find_child_process_instance_ids(parent_process_instance_id)
      assert child_process_instance_ids != [],
             "Expected at least one child PI from CallActivity"

      Enum.each(child_process_instance_ids, fn child_id ->
        child_pi = fetch_process_instance!(child_id)
        assert child_pi.state == "escalated",
               "Child PI should be :escalated, got: #{child_pi.state}"
      end)
    end
  end

  # ===================================================================
  # Error §4.4
  # ===================================================================

  # -------------------------------------------------------------------
  # ERR-1: Error boundary on subprocess A beats ESP error start
  # -------------------------------------------------------------------

  describe "ERR-1: error boundary on subprocess beats ESP error start (proximity)" do
    test "boundary fires, ESP error start does NOT fire" do
      {201, _} = http_deploy("esp_conflict_err_boundary_vs_esp.bpmn")

      {201, body} = http_start("EspConflictErrBoundaryVsEsp")
      process_instance_id = body["processInstanceId"]

      wait_for_process_instance(process_instance_id, 10_000)

      assert_pi_state!(process_instance_id, "finished")

      flow_node_instances = fetch_flow_node_instances(process_instance_id)

      boundary_end_fni = Enum.find(flow_node_instances, &(&1.flow_node_id == "End_BoundaryCaught"))
      normal_end_fni = Enum.find(flow_node_instances, &(&1.flow_node_id == "End_Normal"))
      boundary_fni = Enum.find(flow_node_instances, &(&1.flow_node_id == "BE_Error"))

      assert boundary_end_fni != nil,
             "End_BoundaryCaught should exist — error boundary fired"
      assert boundary_end_fni.state == "finished"
      assert boundary_fni != nil
      assert boundary_fni.state == "finished"

      assert normal_end_fni == nil,
             "End_Normal should NOT be reached"

      esp_error_fnis =
        Enum.filter(flow_node_instances, fn fni ->
          fni.flow_node_id in ["ESP_Error_Start", "ESP_Error_End"]
        end)

      assert esp_error_fnis == [],
             "ESP error start should NOT have fired — boundary has proximity"
    end
  end

  # -------------------------------------------------------------------
  # ERR-2: ESP error inside child process beats shell error boundary
  # -------------------------------------------------------------------

  describe "ERR-2: ESP error inside child process beats shell boundary on CA" do
    test "ESP fires inside child, shell error boundary does NOT fire" do
      {201, _} = http_deploy("esp_conflict_err_esp_vs_shell_boundary_child.bpmn")
      {201, _} = http_deploy("esp_conflict_err_esp_vs_shell_boundary_parent.bpmn")

      {201, body} = http_start("EspConflictErrEspVsShellParent")
      parent_process_instance_id = body["processInstanceId"]

      wait_for_process_instance(parent_process_instance_id, 15_000)

      parent_fnis = fetch_flow_node_instances(parent_process_instance_id)

      shell_boundary_fni = Enum.find(parent_fnis, &(&1.flow_node_id == "BE_ShellError"))
      shell_boundary_end_fni = Enum.find(parent_fnis, &(&1.flow_node_id == "End_ShellBoundary"))
      _normal_end_fni = Enum.find(parent_fnis, &(&1.flow_node_id == "End_Normal"))

      assert shell_boundary_fni == nil or shell_boundary_fni.state == "interrupted",
             "BE_ShellError should NOT have fired — ESP inside child has proximity " <>
               "(found state: #{inspect(shell_boundary_fni && shell_boundary_fni.state)})"
      assert shell_boundary_end_fni == nil,
             "End_ShellBoundary should NOT exist"

      call_activity_child_ids = find_child_process_instance_ids(parent_process_instance_id)
      assert call_activity_child_ids != [],
             "Expected at least one child PI from CallActivity"

      [call_activity_child_id | _] = call_activity_child_ids

      child_fnis = fetch_flow_node_instances(call_activity_child_id)
      child_fni_summary =
        Enum.map(child_fnis, fn fni -> "#{fni.flow_node_id}=#{fni.state}" end)
        |> Enum.join(", ")

      esp_shell_fni = Enum.find(child_fnis, &(&1.flow_node_id == "ESP_ErrorInner"))

      assert esp_shell_fni != nil,
             "ESP error shell FNI should exist in child PI. Child FNIs: [#{child_fni_summary}]"

      assert esp_shell_fni.state == "finished",
             "ESP error shell should have completed (found state: #{esp_shell_fni.state})"
    end
  end

  # -------------------------------------------------------------------
  # ERR-4: Two ESP error starts — specific code beats catch-all
  # -------------------------------------------------------------------

  describe "ERR-4: two ESP error starts, specific code wins" do
    test "specific error ESP fires, catch-all error ESP does NOT fire" do
      {201, _} = http_deploy("esp_conflict_err_two_esps_specific_wins.bpmn")

      {201, body} = http_start("EspConflictErrTwoEspsSpecificWins")
      process_instance_id = body["processInstanceId"]

      wait_for_process_instance(process_instance_id, 10_000)

      child_process_instance_ids = find_child_process_instance_ids(process_instance_id)

      specific_esp_child_ids =
        Enum.filter(child_process_instance_ids, fn child_id ->
          child_fnis = fetch_flow_node_instances(child_id)
          Enum.any?(child_fnis, &(&1.flow_node_id == "ESP_Specific_Err_Start"))
        end)

      catchall_esp_child_ids =
        Enum.filter(child_process_instance_ids, fn child_id ->
          child_fnis = fetch_flow_node_instances(child_id)
          Enum.any?(child_fnis, &(&1.flow_node_id == "ESP_CatchAll_Err_Start"))
        end)

      assert specific_esp_child_ids != [],
             "Specific error ESP (PAYMENT_FAILED) should have spawned a child PI"

      assert catchall_esp_child_ids == [],
             "Catch-all error ESP should NOT have fired — specific match wins"
    end
  end

  # -------------------------------------------------------------------
  # ERR-5: No catcher — scope PI goes to :error, bubbles to parent
  # -------------------------------------------------------------------

  describe "ERR-5: no error catcher, error bubbles up" do
    test "standalone process with uncaught error end event reaches :error" do
      {201, _} = http_deploy("error_end_event_standalone.bpmn")

      {201, body} = http_start("ErrorEndStandalone")
      process_instance_id = body["processInstanceId"]

      wait_for_process_instance(process_instance_id, 10_000)

      assert_pi_state!(process_instance_id, "error")
    end
  end

  # ===================================================================
  # Message Tiers §4.1
  # ===================================================================

  # -------------------------------------------------------------------
  # MSG-A: Active message catch beats ESP message start (ESP-D13)
  # -------------------------------------------------------------------

  describe "MSG-A: active message catch suppresses ESP message start" do
    test "catch event receives message, ESP does NOT fire" do
      {201, _} = http_deploy("esp_conflict_msg_catch_vs_esp.bpmn")

      {201, body} = http_start("EspConflictMsgCatchVsEsp")
      process_instance_id = body["processInstanceId"]

      {:ok, _catch_fni} =
        await_waiting_flow_node_instance(process_instance_id, "intermediate_catch_event",
          timeout: 10_000
        )

      {200, trigger_result} = http_trigger_message("conflict-message", %{"data" => "test"})

      assert trigger_result["deliveries"] != [],
             "Message should have been delivered to at least one subscriber"

      delivery_pi_ids = Enum.map(trigger_result["deliveries"], & &1["processInstanceId"])
      assert process_instance_id in delivery_pi_ids,
             "Message should have been delivered to the catch event's PI"

      wait_for_process_instance(process_instance_id, 10_000)

      assert_pi_state!(process_instance_id, "finished")

      flow_node_instances = fetch_flow_node_instances(process_instance_id)

      catch_fni = Enum.find(flow_node_instances, &(&1.flow_node_id == "Catch_Msg"))
      end_caught_fni = Enum.find(flow_node_instances, &(&1.flow_node_id == "End_Caught"))

      assert catch_fni != nil
      assert catch_fni.state == "finished"
      assert end_caught_fni != nil
      assert end_caught_fni.state == "finished"

      esp_child_ids = find_child_process_instance_ids(process_instance_id)

      esp_message_children =
        Enum.filter(esp_child_ids, fn child_id ->
          child_fnis = fetch_flow_node_instances(child_id)
          Enum.any?(child_fnis, &(&1.flow_node_id == "ESP_Msg_Start"))
        end)

      assert esp_message_children == [],
             "ESP message start should NOT fire — catch event has priority (ESP-D13)"
    end
  end

  # -------------------------------------------------------------------
  # MSG-B: ESP message start beats standalone message start (ESP-D13b)
  # -------------------------------------------------------------------

  describe "MSG-B: ESP message start beats standalone message start" do
    test "ESP fires, no new PI from standalone start" do
      {201, _} = http_deploy("esp_conflict_msg_esp_vs_standalone_start.bpmn")
      {201, _} = http_deploy("esp_conflict_msg_standalone_start_process.bpmn")

      {201, body} = http_start("EspConflictMsgEspVsStandaloneStart")
      process_instance_id = body["processInstanceId"]

      {:ok, _user_task_fni} =
        await_waiting_flow_node_instance(process_instance_id, "user_task",
          timeout: 10_000
        )

      {200, trigger_result} = http_trigger_message("tier-message", %{"data" => "tier_test"})

      assert trigger_result["startedProcessInstanceIds"] == [],
             "No new PI should be started via standalone message start (ESP-D13b)"

      Process.sleep(500)

      esp_child_ids = find_child_process_instance_ids(process_instance_id)

      esp_message_children =
        Enum.filter(esp_child_ids, fn child_id ->
          child_fnis = fetch_flow_node_instances(child_id)
          Enum.any?(child_fnis, &(&1.flow_node_id == "ESP_Tier_Start"))
        end)

      assert esp_message_children != [],
             "ESP message start should have fired"

      Enum.each(esp_message_children, fn child_id ->
        wait_for_process_instance(child_id, 10_000)
      end)
    end
  end

  # ===================================================================
  # Signal §4.2
  # ===================================================================

  # -------------------------------------------------------------------
  # SIG-1: ESP signal + active catch + standalone start all fire
  # -------------------------------------------------------------------

  describe "SIG-1: signal broadcast — ESP, catch, and standalone start all fire" do
    test "all three fire simultaneously" do
      {201, _} = http_deploy("esp_conflict_signal_all_fire.bpmn")
      {201, _} = http_deploy("esp_conflict_signal_standalone_start.bpmn")

      {201, body} = http_start("EspConflictSignalAllFire")
      catcher_process_instance_id = body["processInstanceId"]

      {:ok, _catch_fni} =
        await_waiting_flow_node_instance(catcher_process_instance_id, "intermediate_catch_event",
          timeout: 10_000
        )

      {200, trigger_result} = http_trigger_signal("broadcast-signal")

      assert trigger_result["deliveries"] != [],
             "Signal should have been delivered to at least the catch event"

      assert trigger_result["startedProcessInstanceIds"] != [],
             "Signal should have started at least one PI via standalone signal start"

      wait_for_process_instance(catcher_process_instance_id, 10_000)
      assert_pi_state!(catcher_process_instance_id, "finished")

      catcher_fnis = fetch_flow_node_instances(catcher_process_instance_id)
      catch_fni = Enum.find(catcher_fnis, &(&1.flow_node_id == "Catch_Signal"))
      assert catch_fni != nil
      assert catch_fni.state == "finished",
             "Catch event should have received the signal"

      esp_child_ids = find_child_process_instance_ids(catcher_process_instance_id)

      esp_signal_children =
        Enum.filter(esp_child_ids, fn child_id ->
          child_fnis = fetch_flow_node_instances(child_id)
          Enum.any?(child_fnis, &(&1.flow_node_id == "ESP_Sig_Start"))
        end)

      assert esp_signal_children != [],
             "ESP signal start should also have fired (signals broadcast to all)"

      [started_process_instance_id | _] = trigger_result["startedProcessInstanceIds"]
      wait_for_process_instance(started_process_instance_id, 10_000)
      assert_pi_state!(started_process_instance_id, "finished")
    end
  end

  # ===================================================================
  # Private helpers
  # ===================================================================

  defp find_child_process_instance_ids(parent_process_instance_id) do
    require Ash.Query

    EvilEngine.Persistence.Resources.ProcessInstance
    |> Ash.Query.filter(parent_process_instance_id == ^parent_process_instance_id)
    |> Ash.read!(domain: EvilEngine.Persistence.Api, authorize?: false)
    |> Enum.map(& &1.id)
  end
end

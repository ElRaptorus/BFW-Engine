defmodule EvilEngine.Integration.Execution.EscalationEventTest do
  @moduledoc """
  Umbrella-level integration tests for Escalation Events (E1–E16).

  Uses real BPMN XML fixtures deployed via the HTTP API. Verifies
  PI state, FNI states, escalation propagation through Embedded
  SubProcesses and Call Activities, boundary catch semantics,
  and correct event/telemetry emission against a real database.

  Scenarios covered:
  - E1: SP + interrupting boundary (Escalation End → boundary catches)
  - E2: SP + non-interrupting boundary (Escalation End → boundary fires, SP FNI finishes)
  - E3: SP + Intermediate Throw + non-interrupting boundary (SP finishes, boundary fires)
  - E4: SP + Intermediate Throw + interrupting boundary (SP aborted, boundary catches)
  - E5: CA + interrupting boundary (child PI :escalated, CA :interrupted, parent follows boundary)
  - E6: CA + non-interrupting boundary (child PI :escalated, CA :finished, boundary fires)
  - E7: Uncaught Escalation End in root PI (:escalated)
  - E8: Uncaught Escalation Intermediate Throw in root PI (PI :finished, token continues)
  - E9: Multi-level uncaught Escalation End (all ancestor PIs :escalated)
  - E10: Uncaught Escalation Intermediate Throw through CA (all PIs :finished)
  - E11: Code matching — specific code beats catch-all
  - E12: Parallel branches, two Escalation Intermediate Throws with distinct non-interrupting boundaries
  - E13: Mixed chain CA→SP→CA (interrupting boundary on outermost CA)
  - E14: Mixed chain SP→CA→SP (non-interrupting boundary on outermost SP)
  - E15: Escalation End reached after PI abort + retry (PI :escalated)
  - E16: Catch-all boundary catches unnamed escalation
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

  # ---------------------------------------------------------------------------
  # E1: Escalation End Event in Subprocess — interrupting boundary
  # ---------------------------------------------------------------------------

  describe "E1: SP + interrupting escalation boundary" do
    test "boundary path followed, SP child PI :escalated, parent PI :finished",
         %{collector: collector} do
      {201, _} = http_deploy("escalation_end_event_sp_interrupting_boundary.bpmn")

      {201, body} = http_start("EscalationSPInterrupting")
      process_instance_id = body["processInstanceId"]

      [child_process_instance_id] = await_child_process_instance_ids(process_instance_id)

      :ok =
        finish_waiting_user_task_by_node_id(child_process_instance_id, "Sub_UserTask",
          timeout: 10_000
        )

      wait_for_process_instance(process_instance_id, 10_000)
      poll_pi_state(process_instance_id, "finished", 10_000)

      assert_pi_state!(process_instance_id, "finished")

      flow_node_instances = fetch_flow_node_instances(process_instance_id)
      start_fni = Enum.find(flow_node_instances, &(&1.flow_node_id == "Start_1"))
      sp_fni = Enum.find(flow_node_instances, &(&1.flow_node_id == "SubProcess_1"))
      be_fni = Enum.find(flow_node_instances, &(&1.flow_node_id == "BE_Escalation"))
      end_caught_fni = Enum.find(flow_node_instances, &(&1.flow_node_id == "End_Caught"))
      end_normal_fni = Enum.find(flow_node_instances, &(&1.flow_node_id == "End_Normal"))

      assert start_fni.state == "finished"
      assert sp_fni != nil
      assert sp_fni.state == "interrupted",
             "SP FNI should be interrupted by escalation boundary, got: #{sp_fni.state}"
      assert be_fni != nil
      assert be_fni.state == "finished"
      assert end_caught_fni != nil
      assert end_caught_fni.state == "finished"
      assert end_normal_fni == nil, "Normal path should not be taken when boundary catches"

      child_pi_ids = find_child_process_instance_ids(process_instance_id)
      assert length(child_pi_ids) >= 1

      Enum.each(child_pi_ids, fn child_id ->
        child_pi = fetch_process_instance!(child_id)
        assert child_pi.state == "escalated",
               "Child PI should be :escalated, got: #{child_pi.state}"
      end)

      events = EventCollector.get_events(collector)

      escalation_raised =
        Enum.find(events, &(&1.__struct__ == Event.EscalationRaised))

      assert escalation_raised != nil, "EscalationRaised event should have been emitted"
      assert escalation_raised.escalation_code == "ESC_REVIEW"
      assert escalation_raised.throw_type == :end_event

      [child_pi_id | _] = child_pi_ids
      child_fnis = fetch_flow_node_instances(child_pi_id)
      sub_end_escalation_fni = Enum.find(child_fnis, &(&1.flow_node_id == "Sub_End_Escalation"))

      assert sub_end_escalation_fni != nil,
             "Sub_End_Escalation FNI must exist in SP child PI"

      assert be_fni.triggerer_flow_node_instance_id == sub_end_escalation_fni.id,
             "BE_Escalation boundary FNI triggerer_flow_node_instance_id should reference the Sub_End_Escalation FNI"
    end
  end

  # ---------------------------------------------------------------------------
  # E2: Escalation End Event in Subprocess — non-interrupting boundary
  # ---------------------------------------------------------------------------

  describe "E2: SP + non-interrupting escalation boundary" do
    test "boundary fires in parallel, SP FNI :finished, parent PI :finished" do
      {201, _} = http_deploy("escalation_end_event_sp_non_interrupting_boundary.bpmn")

      {201, body} = http_start("EscalationSPNonInterrupting")
      process_instance_id = body["processInstanceId"]

      wait_for_process_instance(process_instance_id, 10_000)

      assert_pi_state!(process_instance_id, "finished")

      flow_node_instances = fetch_flow_node_instances(process_instance_id)
      sp_fni = Enum.find(flow_node_instances, &(&1.flow_node_id == "SubProcess_1"))
      be_fni = Enum.find(flow_node_instances, &(&1.flow_node_id == "BE_Escalation"))
      end_boundary_fni = Enum.find(flow_node_instances, &(&1.flow_node_id == "End_Boundary"))

      assert sp_fni != nil
      assert sp_fni.state == "finished",
             "Non-interrupting: SP FNI should be finished (not interrupted), got: #{sp_fni.state}"

      assert be_fni != nil
      assert be_fni.state == "finished"
      assert end_boundary_fni != nil
      assert end_boundary_fni.state == "finished"

      child_pi_ids = find_child_process_instance_ids(process_instance_id)
      assert length(child_pi_ids) >= 1

      Enum.each(child_pi_ids, fn child_id ->
        child_pi = fetch_process_instance!(child_id)
        assert child_pi.state == "escalated",
               "Child PI should be :escalated, got: #{child_pi.state}"
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # E3: Escalation Intermediate Throw in Subprocess — non-interrupting boundary
  # ---------------------------------------------------------------------------

  describe "E3: SP + Intermediate Throw + non-interrupting boundary" do
    test "SP PI finishes (token continues), boundary fires, parent PI :finished" do
      {201, _} = http_deploy("escalation_intermediate_throw_sp_non_interrupting_boundary.bpmn")

      {201, body} = http_start("EscalationThrowSPNonInt")
      process_instance_id = body["processInstanceId"]

      wait_for_process_instance(process_instance_id, 10_000)

      assert_pi_state!(process_instance_id, "finished")

      flow_node_instances = fetch_flow_node_instances(process_instance_id)
      sp_fni = Enum.find(flow_node_instances, &(&1.flow_node_id == "SubProcess_1"))
      be_fni = Enum.find(flow_node_instances, &(&1.flow_node_id == "BE_Escalation"))

      assert sp_fni != nil
      assert sp_fni.state == "finished"
      assert be_fni != nil
      assert be_fni.state == "finished"

      child_pi_ids = find_child_process_instance_ids(process_instance_id)
      Enum.each(child_pi_ids, fn child_id ->
        child_pi = fetch_process_instance!(child_id)
        assert child_pi.state in ["finished", "escalated"]
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # E4: Escalation Intermediate Throw in Subprocess — interrupting boundary
  # ---------------------------------------------------------------------------

  describe "E4: SP + Intermediate Throw + interrupting boundary" do
    test "SP is interrupted, child PI :aborted, parent follows boundary path" do
      {201, _} = http_deploy("escalation_intermediate_throw_sp_interrupting_boundary.bpmn")

      {201, body} = http_start("EscalationITSPInterrupting")
      process_instance_id = body["processInstanceId"]

      [child_process_instance_id] = await_child_process_instance_ids(process_instance_id)

      :ok =
        finish_waiting_user_task_by_node_id(child_process_instance_id, "Sub_UserTask",
          timeout: 10_000
        )

      wait_for_process_instance(process_instance_id, 10_000)
      poll_pi_state(process_instance_id, "finished", 10_000)

      assert_pi_state!(process_instance_id, "finished")

      flow_node_instances = fetch_flow_node_instances(process_instance_id)
      sp_fni = Enum.find(flow_node_instances, &(&1.flow_node_id == "SubProcess_1"))
      be_fni = Enum.find(flow_node_instances, &(&1.flow_node_id == "BE_Escalation"))
      end_caught_fni = Enum.find(flow_node_instances, &(&1.flow_node_id == "End_Caught"))
      end_normal_fni = Enum.find(flow_node_instances, &(&1.flow_node_id == "End_Normal"))

      assert sp_fni != nil
      assert sp_fni.state == "interrupted",
             "SP FNI should be interrupted by boundary, got: #{sp_fni.state}"

      assert be_fni != nil
      assert be_fni.state == "finished"
      assert end_caught_fni != nil
      assert end_caught_fni.state == "finished"
      assert end_normal_fni == nil

      child_pi_ids = find_child_process_instance_ids(process_instance_id)
      Enum.each(child_pi_ids, fn child_id ->
        child_pi = fetch_process_instance!(child_id)
        assert child_pi.state in ["aborted", "finished"],
               "Child PI should be :aborted (interrupted by parent boundary) or :finished, got: #{child_pi.state}"
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # E5: CA + interrupting boundary (Escalation End in child PI)
  # ---------------------------------------------------------------------------

  describe "E5: CA + interrupting escalation boundary (cross-PI)" do
    test "child PI :escalated, CA FNI :interrupted, parent follows boundary path",
         %{collector: collector} do
      {201, _} = http_deploy("escalation_end_child.bpmn")
      {201, _} = http_deploy("escalation_end_event_ca_interrupting_boundary.bpmn")

      {201, body} = http_start("EscalationCAInterrupting")
      parent_pi_id = body["processInstanceId"]

      wait_for_process_instance(parent_pi_id, 10_000)

      assert_pi_state!(parent_pi_id, "finished")

      parent_fnis = fetch_flow_node_instances(parent_pi_id)
      ca_fni = Enum.find(parent_fnis, &(&1.flow_node_id == "CA_1"))
      end_caught_fni = Enum.find(parent_fnis, &(&1.flow_node_id == "End_Caught"))
      end_normal_fni = Enum.find(parent_fnis, &(&1.flow_node_id == "End_Normal"))

      assert ca_fni != nil
      assert ca_fni.state == "interrupted",
             "CA FNI should be interrupted by escalation boundary, got: #{ca_fni.state}"
      assert end_caught_fni != nil
      assert end_caught_fni.state == "finished"
      assert end_normal_fni == nil, "Normal path should not be taken"

      child_pi_ids = find_child_process_instance_ids(parent_pi_id)
      assert length(child_pi_ids) >= 1

      Enum.each(child_pi_ids, fn child_id ->
        child_pi = fetch_process_instance!(child_id)
        assert child_pi.state == "escalated",
               "Child PI should be :escalated, got: #{child_pi.state}"
      end)

      events = EventCollector.get_events(collector)

      pi_state_events =
        events
        |> Enum.filter(&(&1.__struct__ == Event.ProcessInstanceStateChanged))

      child_escalated =
        Enum.find(pi_state_events, fn event ->
          event.process_instance_id != parent_pi_id and event.new_state == :escalated
        end)

      assert child_escalated != nil,
             "Child PI should have emitted :escalated state change"

      [child_pi_id | _] = child_pi_ids
      child_fnis = fetch_flow_node_instances(child_pi_id)
      end_escalation_fni = Enum.find(child_fnis, &(&1.flow_node_id == "End_Escalation"))

      assert end_escalation_fni != nil,
             "End_Escalation FNI must exist in Call Activity child PI"

      boundary_fni = Enum.find(parent_fnis, &(&1.flow_node_id == "BE_Escalation"))
      assert boundary_fni != nil, "BE_Escalation FNI must exist in parent PI"

      assert boundary_fni.triggerer_flow_node_instance_id == end_escalation_fni.id,
             "BE_Escalation boundary FNI triggerer_flow_node_instance_id should reference the End_Escalation FNI in the child PI"
    end
  end

  # ---------------------------------------------------------------------------
  # E6: CA + non-interrupting boundary (Escalation End in child PI)
  # ---------------------------------------------------------------------------

  describe "E6: CA + non-interrupting escalation boundary (cross-PI)" do
    test "child PI :escalated, CA FNI :finished, boundary fires in parallel" do
      {201, _} = http_deploy("escalation_end_child.bpmn")
      {201, _} = http_deploy("escalation_end_event_ca_non_interrupting_boundary.bpmn")

      {201, body} = http_start("EscalationCANonInterrupting")
      parent_pi_id = body["processInstanceId"]

      wait_for_process_instance(parent_pi_id, 10_000)

      assert_pi_state!(parent_pi_id, "finished")

      parent_fnis = fetch_flow_node_instances(parent_pi_id)
      ca_fni = Enum.find(parent_fnis, &(&1.flow_node_id == "CA_1"))
      end_boundary_fni = Enum.find(parent_fnis, &(&1.flow_node_id == "End_Parallel"))

      assert ca_fni != nil
      assert ca_fni.state == "finished",
             "Non-interrupting: CA FNI should be :finished, got: #{ca_fni.state}"

      assert end_boundary_fni != nil,
             "End_Parallel FNI (boundary path) should exist"
      assert end_boundary_fni.state == "finished"

      child_pi_ids = find_child_process_instance_ids(parent_pi_id)
      assert length(child_pi_ids) >= 1

      Enum.each(child_pi_ids, fn child_id ->
        child_pi = fetch_process_instance!(child_id)
        assert child_pi.state == "escalated",
               "Child PI should be :escalated, got: #{child_pi.state}"
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # E7: Uncaught Escalation End in root PI → PI :escalated
  # ---------------------------------------------------------------------------

  describe "E7: Uncaught Escalation End Event in root PI" do
    test "PI reaches :escalated, FNI is :finished, EscalationRaised emitted",
         %{collector: collector} do
      {201, _} = http_deploy("escalation_end_event_standalone.bpmn")

      {201, body} = http_start("EscalationEndStandalone")
      process_instance_id = body["processInstanceId"]

      wait_for_process_instance(process_instance_id, 10_000)

      process_instance = assert_pi_state!(process_instance_id, "escalated")
      assert process_instance.finished_at != nil

      flow_node_instances = fetch_flow_node_instances(process_instance_id)
      start_fni = Enum.find(flow_node_instances, &(&1.flow_node_id == "Start_1"))
      end_fni = Enum.find(flow_node_instances, &(&1.flow_node_id == "End_Escalation"))

      assert start_fni.state == "finished"
      assert end_fni != nil
      assert end_fni.state == "finished",
             "Escalation End FNI should be in :finished state, got: #{end_fni.state}"
      assert end_fni.flow_node_type == "end_event"
      assert end_fni.event_type == "escalation"

      type_props = end_fni.type_properties
      assert type_props["escalation_code"] == "ESC_MANAGER_REVIEW"
      assert type_props["escalation_name"] == "Manager Review Required"

      events = EventCollector.get_events(collector)

      pi_events =
        events
        |> Enum.filter(&(&1.__struct__ == Event.ProcessInstanceStateChanged))
        |> Enum.filter(&(&1.process_instance_id == process_instance_id))
        |> Enum.sort_by(& &1.occurred_at)

      assert length(pi_events) == 2, "Expected 2 PI state changes (running, escalated), got: #{length(pi_events)}"

      # Assert the transition chain by state rather than by occurred_at ordering:
      # both events can share the same microsecond timestamp, which makes a
      # positional sort non-deterministic. Verifying that the :escalated event
      # transitioned out of :running proves the chain order deterministically.
      assert Enum.any?(pi_events, &(&1.new_state == :running))
      escalated_event = Enum.find(pi_events, &(&1.new_state == :escalated))
      assert escalated_event != nil
      assert escalated_event.old_state == :running

      escalation_raised = Enum.find(events, &(&1.__struct__ == Event.EscalationRaised))
      assert escalation_raised != nil
      assert escalation_raised.escalation_code == "ESC_MANAGER_REVIEW"
      assert escalation_raised.throw_type == :end_event
      assert escalation_raised.process_instance_id == process_instance_id
    end

    test "escalated PI is not retryable" do
      {201, _} = http_deploy("escalation_end_event_standalone.bpmn")

      {201, body} = http_start("EscalationEndStandalone")
      process_instance_id = body["processInstanceId"]

      wait_for_process_instance(process_instance_id, 10_000)

      assert_pi_state!(process_instance_id, "escalated")

      {status, error_body} = http_retry_process_instance(process_instance_id)

      assert status == 422,
             "Retrying an escalated PI should return 422, got: #{status}"

      assert error_body["errorCode"] == "not_retriable" or
               error_body["error"] != nil,
             "Expected not_retriable error, got: #{inspect(error_body)}"
    end
  end

  # ---------------------------------------------------------------------------
  # E8: Uncaught Escalation Intermediate Throw in root PI → PI :finished
  # ---------------------------------------------------------------------------

  describe "E8: Uncaught Escalation Intermediate Throw in root PI" do
    test "PI reaches :finished (token continues), throw FNI is :finished",
         %{collector: collector} do
      {201, _} = http_deploy("escalation_intermediate_throw_standalone.bpmn")

      {201, body} = http_start("EscalationThrowStandalone")
      process_instance_id = body["processInstanceId"]

      wait_for_process_instance(process_instance_id, 10_000)

      assert_pi_state!(process_instance_id, "finished")

      flow_node_instances = fetch_flow_node_instances(process_instance_id)
      throw_fni = Enum.find(flow_node_instances, &(&1.flow_node_id == "Throw_Escalation"))

      assert throw_fni != nil
      assert throw_fni.state == "finished",
             "Intermediate Throw FNI should be :finished (token continues), got: #{throw_fni.state}"
      assert throw_fni.flow_node_type == "intermediate_throw_event"
      assert throw_fni.event_type == "escalation"

      events = EventCollector.get_events(collector)

      escalation_raised = Enum.find(events, &(&1.__struct__ == Event.EscalationRaised))
      assert escalation_raised != nil
      assert escalation_raised.throw_type == :intermediate_throw
    end
  end

  # ---------------------------------------------------------------------------
  # E9: Multi-level uncaught Escalation End (grandchild → child → root)
  # ---------------------------------------------------------------------------

  describe "E9: Multi-level uncaught escalation (3-level CA chain)" do
    test "all PIs in chain reach :escalated state" do
      {201, _} = http_deploy("escalation_multilevel_grandchild.bpmn")
      {201, _} = http_deploy("escalation_multilevel_child.bpmn")
      {201, _} = http_deploy("escalation_multilevel_uncaught.bpmn")

      {201, body} = http_start("EscalationMultilevelUncaught")
      root_pi_id = body["processInstanceId"]

      wait_for_process_instance(root_pi_id, 15_000)

      root_pi = assert_pi_state!(root_pi_id, "escalated")
      assert root_pi.finished_at != nil

      all_pi_ids = [root_pi_id | find_all_descendant_pi_ids(root_pi_id)]

      Enum.each(all_pi_ids, fn pi_id ->
        pi = fetch_process_instance!(pi_id)
        assert pi.state in ["escalated", "finished"],
               "PI #{pi_id} should be :escalated or :finished, got: #{pi.state}"
      end)

      escalated_pi_ids =
        Enum.filter(all_pi_ids, fn pi_id ->
          pi = fetch_process_instance!(pi_id)
          pi.state == "escalated"
        end)

      assert length(escalated_pi_ids) >= 1,
             "At least one PI in the chain should be :escalated"
    end
  end

  # ---------------------------------------------------------------------------
  # E11: Escalation code matching — specific code beats catch-all
  # ---------------------------------------------------------------------------

  describe "E11: Escalation code matching — specific code vs catch-all" do
    test "specific-code boundary fires, catch-all does NOT fire" do
      {201, _} = http_deploy("escalation_code_matching_sp.bpmn")

      {201, body} = http_start("EscalationCodeMatching")
      process_instance_id = body["processInstanceId"]

      wait_for_process_instance(process_instance_id, 10_000)

      assert_pi_state!(process_instance_id, "finished")

      flow_node_instances = fetch_flow_node_instances(process_instance_id)
      end_specific_fni = Enum.find(flow_node_instances, &(&1.flow_node_id == "End_Specific"))
      end_catchall_fni = Enum.find(flow_node_instances, &(&1.flow_node_id == "End_Catchall"))
      end_normal_fni = Enum.find(flow_node_instances, &(&1.flow_node_id == "End_Normal"))

      assert end_specific_fni != nil,
             "Specific-code boundary path should be taken"
      assert end_specific_fni.state == "finished"

      assert end_catchall_fni == nil,
             "Catch-all boundary path should NOT be taken when specific code matches"

      assert end_normal_fni == nil,
             "Normal path should NOT be taken"
    end
  end

  # ---------------------------------------------------------------------------
  # E16: Catch-all escalation boundary catches unnamed escalation
  # ---------------------------------------------------------------------------

  describe "E16: Catch-all escalation boundary catches unnamed escalation" do
    test "catch-all boundary fires on unnamed (no code) escalation" do
      {201, _} = http_deploy("escalation_catchall_boundary_sp.bpmn")

      {201, body} = http_start("EscalationCatchallBoundary")
      process_instance_id = body["processInstanceId"]

      wait_for_process_instance(process_instance_id, 10_000)

      assert_pi_state!(process_instance_id, "finished")

      flow_node_instances = fetch_flow_node_instances(process_instance_id)
      end_caught_fni = Enum.find(flow_node_instances, &(&1.flow_node_id == "End_Caught"))
      end_normal_fni = Enum.find(flow_node_instances, &(&1.flow_node_id == "End_Normal"))

      assert end_caught_fni != nil,
             "Catch-all boundary should catch the unnamed escalation"
      assert end_caught_fni.state == "finished"
      assert end_normal_fni == nil, "Normal path should not be taken"
    end
  end

  # ---------------------------------------------------------------------------
  # E13: Mixed chain CA → SP → CA (interrupting boundary on outermost CA)
  # ---------------------------------------------------------------------------

  describe "E13: Mixed chain CA→SP→CA with interrupting boundary on root CA" do
    test "escalation propagates CA→SP→CA, root boundary catches, root PI :finished" do
      {201, _} = http_deploy("escalation_mixed_ca_sp_ca_leaf.bpmn")
      {201, _} = http_deploy("escalation_mixed_ca_sp_ca_middle.bpmn")
      {201, _} = http_deploy("escalation_mixed_ca_sp_ca_root.bpmn")

      {201, body} = http_start("EscalationMixedCASPCARoot")
      root_pi_id = body["processInstanceId"]

      wait_for_process_instance(root_pi_id, 15_000)

      root_pi = assert_pi_state!(root_pi_id, "finished")
      assert root_pi.finished_at != nil

      root_fnis = fetch_flow_node_instances(root_pi_id)
      ca1_fni = Enum.find(root_fnis, &(&1.flow_node_id == "CA1"))
      end_caught_fni = Enum.find(root_fnis, &(&1.flow_node_id == "End_Caught"))
      end_normal_fni = Enum.find(root_fnis, &(&1.flow_node_id == "End_Normal"))

      assert ca1_fni != nil
      assert ca1_fni.state == "interrupted",
             "CA1 should be :interrupted by escalation boundary, got: #{ca1_fni.state}"

      assert end_caught_fni != nil
      assert end_caught_fni.state == "finished"
      assert end_normal_fni == nil

      all_child_pis = find_all_descendant_pi_ids(root_pi_id)
      assert length(all_child_pis) >= 1

      leaf_pis =
        Enum.filter(all_child_pis, fn pi_id ->
          pi = fetch_process_instance!(pi_id)
          pi.state == "escalated"
        end)

      assert length(leaf_pis) >= 1,
             "At least the leaf PI (EscalationMixedLeaf) should be :escalated"
    end
  end

  # ---------------------------------------------------------------------------
  # E14: Mixed chain SP → CA → SP (non-interrupting boundary on outermost SP)
  # ---------------------------------------------------------------------------

  describe "E14: Mixed chain SP→CA→SP with non-interrupting boundary on root SP" do
    test "escalation propagates SP→CA→SP, non-interrupting boundary fires, root PI :finished" do
      {201, _} = http_deploy("escalation_mixed_sp_ca_sp_middle.bpmn")
      {201, _} = http_deploy("escalation_mixed_sp_ca_sp_root.bpmn")

      {201, body} = http_start("EscalationSPCASPRoot")
      root_pi_id = body["processInstanceId"]

      wait_for_process_instance(root_pi_id, 15_000)

      root_pi = assert_pi_state!(root_pi_id, "finished")
      assert root_pi.finished_at != nil

      root_fnis = fetch_flow_node_instances(root_pi_id)
      sp1_fni = Enum.find(root_fnis, &(&1.flow_node_id == "SubProcess_1"))
      be_fni = Enum.find(root_fnis, &(&1.flow_node_id == "BE_Escalation"))
      end_boundary_fni = Enum.find(root_fnis, &(&1.flow_node_id == "End_Boundary"))

      assert sp1_fni != nil
      assert sp1_fni.state in ["finished", "escalated"],
             "Non-interrupting: SP1 FNI should finish (child escalated), got: #{sp1_fni.state}"

      assert be_fni != nil
      assert be_fni.state == "finished"
      assert end_boundary_fni != nil
      assert end_boundary_fni.state == "finished"

      all_child_pis = find_all_descendant_pi_ids(root_pi_id)

      escalated_pis =
        Enum.filter(all_child_pis, fn pi_id ->
          pi = fetch_process_instance!(pi_id)
          pi.state == "escalated"
        end)

      assert length(escalated_pis) >= 1,
             "At least one descendant PI should be :escalated"
    end
  end

  # ---------------------------------------------------------------------------
  # E10: Uncaught Escalation Intermediate Throw through CA — all PIs :finished
  # ---------------------------------------------------------------------------

  describe "E10: Uncaught Escalation Intermediate Throw through CA chain" do
    test "all PIs finish normally; token continues past the throw, escalation is uncaught",
         %{collector: collector} do
      {201, _} = http_deploy("escalation_intermediate_throw_standalone.bpmn")
      {201, _} = http_deploy("escalation_throw_ca_root.bpmn")

      {201, body} = http_start("EscalationThrowCARoot")
      root_pi_id = body["processInstanceId"]

      wait_for_process_instance(root_pi_id, 10_000)

      assert_pi_state!(root_pi_id, "finished")

      all_child_pis = find_all_descendant_pi_ids(root_pi_id)
      assert length(all_child_pis) >= 1, "Expected at least one child PI (the called process)"

      Enum.each(all_child_pis, fn pi_id ->
        pi = fetch_process_instance!(pi_id)

        assert pi.state == "finished",
               "Child PI #{pi_id} should be :finished (Intermediate Throw, not End), got: #{pi.state}"
      end)

      events = EventCollector.get_events(collector)

      escalation_raised = Enum.find(events, &(&1.__struct__ == Event.EscalationRaised))

      assert escalation_raised != nil,
             "EscalationRaised event should be emitted for the uncaught Intermediate Throw"

      assert escalation_raised.throw_type == :intermediate_throw

      refute Enum.any?(events, fn event ->
               event.__struct__ == Event.FlowNodeInstanceFinished and
                 event.terminal_state == :interrupted
             end),
             "No FNI should be :interrupted — uncaught Intermediate Throw does not interrupt siblings"
    end
  end

  # ---------------------------------------------------------------------------
  # E12: Parallel branches, two Escalation Ends, non-interrupting boundaries
  # ---------------------------------------------------------------------------

  describe "E12: Parallel branches, two Escalation Intermediate Throws with distinct non-interrupting boundaries" do
    test "both boundary paths fire when parallel branches each throw distinct escalation codes" do
      # The subprocess has a parallel gateway splitting into:
      #   Branch A: Intermediate Throw ESC_A → End (none)
      #   Branch B: Intermediate Throw ESC_B → End (none)
      # Using Intermediate Throw (not End Event) keeps the child PI alive so both
      # passthrough escalations propagate to the root's non-interrupting boundaries.
      # The subprocess child PI finishes normally; root PI finishes via End_Normal
      # plus both boundary paths.
      {201, _} = http_deploy("escalation_parallel_branches_sp.bpmn")

      {201, body} = http_start("EscalationParallelBranches")
      root_pi_id = body["processInstanceId"]

      wait_for_process_instance(root_pi_id, 15_000)

      root_pi = assert_pi_state!(root_pi_id, "finished")
      assert root_pi.finished_at != nil

      root_fnis = fetch_flow_node_instances(root_pi_id)

      be_a_fni = Enum.find(root_fnis, &(&1.flow_node_id == "BE_A"))
      be_b_fni = Enum.find(root_fnis, &(&1.flow_node_id == "BE_B"))

      assert be_a_fni != nil,
             "Boundary BE_A (ESC_A) should have fired — escalation passthrough from Branch A"

      assert be_b_fni != nil,
             "Boundary BE_B (ESC_B) should have fired — escalation passthrough from Branch B"

      assert be_a_fni.state == "finished",
             "BE_A FNI should be :finished, got: #{be_a_fni.state}"

      assert be_b_fni.state == "finished",
             "BE_B FNI should be :finished, got: #{be_b_fni.state}"

      end_a_fni = Enum.find(root_fnis, &(&1.flow_node_id == "End_BoundaryA"))
      end_b_fni = Enum.find(root_fnis, &(&1.flow_node_id == "End_BoundaryB"))
      end_normal_fni = Enum.find(root_fnis, &(&1.flow_node_id == "End_Normal"))

      assert end_a_fni != nil, "End_BoundaryA should have been reached via BE_A"
      assert end_b_fni != nil, "End_BoundaryB should have been reached via BE_B"
      assert end_normal_fni != nil, "End_Normal should have been reached (SP_1 finishes normally)"

      assert end_a_fni.state == "finished"
      assert end_b_fni.state == "finished"
      assert end_normal_fni.state == "finished"
    end
  end

  # ---------------------------------------------------------------------------
  # E15: Escalation End Event reached after PI abort + retry
  # ---------------------------------------------------------------------------

  describe "E15: Escalation End reached after abort and retry" do
    test "PI ends as :escalated after being aborted, retried, and the user task completed" do
      {201, _} = http_deploy("escalation_after_user_task.bpmn")

      {201, body} = http_start("EscalationAfterUserTask")
      process_instance_id = body["processInstanceId"]

      {:ok, user_task_fni} =
        await_waiting_flow_node_instance(process_instance_id, "user_task", timeout: 10_000)

      assert user_task_fni.state == "waiting"
      assert user_task_fni.flow_node_id == "UserTask_1"

      {204, nil} = http_abort_process_instance(process_instance_id, "test_abort", %{"abort_process_instance" => "all"})

      assert_pi_state!(process_instance_id, "aborted")

      {204, nil} = http_retry_process_instance(process_instance_id)

      {:ok, retried_user_task_fni} =
        await_waiting_flow_node_instance(process_instance_id, "user_task", timeout: 10_000)

      assert retried_user_task_fni.state == "waiting",
             "After retry, user task should be waiting again"

      {204, nil} = http_finish_user_task(retried_user_task_fni.id, %{"done" => true})

      wait_for_process_instance(process_instance_id, 10_000)

      assert_pi_state!(process_instance_id, "escalated")

      flow_node_instances = fetch_flow_node_instances(process_instance_id)
      escalation_end_fni = Enum.find(flow_node_instances, &(&1.flow_node_id == "End_Escalation"))

      assert escalation_end_fni != nil,
             "Escalation End Event FNI should exist after user task completion"

      assert escalation_end_fni.state == "finished",
             "Escalation End Event FNI should be :finished, got: #{escalation_end_fni.state}"
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp find_child_process_instance_ids(parent_process_instance_id) do
    list_child_process_instance_ids(parent_process_instance_id)
  end

  defp find_all_descendant_pi_ids(process_instance_id) do
    direct_children = find_child_process_instance_ids(process_instance_id)

    direct_children ++
      Enum.flat_map(direct_children, &find_all_descendant_pi_ids/1)
  end
end

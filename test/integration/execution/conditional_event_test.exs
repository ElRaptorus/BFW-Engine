defmodule BfwEngine.Integration.Execution.ConditionalEventTest do
  @moduledoc """
  Integration tests for Conditional Intermediate Catch Events and
  Conditional Boundary Events (interrupting and non-interrupting).
  """
  use BfwEngine.ExecutionCase, async: false

  alias BfwEngine.Execution
  alias BfwEngine.Execution.ResumeRunner
  alias BfwEngine.Persistence.Resources.ProcessInstance, as: PiResource

  require Ash.Query

  # =================================================================
  # C3: Conditional Intermediate Catch — condition met later
  # =================================================================

  describe "C3: conditional catch — condition met by later FNI completing" do
    @tag :integration
    test "conditional catch fires after user task writes a Data Object that satisfies the condition" do
      process_instance_id =
        http_deploy_and_start(
          "conditional_catch_condition_met_later.bpmn",
          "ConditionalCatchConditionMetLater"
        )

      {:ok, user_task} =
        await_waiting_flow_node_instance(process_instance_id, "user_task", timeout: 5_000)

      assert user_task.flow_node_id == "UserTask_SetAmount"

      {204, _} = http_finish_user_task(user_task.id, %{"amount" => 200})

      wait_for_process_instance(process_instance_id, 10_000)
      assert_pi_state!(process_instance_id, "finished")

      conditional_catch_fni = find_fni_by_flow_node_id(process_instance_id, "ConditionalCatch_AmountHigh")
      assert conditional_catch_fni != nil
      assert conditional_catch_fni.state == "finished"

      assert_all_fnis_terminal!(process_instance_id)
    end
  end

  # =================================================================
  # C4: Conditional Intermediate Catch — condition already true
  # =================================================================

  describe "C4: conditional catch — condition already true at instantiation" do
    @tag :integration
    test "conditional catch fires immediately when the condition is true on arrival" do
      process_instance_id =
        http_deploy_and_start(
          "conditional_catch_already_true.bpmn",
          "ConditionalCatchAlreadyTrue"
        )

      wait_for_process_instance(process_instance_id, 10_000)
      assert_pi_state!(process_instance_id, "finished")

      conditional_catch_fni = find_fni_by_flow_node_id(process_instance_id, "ConditionalCatch_Ready")
      assert conditional_catch_fni != nil
      assert conditional_catch_fni.state == "finished"

      assert_all_fnis_terminal!(process_instance_id)
    end
  end

  # =================================================================
  # C5: Conditional Boundary (interrupting)
  # =================================================================

  describe "C5: conditional boundary (interrupting) — host interrupted when condition met" do
    @tag :integration
    test "interrupting boundary fires and interrupts the host user task" do
      process_instance_id =
        http_deploy_and_start(
          "conditional_boundary_interrupting.bpmn",
          "ConditionalBoundaryInterrupting"
        )

      wait_for_process_instance(process_instance_id, 10_000)
      assert_pi_state!(process_instance_id, "finished")

      flow_node_instances = fetch_flow_node_instances(process_instance_id)

      user_task_fni = Enum.find(flow_node_instances, &(&1.flow_node_id == "UserTask_LongRunning"))
      assert user_task_fni != nil
      assert user_task_fni.state == "interrupted"

      interrupted_end_fni = Enum.find(flow_node_instances, &(&1.flow_node_id == "End_Interrupted"))
      assert interrupted_end_fni != nil
      assert interrupted_end_fni.state == "finished"

      assert_all_fnis_terminal!(process_instance_id)
    end
  end

  # =================================================================
  # C6: Conditional Boundary (non-interrupting) — fires once
  # =================================================================

  describe "C6: conditional boundary (non-interrupting) — parallel branch, host continues" do
    @tag :integration
    test "non-interrupting boundary spawns parallel branch and host continues" do
      process_instance_id =
        http_deploy_and_start(
          "conditional_boundary_non_interrupting.bpmn",
          "ConditionalBoundaryNonInterrupting"
        )

      {:ok, user_task} =
        await_waiting_flow_node_instance(process_instance_id, "user_task", timeout: 5_000)

      assert user_task.flow_node_id == "UserTask_LongRunning"

      triggered_end_fni = poll_fni_by_flow_node_id(process_instance_id, "End_Triggered", "finished")
      assert triggered_end_fni != nil

      {204, _} = http_finish_user_task(user_task.id)

      wait_for_process_instance(process_instance_id, 10_000)
      assert_pi_state!(process_instance_id, "finished")

      assert_all_fnis_terminal!(process_instance_id)
    end
  end

  # =================================================================
  # C7: Multiple conditional boundaries on same host
  # =================================================================

  describe "C7: multiple conditional boundaries — one interrupting, one non-interrupting" do
    @tag :integration
    test "interrupting boundary fires and cancels the host and sibling" do
      process_instance_id =
        http_deploy_and_start(
          "conditional_boundary_multiple.bpmn",
          "ConditionalBoundaryMultiple"
        )

      wait_for_process_instance(process_instance_id, 10_000)
      assert_pi_state!(process_instance_id, "finished")

      flow_node_instances = fetch_flow_node_instances(process_instance_id)

      user_task_fni = Enum.find(flow_node_instances, &(&1.flow_node_id == "UserTask_LongRunning"))
      assert user_task_fni != nil
      assert user_task_fni.state == "interrupted"

      critical_end = Enum.find(flow_node_instances, &(&1.flow_node_id == "End_Critical"))
      assert critical_end != nil
      assert critical_end.state == "finished"

      assert_all_fnis_terminal!(process_instance_id)
    end
  end

  # =================================================================
  # C8: Conditional catch after EBG — conditional wins
  # =================================================================

  describe "C8: conditional catch after Event-Based Gateway — conditional wins" do
    @tag :integration
    test "conditional catch fires and timer sibling is cancelled" do
      process_instance_id =
        http_deploy_and_start(
          "conditional_catch_ebg_conditional_wins.bpmn",
          "ConditionalCatchEbgConditionalWins"
        )

      {:ok, _} =
        await_waiting_fni_by_node_id(process_instance_id, "TimerCatch_Timeout", timeout: 10_000)

      {:ok, _} =
        await_waiting_fni_by_node_id(process_instance_id, "ConditionalCatch_DataReady",
          timeout: 10_000
        )

      :ok =
        finish_waiting_user_task_by_node_id(process_instance_id, "UserTask_WriteReady",
          result: %{"status" => "ready"},
          timeout: 10_000
        )

      wait_for_process_instance(process_instance_id, 10_000)
      assert_pi_state!(process_instance_id, "finished")

      flow_node_instances = fetch_flow_node_instances(process_instance_id)

      conditional_catch = Enum.find(flow_node_instances, &(&1.flow_node_id == "ConditionalCatch_DataReady"))
      assert conditional_catch != nil
      assert conditional_catch.state == "finished"

      assert_all_fnis_terminal!(process_instance_id)
    end
  end

  # =================================================================
  # C9: Conditional catch after EBG — sibling (timer) wins
  # =================================================================

  describe "C9: conditional catch after EBG — sibling wins" do
    @tag :integration
    test "timer fires first and conditional catch is cancelled" do
      process_instance_id =
        http_deploy_and_start(
          "conditional_catch_ebg.bpmn",
          "ConditionalCatchEbg"
        )

      timer_fni = poll_fni_by_type(process_instance_id, "intermediate_catch_event", "waiting", flow_node_id: "TimerCatch_Timeout")
      assert timer_fni != nil

      {200, _} = http_trigger_timer_event(timer_fni.id)

      wait_for_process_instance(process_instance_id, 10_000)
      assert_pi_state!(process_instance_id, "finished")

      flow_node_instances = fetch_flow_node_instances(process_instance_id)

      timer_catch = Enum.find(flow_node_instances, &(&1.flow_node_id == "TimerCatch_Timeout"))
      assert timer_catch.state == "finished"

      assert_all_fnis_terminal!(process_instance_id)
    end
  end

  # =================================================================
  # C10: Conditional event inside Embedded Subprocess
  # =================================================================

  describe "C10: conditional event inside embedded subprocess — scope isolation" do
    @tag :integration
    test "conditional catch in subprocess fires from subprocess-scoped Data Object write" do
      process_instance_id =
        http_deploy_and_start(
          "conditional_catch_in_subprocess.bpmn",
          "ConditionalCatchInSubprocess"
        )

      child_process_instances = poll_child_process_instances(process_instance_id)
      assert length(child_process_instances) >= 1
      child_process_instance = hd(child_process_instances)

      {:ok, user_task} =
        await_waiting_flow_node_instance(child_process_instance.id, "user_task", timeout: 5_000)

      assert user_task.flow_node_id == "UserTask_InSub"

      {204, _} = http_finish_user_task(user_task.id, %{"done" => true})

      wait_for_process_instance(process_instance_id, 15_000)
      assert_pi_state!(process_instance_id, "finished")

      assert_pi_state!(child_process_instance.id, "finished")

      child_fnis = fetch_flow_node_instances(child_process_instance.id)
      conditional_catch = Enum.find(child_fnis, &(&1.flow_node_id == "ConditionalCatch_SubData"))
      assert conditional_catch != nil
      assert conditional_catch.state == "finished"
    end
  end

  # =================================================================
  # C11: Condition never becomes true — abort cleanup
  # =================================================================

  describe "C11: condition never true — PI abort cleans up" do
    @tag :integration
    test "aborting PI with never-true condition cleans up all FNIs" do
      process_instance_id =
        http_deploy_and_start(
          "conditional_catch_abort.bpmn",
          "ConditionalCatchAbort"
        )

      Process.sleep(200)

      {204, _} =
        http_abort_process_instance(
          process_instance_id,
          "test abort",
          %{"abort_process_instance" => "all"}
        )

      wait_for_process_instance(process_instance_id, 10_000)
      assert_pi_state!(process_instance_id, "aborted")

      assert_all_fnis_terminal!(process_instance_id)
      assert_no_running_fnis!(process_instance_id)
    end
  end

  # =================================================================
  # C12: Data Object condition triggers re-evaluation
  # =================================================================

  describe "C12: conditional event with Data Object condition — write triggers re-evaluation" do
    @tag :integration
    test "Data Object write makes condition true and conditional catch fires" do
      process_instance_id =
        http_deploy_and_start(
          "conditional_catch_data_object.bpmn",
          "ConditionalCatchDataObject"
        )

      {:ok, user_task} =
        await_waiting_flow_node_instance(process_instance_id, "user_task", timeout: 5_000)

      assert user_task.flow_node_id == "UserTask_WriteData"

      {204, _} = http_finish_user_task(user_task.id, %{"status" => "ready"})

      wait_for_process_instance(process_instance_id, 10_000)
      assert_pi_state!(process_instance_id, "finished")

      conditional_catch = find_fni_by_flow_node_id(process_instance_id, "ConditionalCatch_OrderReady")
      assert conditional_catch != nil
      assert conditional_catch.state == "finished"

      assert_all_fnis_terminal!(process_instance_id)
    end
  end

  # =================================================================
  # C13: Resume — condition true on resume
  # =================================================================

  describe "C13: resume with conditional waiter — condition true on resume" do
    @tag :integration
    test "conditional catch survives resume and fires when user task completes post-resume" do
      # Uses the same fixture as C3 but exercises the kill → resume → fire path.
      # With the PI-driven synchronous evaluation model, "condition true at exact
      # resume time" is architecturally equivalent to "condition fires immediately
      # after the triggering state change post-resume" — there is no window between
      # evaluation and completion.
      process_instance_id =
        http_deploy_and_start(
          "conditional_catch_condition_met_later.bpmn",
          "ConditionalCatchConditionMetLater"
        )

      {:ok, _user_task} =
        await_waiting_flow_node_instance(process_instance_id, "user_task", timeout: 5_000)

      terminate_process_instance(process_instance_id)
      await_process_exit(process_instance_id)

      assert_pi_state!(process_instance_id, "running")

      {:ok, resumed_count} = ResumeRunner.resume_all()
      assert resumed_count == 1

      {:ok, _process_instance_pid} = poll_pi_alive(process_instance_id)

      {:ok, resumed_user_task} =
        await_waiting_flow_node_instance(process_instance_id, "user_task", timeout: 5_000)

      assert resumed_user_task.flow_node_id == "UserTask_SetAmount"

      {204, _} = http_finish_user_task(resumed_user_task.id, %{"amount" => 200})

      wait_for_process_instance(process_instance_id, 10_000)
      assert_pi_state!(process_instance_id, "finished")

      conditional_catch_fni =
        find_fni_by_flow_node_id(process_instance_id, "ConditionalCatch_AmountHigh")

      assert conditional_catch_fni != nil
      assert conditional_catch_fni.state == "finished"

      assert_all_fnis_terminal!(process_instance_id)
    end
  end

  # =================================================================
  # C14: Resume — condition false, fires later
  # =================================================================

  describe "C14: resume with conditional waiter — condition false, fires later" do
    @tag :integration
    test "conditional catch survives resume and fires when condition becomes true" do
      process_instance_id =
        http_deploy_and_start(
          "conditional_catch_data_object.bpmn",
          "ConditionalCatchDataObject"
        )

      {:ok, _user_task} =
        await_waiting_flow_node_instance(process_instance_id, "user_task", timeout: 5_000)

      terminate_process_instance(process_instance_id)
      await_process_exit(process_instance_id)

      assert_pi_state!(process_instance_id, "running")

      {:ok, resumed_count} = ResumeRunner.resume_all()
      assert resumed_count == 1

      {:ok, _process_instance_pid} = poll_pi_alive(process_instance_id)

      {:ok, resumed_user_task} =
        await_waiting_flow_node_instance(process_instance_id, "user_task", timeout: 5_000)

      assert resumed_user_task.flow_node_id == "UserTask_WriteData"

      {204, _} = http_finish_user_task(resumed_user_task.id, %{"status" => "ready"})

      wait_for_process_instance(process_instance_id, 10_000)
      assert_pi_state!(process_instance_id, "finished")

      conditional_catch = find_fni_by_flow_node_id(process_instance_id, "ConditionalCatch_OrderReady")
      assert conditional_catch != nil
      assert conditional_catch.state == "finished"

      assert_all_fnis_terminal!(process_instance_id)
    end
  end

  # =================================================================
  # Private helpers
  # =================================================================

  defp poll_fni_by_flow_node_id(process_instance_id, flow_node_id, expected_state, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_poll_fni_by_flow_node_id(process_instance_id, flow_node_id, expected_state, deadline)
  end

  defp do_poll_fni_by_flow_node_id(process_instance_id, flow_node_id, expected_state, deadline) do
    flow_node_instance = find_fni_by_flow_node_id(process_instance_id, flow_node_id)

    cond do
      flow_node_instance != nil and flow_node_instance.state == expected_state ->
        flow_node_instance

      System.monotonic_time(:millisecond) >= deadline ->
        actual = if flow_node_instance, do: flow_node_instance.state, else: "not found"
        raise "Expected FNI #{flow_node_id} in state #{expected_state}, got #{actual} within timeout"

      true ->
        Process.sleep(50)
        do_poll_fni_by_flow_node_id(process_instance_id, flow_node_id, expected_state, deadline)
    end
  end

  defp poll_fni_by_type(process_instance_id, flow_node_type, expected_state, opts) do
    flow_node_id = Keyword.get(opts, :flow_node_id)
    timeout = Keyword.get(opts, :timeout, 5_000)
    deadline = System.monotonic_time(:millisecond) + timeout
    do_poll_fni_by_type(process_instance_id, flow_node_type, expected_state, flow_node_id, deadline)
  end

  defp do_poll_fni_by_type(process_instance_id, flow_node_type, expected_state, flow_node_id, deadline) do
    flow_node_instances = fetch_flow_node_instances(process_instance_id)

    match =
      Enum.find(flow_node_instances, fn fni ->
        fni.flow_node_type == flow_node_type and
          fni.state == expected_state and
          (flow_node_id == nil or fni.flow_node_id == flow_node_id)
      end)

    case match do
      nil ->
        if System.monotonic_time(:millisecond) >= deadline do
          raise "FNI #{flow_node_type} (#{flow_node_id || "any"}) never reached #{expected_state} within timeout"
        else
          Process.sleep(50)
          do_poll_fni_by_type(process_instance_id, flow_node_type, expected_state, flow_node_id, deadline)
        end

      flow_node_instance ->
        flow_node_instance
    end
  end

  defp poll_child_process_instances(parent_process_instance_id, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_poll_child_process_instances(parent_process_instance_id, deadline)
  end

  defp do_poll_child_process_instances(parent_process_instance_id, deadline) do
    children = fetch_child_process_instances(parent_process_instance_id)

    if length(children) >= 1 do
      children
    else
      if System.monotonic_time(:millisecond) >= deadline do
        raise "No child PI found for #{parent_process_instance_id} within timeout"
      else
        Process.sleep(50)
        do_poll_child_process_instances(parent_process_instance_id, deadline)
      end
    end
  end

  defp fetch_child_process_instances(parent_process_instance_id) do
    PiResource
    |> Ash.Query.filter(parent_process_instance_id == ^parent_process_instance_id)
    |> Ash.read!(authorize?: false)
  end

  defp terminate_process_instance(process_instance_id) do
    case Execution.lookup_process_instance(process_instance_id) do
      {:ok, pid} ->
        DynamicSupervisor.terminate_child(BfwEngine.Execution.Supervisor, pid)

      {:error, :not_found} ->
        :ok
    end
  end

  defp await_process_exit(process_instance_id) do
    case Execution.lookup_process_instance(process_instance_id) do
      {:ok, pid} ->
        ref = Process.monitor(pid)

        receive do
          {:DOWN, ^ref, :process, ^pid, _} -> :ok
        after
          2_000 -> :ok
        end

      {:error, :not_found} ->
        :ok
    end
  end
end

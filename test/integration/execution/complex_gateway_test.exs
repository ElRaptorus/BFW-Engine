defmodule EvilEngine.Integration.Execution.ComplexGatewayTest do
  @moduledoc """
  Integration tests for the Complex Gateway (Phase 5.1 + 5.2):

  - Complex Split — conditional inclusive-style fork (no unconditional
    fall-through), default-flow fallback.
  - Complex Join — single-fire threshold join driven by a FEEL
    `activationCondition` with the `activatedCount` / `incomingCount`
    bindings.
  - Twist 1 — all branches resolve but the activation condition is never
    met → PI fatal with `complex_join_condition_unmet`.
  - Twist 2 — when the join fires while sibling branches are still live,
    every active/waiting FNI inside the join's SESE region is cancelled
    (`cancelled_by_complex_join`). Nested regions cancel their own scope
    only — the enclosing region is untouched.
  - Unmarked Complex Split — an unconditional non-default outgoing flow
    still deploys; entering the split fatals `:complex_gateway_unconditional_flow`.
  """
  use EvilEngine.ExecutionCase, async: false

  alias EvilEngine.Execution
  alias EvilEngine.Execution.ResumeRunner
  alias EvilEngine.Persistence.Resources.GatewayPendingArrival

  require Ash.Query

  describe "C210: threshold join fires when activatedCount reaches the threshold" do
    @tag :integration
    test "2-of-3 branches arrive, activationCondition (>= 2) fires, PI finishes" do
      process_instance_id =
        http_deploy_and_start(
          "complex_gateway_threshold_join.bpmn",
          "ComplexGatewayThresholdJoin",
          %{"payload" => %{"a" => true, "b" => true, "c" => false}}
        )

      wait_for_process_instance(process_instance_id, 10_000)
      assert_pi_state!(process_instance_id, "finished")

      poll_fni_state(process_instance_id, "task", "finished")

      flow_node_instances = fetch_flow_node_instances(process_instance_id)

      task_a = Enum.find(flow_node_instances, &(&1.flow_node_id == "Task_A"))
      task_b = Enum.find(flow_node_instances, &(&1.flow_node_id == "Task_B"))
      join = Enum.find(flow_node_instances, &(&1.flow_node_id == "ComplexJoin"))

      assert task_a.state == "finished"
      assert task_b.state == "finished"
      assert join.state == "finished"

      # The dead branch (c = false) never starts.
      refute find_fni_by_flow_node_id(process_instance_id, "Task_C")
    end
  end

  describe "C211: Twist 1 — all branches resolved but activation condition unmet" do
    @tag :integration
    test "PI fatals with complex_join_condition_unmet when the threshold is never reached" do
      process_instance_id =
        http_deploy_and_start(
          "complex_gateway_condition_unmet.bpmn",
          "ComplexGatewayConditionUnmet",
          %{"payload" => %{"a" => true, "b" => true, "c" => false}}
        )

      wait_for_process_instance(process_instance_id, 10_000)
      assert_pi_state!(process_instance_id, "fatal")

      join = find_fni_by_flow_node_id(process_instance_id, "ComplexJoin")
      assert join != nil
      assert join.state == "fatal"
      assert join.error_info["error_code"] == "complex_join_condition_unmet"

      assert join.error_info["message"] =~
               "all branches have finished but the gateway's"
    end
  end

  describe "C212: complex split forks on every truthy condition" do
    @tag :integration
    test "two truthy conditions fork, the false branch is not activated" do
      process_instance_id =
        http_deploy_and_start(
          "complex_gateway_split_fork.bpmn",
          "ComplexGatewaySplitFork",
          %{"payload" => %{"a" => true, "b" => true, "c" => false}}
        )

      wait_for_process_instance(process_instance_id, 10_000)
      assert_pi_state!(process_instance_id, "finished")

      flow_node_instances = fetch_flow_node_instances(process_instance_id)

      assert Enum.find(flow_node_instances, &(&1.flow_node_id == "Task_A")).state == "finished"
      assert Enum.find(flow_node_instances, &(&1.flow_node_id == "Task_B")).state == "finished"
      refute Enum.find(flow_node_instances, &(&1.flow_node_id == "Task_C"))
    end
  end

  describe "C213: complex split falls back to the default flow" do
    @tag :integration
    test "no conditional matches, only the default branch executes" do
      process_instance_id =
        http_deploy_and_start(
          "complex_gateway_split_default.bpmn",
          "ComplexGatewaySplitDefault",
          %{"payload" => %{"amount" => 1}}
        )

      wait_for_process_instance(process_instance_id, 10_000)
      assert_pi_state!(process_instance_id, "finished")

      flow_node_instances = fetch_flow_node_instances(process_instance_id)

      assert Enum.find(flow_node_instances, &(&1.flow_node_id == "Task_Default")).state ==
               "finished"

      refute Enum.find(flow_node_instances, &(&1.flow_node_id == "Task_A"))
    end
  end

  describe "C214: unmarked Complex Split deploys and fatals at runtime" do
    @tag :integration
    test "unconditional non-default split flow deploys, then fatals when the split is entered" do
      {201, _} = http_deploy("complex_gateway_unconditional_split.bpmn")

      {201, body} =
        http_start("ComplexGatewayUnconditionalSplit", %{"payload" => %{"a" => true}})

      process_instance_id = body["processInstanceId"]
      wait_for_process_instance(process_instance_id, 10_000)
      assert_pi_state!(process_instance_id, "fatal")

      complex_split = find_fni_by_flow_node_id(process_instance_id, "ComplexSplit")
      assert complex_split.state == "fatal"
    end
  end

  describe "C215: Twist 2 — firing join cancels the waiting branch in its region" do
    @tag :integration
    test "two branches satisfy the threshold, the third waiting branch is cancelled" do
      process_instance_id =
        http_deploy_and_start(
          "complex_gateway_cancel_region.bpmn",
          "ComplexGatewayCancelRegion",
          %{"payload" => %{"a" => true, "b" => true, "c" => true}}
        )

      # All three branches fork to user tasks. Draining two of them satisfies the
      # join threshold (activatedCount >= 2); the third (UserTask_C) is still an
      # idle-waiting FNI inside the join's SESE region and must be cancelled when
      # the join fires. Draining user tasks (rather than plain tasks) guarantees
      # UserTask_C has reached `waiting` before the fire, so the assertion is
      # deterministic.
      {:ok, user_a} = await_waiting_fni_by_node_id(process_instance_id, "UserTask_A", timeout: 10_000)
      {:ok, user_b} = await_waiting_fni_by_node_id(process_instance_id, "UserTask_B", timeout: 10_000)
      {:ok, _user_c} = await_waiting_fni_by_node_id(process_instance_id, "UserTask_C", timeout: 10_000)

      # First arrival: activatedCount == 1 → below threshold, join keeps waiting.
      {204, _} = http_finish_user_task(user_a.id, %{"done" => true})
      # Second arrival: activatedCount == 2 → threshold met, join fires + cancels.
      {204, _} = http_finish_user_task(user_b.id, %{"done" => true})

      wait_for_process_instance(process_instance_id, 10_000)
      assert_pi_state!(process_instance_id, "finished")

      user_a_after = find_fni_by_flow_node_id(process_instance_id, "UserTask_A")
      user_b_after = find_fni_by_flow_node_id(process_instance_id, "UserTask_B")
      user_c_after = find_fni_by_flow_node_id(process_instance_id, "UserTask_C")
      join = find_fni_by_flow_node_id(process_instance_id, "ComplexJoin")

      assert user_a_after.state == "finished"
      assert user_b_after.state == "finished"
      assert join.state == "finished"

      assert user_c_after != nil, "the cancelled user task FNI must exist"

      assert user_c_after.state == "interrupted",
             "UserTask_C should be cancelled by the firing join, got: #{user_c_after.state}"

      assert to_string(user_c_after.type_properties["reason"]) == "cancelled_by_complex_join"

      # No FNI is left dangling on the finished PI.
      assert_no_running_fnis!(process_instance_id)
    end
  end

  describe "C216: Twist 2 — nested regions cancel only their own scope" do
    @tag :integration
    test "inner join fires and cancels the inner branch, the outer branch survives" do
      process_instance_id =
        http_deploy_and_start(
          "complex_gateway_nested_regions.bpmn",
          "ComplexGatewayNestedRegions",
          %{
            "payload" => %{
              "outer_left" => true,
              "outer_right" => true,
              "inner_a" => true,
              "inner_b" => true
            }
          }
        )

      # Wait until every branch has parked on its user task (all idle-waiting).
      {:ok, user_inner_a} =
        await_waiting_fni_by_node_id(process_instance_id, "UserTask_InnerA", timeout: 10_000)

      {:ok, _user_inner_b} =
        await_waiting_fni_by_node_id(process_instance_id, "UserTask_InnerB", timeout: 10_000)

      {:ok, _user_outer} =
        await_waiting_fni_by_node_id(process_instance_id, "UserTask_Outer", timeout: 10_000)

      # Inner join threshold is 1: draining UserTask_InnerA fires the inner join,
      # which cancels the inner region (UserTask_InnerB) only. The outer region's
      # UserTask_Outer keeps waiting for the still-unmet outer threshold (2).
      {204, _} = http_finish_user_task(user_inner_a.id, %{"done" => true})

      user_inner_b =
        poll_flow_node_state(process_instance_id, "UserTask_InnerB", "interrupted", 10_000)

      assert to_string(user_inner_b.type_properties["reason"]) == "cancelled_by_complex_join"

      inner_join = find_fni_by_flow_node_id(process_instance_id, "InnerJoin")
      assert inner_join.state == "finished"

      user_inner_a_after = find_fni_by_flow_node_id(process_instance_id, "UserTask_InnerA")
      assert user_inner_a_after.state == "finished"

      # The outer-region user task is NOT in the inner region and must survive.
      user_outer = find_fni_by_flow_node_id(process_instance_id, "UserTask_Outer")
      assert user_outer != nil

      assert user_outer.state in ["waiting", "active"],
             "UserTask_Outer should still be running (outer region untouched), got: #{user_outer.state}"

      # Completing the outer user task satisfies the outer join (activatedCount == 2).
      {204, _} = http_finish_user_task(user_outer.id, %{"done" => true})

      wait_for_process_instance(process_instance_id, 10_000)
      assert_pi_state!(process_instance_id, "finished")

      outer_join = find_fni_by_flow_node_id(process_instance_id, "OuterJoin")
      assert outer_join.state == "finished"

      assert_no_running_fnis!(process_instance_id)
    end
  end

  describe "C217: Twist 2 — resume mid-region rehydrates the join and still fires + cancels" do
    @tag :integration
    test "engine restart with one branch arrived: resumed PI fires the join and cancels the loser" do
      process_instance_id =
        http_deploy_and_start(
          "complex_gateway_cancel_region.bpmn",
          "ComplexGatewayCancelRegion",
          %{"payload" => %{"a" => true, "b" => true, "c" => true}}
        )

      {:ok, user_a} = await_waiting_fni_by_node_id(process_instance_id, "UserTask_A", timeout: 10_000)
      {:ok, _user_b} = await_waiting_fni_by_node_id(process_instance_id, "UserTask_B", timeout: 10_000)
      {:ok, _user_c} = await_waiting_fni_by_node_id(process_instance_id, "UserTask_C", timeout: 10_000)

      # One branch arrives at the join (activatedCount == 1 → below the >= 2
      # threshold, so the join parks and persists a single gateway pending arrival).
      {204, _} = http_finish_user_task(user_a.id, %{"done" => true})
      Process.sleep(300)

      assert length(fetch_pending_arrivals(process_instance_id)) == 1

      # Simulate an engine restart while the region is mid-flight.
      terminate_process_instance(process_instance_id)
      await_process_exit(process_instance_id)
      assert_pi_state!(process_instance_id, "running")

      {:ok, resumed_count} = ResumeRunner.resume_all()
      assert resumed_count == 1

      {:ok, _process_instance_pid} = poll_pi_alive(process_instance_id)

      # After rehydration UserTask_B and UserTask_C are waiting again, and the
      # join carries the one persisted arrival.
      {:ok, resumed_user_b} =
        await_waiting_fni_by_node_id(process_instance_id, "UserTask_B", timeout: 10_000)

      {:ok, _resumed_user_c} =
        await_waiting_fni_by_node_id(process_instance_id, "UserTask_C", timeout: 10_000)

      # Second arrival post-resume: activatedCount == 2 → the join fires and
      # cancels the still-waiting UserTask_C inside its SESE region.
      {204, _} = http_finish_user_task(resumed_user_b.id, %{"done" => true})

      wait_for_process_instance(process_instance_id, 10_000)
      assert_pi_state!(process_instance_id, "finished")

      user_c_after = find_fni_by_flow_node_id(process_instance_id, "UserTask_C")
      assert user_c_after != nil

      assert user_c_after.state == "interrupted",
             "UserTask_C should be cancelled after the resumed join fires, got: #{user_c_after.state}"

      assert to_string(user_c_after.type_properties["reason"]) == "cancelled_by_complex_join"

      join = find_fni_by_flow_node_id(process_instance_id, "ComplexJoin")
      assert join.state == "finished"

      assert fetch_pending_arrivals(process_instance_id) == []
      assert_no_running_fnis!(process_instance_id)
    end
  end

  defp fetch_pending_arrivals(process_instance_id) do
    GatewayPendingArrival
    |> Ash.Query.filter(process_instance_id == ^process_instance_id)
    |> Ash.read!(authorize?: false)
  end

  defp terminate_process_instance(process_instance_id) do
    case Execution.lookup_process_instance(process_instance_id) do
      {:ok, pid} ->
        DynamicSupervisor.terminate_child(EvilEngine.Execution.Supervisor, pid)

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

  # Poll persistence until a specific flow node reaches the expected state.
  # Unlike `poll_fni_state/4` (which matches by flow-node *type*), this matches
  # by the BPMN element ID so tests can distinguish two user tasks.
  defp poll_flow_node_state(process_instance_id, flow_node_id, expected_state, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_poll_flow_node_state(process_instance_id, flow_node_id, expected_state, deadline)
  end

  defp do_poll_flow_node_state(process_instance_id, flow_node_id, expected_state, deadline) do
    fni = find_fni_by_flow_node_id(process_instance_id, flow_node_id)

    cond do
      fni != nil and fni.state == expected_state ->
        fni

      System.monotonic_time(:millisecond) >= deadline ->
        current = if fni, do: fni.state, else: "absent"

        raise "FNI #{flow_node_id} never reached #{expected_state} within timeout " <>
                "(current state: #{current})"

      true ->
        Process.sleep(25)
        do_poll_flow_node_state(process_instance_id, flow_node_id, expected_state, deadline)
    end
  end
end

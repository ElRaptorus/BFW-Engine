defmodule BfwEngine.Integration.Execution.InclusiveGatewayTest do
  @moduledoc """
  Integration tests for inclusive gateway split, join, and dead-path elimination.
  """
  use BfwEngine.ExecutionCase, async: false

  alias BfwEngine.Execution
  alias BfwEngine.Execution.ResumeRunner
  alias BfwEngine.Persistence.Resources.GatewayPendingArrival
  alias BfwEngine.Persistence.Resources.ProcessInstance, as: PiResource

  require Ash.Query

  describe "C200: split-join with both conditions true" do
    @tag :integration
    test "finishes after both branches execute" do
      process_instance_id =
        http_deploy_and_start(
          "inclusive_gateway_both_true.bpmn",
          "InclusiveGatewayBothTrue",
          %{"payload" => %{"amount" => 50}}
        )

      wait_for_process_instance(process_instance_id, 10_000)
      assert_pi_state!(process_instance_id, "finished")

      task_a = poll_fni_finished(process_instance_id, "Task_A")
      task_b = poll_fni_finished(process_instance_id, "Task_B")

      assert task_a.flow_node_id == "Task_A"
      assert task_b.flow_node_id == "Task_B"
    end
  end

  describe "C201: split-join with one of two conditions true" do
    @tag :integration
    test "finishes with only the truthy branch executed" do
      process_instance_id =
        http_deploy_and_start(
          "inclusive_gateway_one_true.bpmn",
          "InclusiveGatewayOneTrue",
          %{"payload" => %{"amount" => 50}}
        )

      wait_for_process_instance(process_instance_id, 10_000)
      assert_pi_state!(process_instance_id, "finished")

      task_b = poll_fni_finished(process_instance_id, "Task_B")
      assert task_b.flow_node_id == "Task_B"
      refute find_fni_by_flow_node_id(process_instance_id, "Task_A")
    end
  end

  describe "C202: default path when no conditions match" do
    @tag :integration
    test "finishes through the default branch" do
      process_instance_id =
        http_deploy_and_start(
          "inclusive_gateway_default.bpmn",
          "InclusiveGatewayDefault",
          %{"payload" => %{"amount" => 1}}
        )

      wait_for_process_instance(process_instance_id, 10_000)
      assert_pi_state!(process_instance_id, "finished")

      task_default = poll_fni_finished(process_instance_id, "Task_Default")
      assert task_default.flow_node_id == "Task_Default"
      refute find_fni_by_flow_node_id(process_instance_id, "Task_A")
      refute find_fni_by_flow_node_id(process_instance_id, "Task_B")
    end
  end

  describe "C203: no matching path at split" do
    @tag :integration
    test "process instance fatals when no outgoing path is activated" do
      process_instance_id =
        http_deploy_and_start(
          "inclusive_gateway_no_match.bpmn",
          "InclusiveGatewayNoMatch",
          %{"payload" => %{"amount" => 1}}
        )

      wait_for_process_instance(process_instance_id, 10_000)
      assert_pi_state!(process_instance_id, "fatal")
    end
  end

  describe "C204: three branches with two truthy paths" do
    @tag :integration
    test "join fires after two branches arrive and dead-path eliminates the third" do
      process_instance_id =
        http_deploy_and_start(
          "inclusive_gateway_three_branches.bpmn",
          "InclusiveGatewayThreeBranches",
          %{"payload" => %{"a" => true, "b" => true, "c" => false}}
        )

      wait_for_process_instance(process_instance_id, 10_000)
      assert_pi_state!(process_instance_id, "finished")

      poll_fni_finished(process_instance_id, "Task_A")
      poll_fni_finished(process_instance_id, "Task_B")
      refute find_fni_by_flow_node_id(process_instance_id, "Task_C")
    end
  end

  describe "C205: split without join to separate end events" do
    @tag :integration
    test "finishes when truthy branches reach their own end events" do
      process_instance_id =
        http_deploy_and_start(
          "inclusive_gateway_no_join.bpmn",
          "InclusiveGatewayNoJoin",
          %{"payload" => %{"x" => true}}
        )

      wait_for_process_instance(process_instance_id, 10_000)
      assert_pi_state!(process_instance_id, "finished")

      poll_fni_finished(process_instance_id, "Task_A")
      poll_fni_finished(process_instance_id, "Task_B")
    end
  end

  describe "C207: dead-path elimination when a branch ends before the join" do
    @tag :integration
    test "join fires after one branch arrives and the other ends at a dead end" do
      process_instance_id =
        http_deploy_and_start(
          "inclusive_gateway_branch_to_end.bpmn",
          "InclusiveGatewayBranchToEnd",
          %{"payload" => %{"x" => true, "route" => "end"}}
        )

      wait_for_process_instance(process_instance_id, 10_000)
      assert_pi_state!(process_instance_id, "finished")

      poll_fni_finished(process_instance_id, "Task_A")
      poll_fni_finished(process_instance_id, "End_B")
    end
  end

  describe "resume mid-join with one branch arrived at inclusive join" do
    @tag :integration
    test "resumed process instance rebuilds join state and finishes when the remaining user task completes" do
      process_instance_id =
        http_deploy_and_start(
          "inclusive_gateway_user_task_branches.bpmn",
          "InclusiveGatewayUserTaskBranches",
          %{"payload" => %{"a" => true, "b" => true}}
        )

      user_task_flow_node_instances = poll_all_waiting_user_tasks(process_instance_id, 2)
      [user_task_a, _user_task_b] = sort_flow_node_instances_by_flow_node_id(user_task_flow_node_instances)

      {204, _} = http_finish_user_task(user_task_a.id, %{"branch" => "a"})
      Process.sleep(300)

      pending_arrivals_before_kill = fetch_pending_arrivals(process_instance_id)
      assert length(pending_arrivals_before_kill) == 1

      terminate_process_instance(process_instance_id)
      await_process_exit(process_instance_id)
      assert_pi_state!(process_instance_id, "running")

      {:ok, resumed_count} = ResumeRunner.resume_all()
      assert resumed_count == 1

      {:ok, _process_instance_pid} = poll_pi_alive(process_instance_id)

      {:ok, resumed_user_task_b} =
        await_waiting_flow_node_instance(process_instance_id, "user_task", timeout: 5_000)

      assert resumed_user_task_b.flow_node_id == "UserTask_B"

      {204, _} = http_finish_user_task(resumed_user_task_b.id, %{"branch" => "b"})

      wait_for_process_instance(process_instance_id, 10_000)
      assert_pi_state!(process_instance_id, "finished")

      assert fetch_pending_arrivals(process_instance_id) == []
    end
  end

  # =================================================================
  # Edge case: fatal on branch while join is parked
  # =================================================================

  describe "fatal on a branch while inclusive join is parked" do
    @tag :integration
    test "PI goes fatal when a service task on one branch has no handler" do
      process_instance_id =
        http_deploy_and_start(
          "inclusive_gateway_fatal_on_branch.bpmn",
          "InclusiveGatewayFatalOnBranch",
          %{"payload" => %{"a" => true, "b" => true}}
        )

      wait_for_process_instance(process_instance_id, 10_000)
      assert_pi_state!(process_instance_id, "fatal")
      assert fetch_pending_arrivals(process_instance_id) == []
    end
  end

  # =================================================================
  # Edge case: terminate end event while inclusive paths active
  # =================================================================

  describe "terminate end event interrupts inclusive gateway branches" do
    @tag :integration
    test "PI finishes when one branch reaches terminate end event, interrupting the other" do
      process_instance_id =
        http_deploy_and_start(
          "inclusive_gateway_terminate_while_parked.bpmn",
          "InclusiveGatewayTerminateWhileParked",
          %{"payload" => %{"a" => true, "b" => true}}
        )

      wait_for_process_instance(process_instance_id, 10_000)
      assert_pi_state!(process_instance_id, "finished")

      flow_node_instances = fetch_flow_node_instances(process_instance_id)

      user_task_a =
        Enum.find(flow_node_instances, &(&1.flow_node_id == "UserTask_A"))

      assert user_task_a != nil
      assert user_task_a.state == "interrupted"

      terminate_end =
        Enum.find(flow_node_instances, &(&1.flow_node_id == "TerminateEnd_1"))

      assert terminate_end != nil
      assert terminate_end.state == "finished"
    end
  end

  # =================================================================
  # Edge case: abort while inclusive join is parked
  # =================================================================

  describe "abort PI while inclusive join is parked" do
    @tag :integration
    test "all FNIs are aborted and GPA rows cleaned up" do
      process_instance_id =
        http_deploy_and_start(
          "inclusive_gateway_abort_while_parked.bpmn",
          "InclusiveGatewayAbortWhileParked",
          %{"payload" => %{"a" => true, "b" => true}}
        )

      _user_tasks = poll_all_waiting_user_tasks(process_instance_id, 2)

      {204, _} =
        http_abort_process_instance(
          process_instance_id,
          "test abort",
          %{"abort_process_instance" => "all"}
        )

      wait_for_process_instance(process_instance_id, 10_000)
      assert_pi_state!(process_instance_id, "aborted")
      assert fetch_pending_arrivals(process_instance_id) == []
    end
  end

  # =================================================================
  # Edge case: payload merge correctness at inclusive join
  # =================================================================

  describe "payload merge at inclusive join" do
    @tag :integration
    test "merged token contains keys from both branches" do
      process_instance_id =
        http_deploy_and_start(
          "inclusive_gateway_payload_merge.bpmn",
          "InclusiveGatewayPayloadMerge",
          %{"payload" => %{"a" => true, "b" => true}}
        )

      wait_for_process_instance(process_instance_id, 10_000)
      assert_pi_state!(process_instance_id, "finished")

      process_instance =
        PiResource
        |> Ash.Query.filter(id == ^process_instance_id)
        |> Ash.Query.load(:final_tokens)
        |> Ash.read_one!(authorize?: false)

      assert is_list(process_instance.final_tokens)
      assert length(process_instance.final_tokens) >= 1

      token = hd(process_instance.final_tokens)
      payload = token["payload"]

      assert payload["branch_a"] == "value_a"
      assert payload["branch_b"] == "value_b"
      assert payload["shared"] in ["from_a", "from_b"]
    end
  end

  # =================================================================
  # Edge case: inclusive gateway inside embedded subprocess
  # =================================================================

  describe "inclusive gateway inside embedded subprocess" do
    @tag :integration
    test "subprocess with inclusive split-join completes and parent finishes" do
      process_instance_id =
        http_deploy_and_start(
          "inclusive_gateway_in_subprocess.bpmn",
          "InclusiveGatewayInSubprocess",
          %{"payload" => %{"a" => true, "b" => true}}
        )

      wait_for_process_instance(process_instance_id, 15_000)

      assert_pi_state!(process_instance_id, "finished")

      child_pis = fetch_child_process_instances(process_instance_id)
      assert length(child_pis) == 1
      child_pi = hd(child_pis)
      assert child_pi.state == "finished"

      child_fnis = fetch_flow_node_instances(child_pi.id)
      inc_split = Enum.find(child_fnis, &(&1.flow_node_id == "IncSplit"))
      inc_join = Enum.find(child_fnis, &(&1.flow_node_id == "IncJoin"))
      assert inc_split.state == "finished"
      assert inc_join.state == "finished"
    end
  end

  # =================================================================
  # Edge case: retry guard — inclusive join rejected as checkpoint
  # =================================================================

  describe "retry guard for inclusive join FNI" do
    @tag :integration
    test "retry with inclusive join FNI as checkpoint returns 422" do
      process_instance_id =
        http_deploy_and_start(
          "inclusive_gateway_fatal_on_branch.bpmn",
          "InclusiveGatewayFatalOnBranch",
          %{"payload" => %{"a" => true, "b" => true}}
        )

      wait_for_process_instance(process_instance_id, 10_000)
      assert_pi_state!(process_instance_id, "fatal")

      flow_node_instances = fetch_flow_node_instances(process_instance_id)

      join_fni =
        Enum.find(flow_node_instances, fn fni ->
          fni.flow_node_type == "inclusive_gateway" and fni.flow_node_id == "IncJoin"
        end)

      if join_fni do
        {422, error_body} =
          http_retry_process_instance(
            process_instance_id,
            %{"resetToFlowNodeInstanceId" => join_fni.id}
          )

        assert error_body["error"] == "retry_checkpoint_is_join_gateway"
      end
    end
  end

  defp fetch_pending_arrivals(process_instance_id) do
    GatewayPendingArrival
    |> Ash.Query.filter(process_instance_id == ^process_instance_id)
    |> Ash.read!(authorize?: false)
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

  defp poll_fni_finished(process_instance_id, flow_node_id, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_poll_fni_state(process_instance_id, flow_node_id, "finished", deadline)
  end

  defp do_poll_fni_state(process_instance_id, flow_node_id, expected_state, deadline) do
    flow_node_instance = find_fni_by_flow_node_id(process_instance_id, flow_node_id)

    cond do
      flow_node_instance != nil and flow_node_instance.state == expected_state ->
        flow_node_instance

      System.monotonic_time(:millisecond) >= deadline ->
        actual = if flow_node_instance, do: flow_node_instance.state, else: "not found"

        raise "Expected FNI #{flow_node_id} in state #{expected_state}, got #{actual} within timeout"

      true ->
        Process.sleep(50)
        do_poll_fni_state(process_instance_id, flow_node_id, expected_state, deadline)
    end
  end

  defp poll_all_waiting_user_tasks(process_instance_id, expected_count, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 5_000)
    deadline = System.monotonic_time(:millisecond) + timeout
    do_poll_all_waiting_user_tasks(process_instance_id, expected_count, deadline)
  end

  defp do_poll_all_waiting_user_tasks(process_instance_id, expected_count, deadline) do
    flow_node_instances = fetch_flow_node_instances(process_instance_id)

    waiting_user_tasks =
      Enum.filter(flow_node_instances, fn flow_node_instance ->
        flow_node_instance.flow_node_type == "user_task" and
          flow_node_instance.state == "waiting"
      end)

    cond do
      length(waiting_user_tasks) >= expected_count ->
        waiting_user_tasks

      System.monotonic_time(:millisecond) >= deadline ->
        raise "Expected #{expected_count} waiting user tasks, " <>
                "got #{length(waiting_user_tasks)} within timeout"

      true ->
        Process.sleep(50)
        do_poll_all_waiting_user_tasks(process_instance_id, expected_count, deadline)
    end
  end

  defp sort_flow_node_instances_by_flow_node_id(flow_node_instances) do
    Enum.sort_by(flow_node_instances, & &1.flow_node_id)
  end
end

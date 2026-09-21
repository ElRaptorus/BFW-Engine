defmodule BfwEngine.Integration.Execution.ParallelGatewayTest do
  @moduledoc """
  Integration tests for parallel gateway resume and retry semantics.

  Covers plan scenarios 10d, 10e (retry), 11a, 11b, 11c (resume).
  Uses real persistence (ExecutionAdapter) and real BPMN fixtures.
  """
  use BfwEngine.ExecutionCase, async: false

  alias BfwEngine.Execution
  alias BfwEngine.Execution.ResumeRunner
  alias BfwEngine.Persistence.Resources.GatewayPendingArrival
  alias BfwEngine.Plugins.Loader
  alias BfwEngine.Test.ExamplePlugin

  require Ash.Query

  # -------------------------------------------------------------------
  # 11a: Resume mid-join (2/3 branches arrived)
  # -------------------------------------------------------------------

  describe "11a: resume mid-join — 2 of 3 branches arrived" do
    test "resumed PI rebuilds join_arrivals and fires join when last user task completes" do
      process_instance_id =
        http_deploy_and_start(
          "parallel_gateway_three_user_tasks.bpmn",
          "ParallelGatewayThreeUserTasks"
        )

      user_task_fnis = poll_all_waiting_user_tasks(process_instance_id, 3)
      [user_task_a, user_task_b, _user_task_c] = sort_fnis_by_flow_node_id(user_task_fnis)

      {204, _} = http_finish_user_task(user_task_a.id, %{"branch" => "a"})
      {204, _} = http_finish_user_task(user_task_b.id, %{"branch" => "b"})
      Process.sleep(300)

      pending_arrivals_before = fetch_pending_arrivals(process_instance_id)
      assert length(pending_arrivals_before) == 2

      terminate_process_instance(process_instance_id)
      await_process_exit(process_instance_id)
      assert_pi_state!(process_instance_id, "running")

      {:ok, resumed_count} = ResumeRunner.resume_all()
      assert resumed_count == 1

      {:ok, _process_instance_pid} = poll_pi_alive(process_instance_id)

      {:ok, resumed_user_task_c} =
        await_waiting_flow_node_instance(process_instance_id, "user_task", timeout: 5_000)

      assert resumed_user_task_c.flow_node_id == "UserTask_C"

      {204, _} = http_finish_user_task(resumed_user_task_c.id, %{"branch" => "c"})

      wait_for_process_instance(process_instance_id, 10_000)
      assert_pi_state!(process_instance_id, "finished")

      assert fetch_pending_arrivals(process_instance_id) == []
    end
  end

  # -------------------------------------------------------------------
  # 11b: Resume with join already fired
  # -------------------------------------------------------------------

  describe "11b: resume with join already fired — PI continues from downstream" do
    test "join already completed; resumed PI finishes from downstream user task" do
      process_instance_id =
        http_deploy_and_start(
          "parallel_gateway_two_user_tasks_then_user_task.bpmn",
          "ParallelGatewayTwoUserTasksThenUserTask"
        )

      branch_user_tasks = poll_all_waiting_user_tasks(process_instance_id, 2)

      Enum.each(branch_user_tasks, fn user_task_fni ->
        {204, _} = http_finish_user_task(user_task_fni.id, %{"done" => true})
      end)

      {:ok, downstream_user_task} =
        await_waiting_flow_node_instance(process_instance_id, "user_task", timeout: 5_000)

      assert downstream_user_task.flow_node_id == "UserTask_After_Join"

      assert fetch_pending_arrivals(process_instance_id) == []

      terminate_process_instance(process_instance_id)
      await_process_exit(process_instance_id)
      assert_pi_state!(process_instance_id, "running")

      {:ok, resumed_count} = ResumeRunner.resume_all()
      assert resumed_count == 1

      {:ok, _process_instance_pid} = poll_pi_alive(process_instance_id)

      {:ok, resumed_downstream_user_task} =
        await_waiting_flow_node_instance(process_instance_id, "user_task", timeout: 5_000)

      assert resumed_downstream_user_task.flow_node_id == "UserTask_After_Join"

      {204, _} = http_finish_user_task(resumed_downstream_user_task.id, %{"final" => true})

      wait_for_process_instance(process_instance_id, 10_000)
      assert_pi_state!(process_instance_id, "finished")
    end
  end

  # -------------------------------------------------------------------
  # 11c: Resume with no branches arrived at join
  # -------------------------------------------------------------------

  describe "11c: resume with no branches arrived — all user tasks still waiting" do
    test "resumed PI rehydrates all user tasks; completing them fires join and finishes PI" do
      process_instance_id =
        http_deploy_and_start(
          "parallel_gateway_three_user_tasks.bpmn",
          "ParallelGatewayThreeUserTasks"
        )

      _user_task_fnis = poll_all_waiting_user_tasks(process_instance_id, 3)

      assert fetch_pending_arrivals(process_instance_id) == []

      join_fni = find_fni_by_flow_node_id(process_instance_id, "Join_1")
      assert join_fni == nil

      terminate_process_instance(process_instance_id)
      await_process_exit(process_instance_id)
      assert_pi_state!(process_instance_id, "running")

      {:ok, resumed_count} = ResumeRunner.resume_all()
      assert resumed_count == 1

      {:ok, _process_instance_pid} = poll_pi_alive(process_instance_id)

      resumed_user_tasks = poll_all_waiting_user_tasks(process_instance_id, 3)

      Enum.each(resumed_user_tasks, fn user_task_fni ->
        {204, _} = http_finish_user_task(user_task_fni.id, %{"done" => true})
      end)

      wait_for_process_instance(process_instance_id, 10_000)
      assert_pi_state!(process_instance_id, "finished")

      assert fetch_pending_arrivals(process_instance_id) == []
    end
  end

  # -------------------------------------------------------------------
  # 10d: Retry at branch task — both branches reset
  # -------------------------------------------------------------------

  describe "10d: full retry resets all fatal FNIs across parallel branches" do
    setup do
      register_test_plugin()
      :ok
    end

    test "both parked async tasks fataled by cascade are reset and can complete after retry" do
      process_instance_id =
        http_deploy_and_start(
          "parallel_gateway_two_async_park.bpmn",
          "ParallelGatewayTwoAsyncPark"
        )

      service_task_a = poll_fni_waiting(process_instance_id, "ServiceTask_A")
      _service_task_b = poll_fni_waiting(process_instance_id, "ServiceTask_B")

      Execution.fail_async_service_task(
        service_task_a.id,
        "TEST_FATAL",
        "deliberate test failure"
      )

      wait_for_process_instance(process_instance_id, 10_000)
      assert_pi_state!(process_instance_id, "fatal")

      flow_node_instances_before = fetch_flow_node_instances(process_instance_id)

      fatal_fnis =
        Enum.filter(flow_node_instances_before, &(&1.state == "fatal"))

      assert length(fatal_fnis) >= 2,
             "Expected at least 2 fatal FNIs (cascade), got #{length(fatal_fnis)}"

      fatal_flow_node_ids = Enum.map(fatal_fnis, & &1.flow_node_id) |> Enum.sort()
      assert "ServiceTask_A" in fatal_flow_node_ids
      assert "ServiceTask_B" in fatal_flow_node_ids

      {204, nil} = http_retry_process_instance(process_instance_id)

      assert {:ok, _pid} = poll_pi_alive(process_instance_id, 10_000)

      retried_service_task_a = poll_fni_waiting(process_instance_id, "ServiceTask_A")
      retried_service_task_b = poll_fni_waiting(process_instance_id, "ServiceTask_B")

      Execution.finish_async_service_task(
        retried_service_task_a.id,
        %{"branch" => "a"}
      )

      Execution.finish_async_service_task(
        retried_service_task_b.id,
        %{"branch" => "b"}
      )

      wait_for_process_instance(process_instance_id, 10_000)
      assert_pi_state!(process_instance_id, "finished")
    end
  end

  # -------------------------------------------------------------------
  # 10e: Retry at branch task — checkpoint preserves completed branch
  # -------------------------------------------------------------------

  describe "10e: checkpoint retry at fatal branch preserves completed branch state" do
    setup do
      register_test_plugin()
      :ok
    end

    test "checkpoint retry resets only the fatal branch; completed branch stays finished" do
      process_instance_id =
        http_deploy_and_start(
          "parallel_gateway_echo_and_park.bpmn",
          "ParallelGatewayEchoAndPark"
        )

      service_task_park = poll_fni_waiting(process_instance_id, "ServiceTask_Park")

      Process.sleep(300)

      echo_fni = poll_fni_finished(process_instance_id, "ServiceTask_Echo")
      assert echo_fni.state == "finished"

      pending_arrivals_before_fatal = fetch_pending_arrivals(process_instance_id)
      assert length(pending_arrivals_before_fatal) >= 1

      Execution.fail_async_service_task(
        service_task_park.id,
        "TEST_FATAL",
        "deliberate test failure"
      )

      wait_for_process_instance(process_instance_id, 10_000)
      assert_pi_state!(process_instance_id, "fatal")

      fatal_park_fni = find_fni_by_flow_node_id(process_instance_id, "ServiceTask_Park")
      assert fatal_park_fni.state == "fatal"

      echo_fni_after_fatal = find_fni_by_flow_node_id(process_instance_id, "ServiceTask_Echo")
      assert echo_fni_after_fatal.state == "finished"

      {204, nil} =
        http_retry_process_instance(
          process_instance_id,
          %{"resetToFlowNodeInstanceId" => fatal_park_fni.id}
        )

      assert {:ok, _pid} = poll_pi_alive(process_instance_id, 10_000)

      retried_park_fni = poll_fni_waiting(process_instance_id, "ServiceTask_Park")

      echo_fni_after_retry = find_fni_by_flow_node_id(process_instance_id, "ServiceTask_Echo")
      assert echo_fni_after_retry.state == "finished"

      Execution.finish_async_service_task(
        retried_park_fni.id,
        %{"branch" => "park"}
      )

      wait_for_process_instance(process_instance_id, 10_000)
      assert_pi_state!(process_instance_id, "finished")
    end
  end

  # -------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------

  defp register_test_plugin do
    Application.put_env(:core_execution, :service_task_dispatch, BfwEngine.Plugins.RegistryDispatch)
    facade = Loader.facade_for_plugin("evil:test_parallel_gateway")
    ExamplePlugin.on_load(facade)
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

  defp fetch_pending_arrivals(process_instance_id) do
    GatewayPendingArrival
    |> Ash.Query.filter(process_instance_id == ^process_instance_id)
    |> Ash.read!(authorize?: false)
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

    if length(waiting_user_tasks) >= expected_count do
      waiting_user_tasks
    else
      if System.monotonic_time(:millisecond) >= deadline do
        raise "Expected #{expected_count} waiting user tasks, " <>
                "got #{length(waiting_user_tasks)} within timeout"
      else
        Process.sleep(50)
        do_poll_all_waiting_user_tasks(process_instance_id, expected_count, deadline)
      end
    end
  end

  defp poll_fni_waiting(process_instance_id, flow_node_id, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_poll_fni_state(process_instance_id, flow_node_id, "waiting", deadline)
  end

  defp poll_fni_finished(process_instance_id, flow_node_id, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_poll_fni_state(process_instance_id, flow_node_id, "finished", deadline)
  end

  defp do_poll_fni_state(process_instance_id, flow_node_id, expected_state, deadline) do
    fni = find_fni_by_flow_node_id(process_instance_id, flow_node_id)

    if fni != nil and fni.state == expected_state do
      fni
    else
      if System.monotonic_time(:millisecond) >= deadline do
        actual = if fni, do: fni.state, else: "not found"

        raise "Expected FNI #{flow_node_id} in state #{expected_state}, " <>
                "got #{actual} within timeout"
      else
        Process.sleep(50)
        do_poll_fni_state(process_instance_id, flow_node_id, expected_state, deadline)
      end
    end
  end

  defp sort_fnis_by_flow_node_id(flow_node_instances) do
    Enum.sort_by(flow_node_instances, & &1.flow_node_id)
  end
end

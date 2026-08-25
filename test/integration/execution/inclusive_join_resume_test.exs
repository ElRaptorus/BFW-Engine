defmodule EvilEngine.Integration.Execution.InclusiveJoinResumeTest do
  @moduledoc """
  Resume of an Inclusive Join that is already fireable (live branch arrived,
  dead path never taken) must complete after engine restart.
  """
  use EvilEngine.ExecutionCase, async: false

  alias EvilEngine.Execution
  alias EvilEngine.Execution.ResumeRunner

  @tag :integration
  test "resume fires an inclusive join whose remaining incoming is a dead path" do
    process_instance_id =
      http_deploy_and_start(
        "inclusive_gateway_exclusive_to_inclusive_join.bpmn",
        "InclusiveGatewayExclusiveToInclusiveJoin",
        %{"payload" => %{"path" => "a"}}
      )

    Process.sleep(200)
    terminate_process_instance(process_instance_id)
    await_process_exit(process_instance_id)

    case persisted_pi_state(process_instance_id) do
      "finished" ->
        :ok

      "running" ->
        {:ok, resumed_count} = ResumeRunner.resume_all()
        assert resumed_count >= 1
        wait_for_process_instance(process_instance_id, 10_000)
        assert_pi_state!(process_instance_id, "finished")

      other_state ->
        flunk("unexpected process instance state after kill: #{inspect(other_state)}")
    end

    assert poll_fni_finished(process_instance_id, "InclusiveJoin")
    assert poll_fni_finished(process_instance_id, "Task_A")
    refute find_fni_by_flow_node_id(process_instance_id, "Task_B")
  end

  defp persisted_pi_state(process_instance_id) do
    case fetch_process_instance(process_instance_id) do
      %{state: state} -> to_string(state)
      _other -> nil
    end
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
          2_000 ->
            :ok
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
end

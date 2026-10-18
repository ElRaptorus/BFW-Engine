defmodule BfwEngine.Integration.Execution.MultiInstanceKillPathsTest do
  @moduledoc """
  Ending an instance while a parallel Multi-Instance has live iterations
  leaves no live row (R5.1), and an iteration whose park result arrives after
  its shell interrupted it is interrupted, not parked (R5.2).
  """
  use BfwEngine.ExecutionCase, async: false

  alias BfwEngine.Execution
  alias BfwEngine.Execution.FlowNodeResult
  alias BfwEngine.Plugins.FacadeBuilder
  alias BfwEngine.Test.ExamplePlugin

  @iteration_count 3

  setup do
    Application.put_env(
      :core_execution,
      :service_task_dispatch,
      BfwEngine.Plugins.RegistryDispatch
    )

    ExamplePlugin.on_load(FacadeBuilder.build("evil:test_multi_instance_kill_paths"))
    :ok
  end

  describe "parallel Multi-Instance with live iterations" do
    test "a Terminate End Event ends every iteration" do
      process_instance_id = start_with_waiting_iterations()

      gate = poll_fni_state(process_instance_id, "intermediate_catch_event", "waiting")
      assert {200, %{"triggered" => true}} = http_trigger_timer_event(gate.id)

      assert {:ok, _process_instance} =
               await_process_instance_state(process_instance_id, "finished")

      assert_no_live_rows(process_instance_id)
    end

    test "an abort ends every iteration" do
      process_instance_id = start_with_waiting_iterations()

      {204, _body} =
        http_abort_process_instance(process_instance_id, "test_abort", %{
          "abort_process_instance" => "all"
        })

      assert {:ok, _process_instance} =
               await_process_instance_state(process_instance_id, "aborted")

      assert_no_live_rows(process_instance_id)
    end
  end

  describe "an iteration that parks after its shell interrupted it" do
    test "is interrupted instead of parked" do
      process_instance_id =
        http_deploy_and_start(
          "mi_parallel_user_task_early_break.bpmn",
          "mi-parallel-user-task-early-break",
          %{
            "payload" => %{"items" => [1, 2]}
          }
        )

      [first_iteration, second_iteration] = await_iterations(process_instance_id, 2)
      {:ok, process_instance_pid} = Execution.lookup_process_instance(process_instance_id)

      # The second iteration's Task has returned its park result, which is
      # still queued: the entry is :active with a dead pid.
      dead_pid = spawn(fn -> :ok end)

      :sys.replace_state(process_instance_pid, fn {state_name, data} ->
        entry = Map.fetch!(data.flow_node_instance_states, second_iteration.id)
        active_entry = %{entry | state: :active, pid: dead_pid}
        {state_name, put_in(data.flow_node_instance_states[second_iteration.id], active_entry)}
      end)

      {204, _body} = http_finish_user_task(first_iteration.id)
      await_interrupt_requested(process_instance_pid, second_iteration.id)
      send(process_instance_pid, {:fni_result, second_iteration.id, {:wait, %FlowNodeResult{}}})

      assert {:ok, _process_instance} =
               await_process_instance_state(process_instance_id, "finished")

      assert Enum.find(
               fetch_flow_node_instances(process_instance_id),
               &(&1.id == second_iteration.id)
             ).state ==
               "interrupted"

      assert_no_live_rows(process_instance_id)
    end
  end

  defp start_with_waiting_iterations do
    process_instance_id =
      http_deploy_and_start("mi_parallel_terminate.bpmn", "MiParallelTerminate", %{
        "payload" => %{"items" => Enum.to_list(1..@iteration_count)}
      })

    _iterations = await_iterations(process_instance_id, @iteration_count)
    process_instance_id
  end

  defp await_iterations(process_instance_id, expected_count) do
    poll(fn ->
      waiting_iterations =
        process_instance_id
        |> fetch_flow_node_instances()
        |> Enum.filter(&(&1.multi_instance_id != nil and &1.state == "waiting"))
        |> Enum.sort_by(& &1.iteration_index)

      if length(waiting_iterations) == expected_count, do: waiting_iterations
    end)
  end

  defp await_interrupt_requested(process_instance_pid, iteration_fni_id) do
    poll(fn ->
      {_state_name, data} = :sys.get_state(process_instance_pid)
      Map.get(data.flow_node_instance_states[iteration_fni_id], :interrupt_requested)
    end)
  end

  defp poll(probe, deadline \\ System.monotonic_time(:millisecond) + 5_000) do
    case probe.() do
      result when result not in [nil, false] ->
        result

      _not_yet ->
        if System.monotonic_time(:millisecond) >= deadline,
          do: flunk("condition not met before the timeout")

        Process.sleep(25)
        poll(probe, deadline)
    end
  end

  defp assert_no_live_rows(process_instance_id) do
    live_rows =
      process_instance_id
      |> fetch_flow_node_instances()
      |> Enum.filter(&(&1.state in ["active", "waiting"]))
      |> Enum.map(&{&1.flow_node_id, &1.state})

    assert live_rows == []
  end
end

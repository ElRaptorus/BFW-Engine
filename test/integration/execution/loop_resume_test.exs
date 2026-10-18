defmodule BfwEngine.Integration.Execution.LoopResumeTest do
  @moduledoc """
  Resume of Multi-Instance shells and iterations (bug hunt Batch 2.5 and
  2.8): the `loop.*` overlay of a resumed iteration, iterations whose rows
  were never created, and a shell resumed without any iteration row.
  """
  use BfwEngine.ExecutionCase, async: false

  alias BfwEngine.Execution.ResumeRunner
  alias BfwEngine.Persistence.Repo

  @items ["first", "second"]

  describe "F10: loop overlay of a resumed iteration" do
    test "an output mapping on loop.item still sees the iteration's item" do
      process_instance_id = start_review()
      iterations = await_waiting_iterations(process_instance_id, [0, 1])

      stop_all_process_instances()
      {:ok, 1} = ResumeRunner.resume_all()
      {:ok, _process_instance_pid} = poll_pi_alive(process_instance_id)

      finish_iterations(process_instance_id, iterations)
      assert reviewed_items(process_instance_id) == @items
    end
  end

  describe "F12: parallel iteration whose row was never created" do
    test "the resumed shell dispatches the missing iteration" do
      process_instance_id = start_review()
      [_first, second] = await_waiting_iterations(process_instance_id, [0, 1])

      stop_all_process_instances()
      delete_flow_node_instance(second.id)
      {:ok, 1} = ResumeRunner.resume_all()

      iterations = await_waiting_iterations(process_instance_id, [0, 1])
      refute Enum.any?(iterations, &(&1.id == second.id))

      finish_iterations(process_instance_id, iterations)
      assert reviewed_items(process_instance_id) == @items
    end
  end

  describe "F13: waiting shell without iteration rows" do
    test "the resumed shell dispatches every iteration again" do
      process_instance_id = start_review()
      old_iterations = await_waiting_iterations(process_instance_id, [0, 1])

      stop_all_process_instances()
      Enum.each(old_iterations, &delete_flow_node_instance(&1.id))
      {:ok, 1} = ResumeRunner.resume_all()

      iterations = await_waiting_iterations(process_instance_id, [0, 1])

      assert MapSet.disjoint?(
               MapSet.new(iterations, & &1.id),
               MapSet.new(old_iterations, & &1.id)
             )

      finish_iterations(process_instance_id, iterations)
      assert reviewed_items(process_instance_id) == @items
    end
  end

  describe "parallel shell whose completionCondition is met by finished iterations" do
    test "the resumed shell finishes with an early break and interrupts the live iterations" do
      process_instance_id =
        http_deploy_and_start(
          "mi_parallel_user_task_early_break.bpmn",
          "mi-parallel-user-task-early-break",
          %{"payload" => %{"items" => [1, 2, 3]}}
        )

      [first | live_iterations] =
        await_waiting_iterations(process_instance_id, [0, 1, 2], "Task_1")

      stop_all_process_instances()

      Repo.query!(
        "UPDATE flow_node_instances SET state = 'finished', finished_at = now(), output_token = $2 WHERE id = $1",
        [Ecto.UUID.dump!(first.id), %{"approved" => true}]
      )

      {:ok, 1} = ResumeRunner.resume_all()

      assert {:ok, _process_instance} =
               await_process_instance_state(process_instance_id, "finished")

      rows = fetch_flow_node_instances(process_instance_id)

      for iteration <- live_iterations do
        assert Enum.find(rows, &(&1.id == iteration.id)).state == "interrupted"
      end

      shell = Enum.find(rows, &(&1.flow_node_id == "Task_1" and &1.multi_instance_id == nil))
      assert shell.state == "finished"
      assert shell.output_token["reviewResults"] == [%{"approved" => true}]
    end
  end

  describe "bfw:loopInterval across a resume" do
    test "a sequential Multi-Instance waits a full interval after the resume" do
      process_instance_id =
        http_deploy_and_start("mi_sequential_with_interval.bpmn", "mi-sequential-with-interval", %{
          "payload" => %{"items" => ["a", "b"]}
        })

      assert_next_iteration_waits_after_resume(process_instance_id)
    end

    test "a Standard Loop waits a full interval after the resume" do
      process_instance_id = http_deploy_and_start("loop_with_interval.bpmn", "loop-with-interval")
      assert_next_iteration_waits_after_resume(process_instance_id)
    end
  end

  defp assert_next_iteration_waits_after_resume(process_instance_id) do
    await_finished_iteration(process_instance_id, 0)
    stop_all_process_instances()
    refute iteration_row(process_instance_id, 1)

    resumed_at = DateTime.utc_now()
    {:ok, 1} = ResumeRunner.resume_all()
    second_iteration = await_finished_iteration(process_instance_id, 1)

    assert DateTime.diff(second_iteration.started_at, resumed_at, :millisecond) >= 950
  end

  defp await_finished_iteration(process_instance_id, iteration_index, attempts_left \\ 200) do
    case iteration_row(process_instance_id, iteration_index) do
      %{state: "finished"} = iteration ->
        iteration

      _not_yet when attempts_left > 0 ->
        Process.sleep(20)
        await_finished_iteration(process_instance_id, iteration_index, attempts_left - 1)

      _not_yet ->
        flunk("iteration #{iteration_index} did not finish")
    end
  end

  defp iteration_row(process_instance_id, iteration_index) do
    process_instance_id
    |> fetch_flow_node_instances()
    |> Enum.find(&(&1.multi_instance_id != nil and &1.iteration_index == iteration_index))
  end

  defp start_review do
    http_deploy_and_start(
      "mi_parallel_user_task_loop_mapping.bpmn",
      "mi-parallel-user-task-loop-mapping",
      %{"payload" => %{"items" => @items}}
    )
  end

  defp finish_iterations(process_instance_id, iterations) do
    for iteration <- iterations do
      {204, _} = http_finish_user_task(iteration.id, %{})
    end

    assert {:ok, _process_instance} =
             await_process_instance_state(process_instance_id, "finished")
  end

  defp reviewed_items(process_instance_id) do
    end_event = find_fni_by_flow_node_id(process_instance_id, "End_1")
    end_event.input_token["reviews"] |> Enum.map(& &1["reviewed"]) |> Enum.sort()
  end

  defp await_waiting_iterations(
         process_instance_id,
         indices,
         flow_node_id \\ "Task_Review",
         attempts_left \\ 100
       ) do
    waiting =
      process_instance_id
      |> fetch_flow_node_instances()
      |> Enum.filter(
        &(&1.flow_node_id == flow_node_id and &1.state == "waiting" and
            &1.iteration_index in indices)
      )
      |> Enum.sort_by(& &1.iteration_index)

    cond do
      length(waiting) == length(indices) ->
        waiting

      attempts_left > 0 ->
        Process.sleep(50)
        await_waiting_iterations(process_instance_id, indices, flow_node_id, attempts_left - 1)

      true ->
        flunk("expected waiting iterations #{inspect(indices)}, got #{length(waiting)}")
    end
  end

  defp delete_flow_node_instance(flow_node_instance_id) do
    Repo.query!("DELETE FROM flow_node_instances WHERE id = $1", [
      Ecto.UUID.dump!(flow_node_instance_id)
    ])
  end

  defp stop_all_process_instances do
    BfwEngine.Execution.Supervisor
    |> DynamicSupervisor.which_children()
    |> Enum.each(fn {_id, pid, _type, _modules} ->
      monitor_reference = Process.monitor(pid)
      DynamicSupervisor.terminate_child(BfwEngine.Execution.Supervisor, pid)
      assert_receive {:DOWN, ^monitor_reference, :process, ^pid, _reason}, 5_000
    end)
  end
end

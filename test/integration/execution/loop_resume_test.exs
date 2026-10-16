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

  defp await_waiting_iterations(process_instance_id, indices, attempts_left \\ 100) do
    waiting =
      process_instance_id
      |> fetch_flow_node_instances()
      |> Enum.filter(
        &(&1.flow_node_id == "Task_Review" and &1.state == "waiting" and
            &1.iteration_index in indices)
      )
      |> Enum.sort_by(& &1.iteration_index)

    cond do
      length(waiting) == length(indices) ->
        waiting

      attempts_left > 0 ->
        Process.sleep(50)
        await_waiting_iterations(process_instance_id, indices, attempts_left - 1)

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

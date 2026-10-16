defmodule BfwEngine.Integration.Execution.LoopLifecycleTest do
  @moduledoc """
  Multi-Instance and Standard Loop lifecycle (bug hunt Batch 2.5 – 2.8):
  iteration cleanup on interrupt and abort, Data Object writes from
  iterations, Standard Loop token chaining, output collection keys, and
  FEEL errors in loop conditions.
  """
  use BfwEngine.ExecutionCase, async: false

  describe "F3: interrupted and aborted Call Activity iterations" do
    test "aborting the parent aborts the child of every live iteration" do
      {parent_process_instance_id, child_process_instance_ids} = start_first_wins_parent()

      {204, _} =
        http_abort_process_instance(parent_process_instance_id, "stop", %{
          "abort_process_instance" => "all"
        })

      for child_process_instance_id <- child_process_instance_ids do
        assert {:ok, _child} = await_process_instance_state(child_process_instance_id, "aborted")
      end
    end

    test "a met completion condition aborts the child of the interrupted iteration" do
      {parent_process_instance_id, [first_child_id, second_child_id]} =
        start_first_wins_parent()

      {:ok, first_work} = await_waiting_fni_by_node_id(first_child_id, "Child_Work")
      {204, _} = http_finish_user_task(first_work.id, %{})

      assert {:ok, _parent} = await_process_instance_state(parent_process_instance_id, "finished")
      assert {:ok, _first_child} = await_process_instance_state(first_child_id, "finished")
      assert {:ok, _second_child} = await_process_instance_state(second_child_id, "aborted")
    end
  end

  describe "F17: interrupting many live iterations" do
    test "thirty Call Activity iterations are interrupted together, not one after another" do
      items = Enum.map(1..30, &"item-#{&1}")

      {parent_process_instance_id, [first_child_id | other_child_ids]} =
        start_first_wins_parent(items)

      {:ok, first_work} = await_waiting_fni_by_node_id(first_child_id, "Child_Work")
      {204, _} = http_finish_user_task(first_work.id, %{})

      assert {:ok, _parent} = await_process_instance_state(parent_process_instance_id, "finished")

      for child_process_instance_id <- other_child_ids do
        assert {:ok, _child} = await_process_instance_state(child_process_instance_id, "aborted")
      end
    end
  end

  describe "iteration dispatch after the shell ended" do
    test "a dispatch request for an interrupted shell is refused and creates no iteration" do
      process_instance_id =
        http_deploy_and_start("mi_parallel_interrupted_shell.bpmn", "MiParallelInterruptedShell", %{
          "payload" => %{"items" => ["a", "b"]}
        })

      {:ok, boundary} = await_waiting_fni_by_node_id(process_instance_id, "BE_Timeout")
      {200, _} = http_trigger_timer_event(boundary.id)
      {:ok, _after} = await_waiting_fni_by_node_id(process_instance_id, "UT_After")

      shell =
        process_instance_id
        |> fetch_flow_node_instances()
        |> Enum.find(&(&1.flow_node_id == "Task_Review" and is_nil(&1.multi_instance_id)))

      assert shell.state == "interrupted"
      iteration_count = count_flow_node_instances(process_instance_id, "Task_Review")
      {:ok, process_instance_pid} = poll_pi_alive(process_instance_id)

      token = %BfwEngine.Types.Token{
        id: Ash.UUIDv7.generate(),
        process_instance_id: process_instance_id,
        payload: %{"item" => "late"},
        created_at: DateTime.utc_now()
      }

      assert {:error, :shell_not_active} ==
               :gen_statem.call(
                 process_instance_pid,
                 {:mi_dispatch_iteration, shell.id, 2, "late", token, %{},
                  %BfwEngine.BPMN.Model.FlowNode{
                    id: "Task_Review",
                    type: :user_task,
                    type_data: %BfwEngine.BPMN.Model.FlowNodeData.UserTask{}
                  }}
               )

      assert count_flow_node_instances(process_instance_id, "Task_Review") == iteration_count
    end
  end

  describe "F9: Data Object writes from Multi-Instance iterations" do
    test "the next sequential iteration reads the value the previous one wrote" do
      {201, _} = http_deploy("mi_sequential_data_object_write.bpmn")

      {201, start_body} =
        http_start("mi-sequential-data-object-write", %{"payload" => %{"items" => [1, 2, 3]}})

      process_instance_id = start_body["processInstanceId"]

      assert {:ok, _process_instance} =
               await_process_instance_state(process_instance_id, "finished")

      end_event = find_fni_by_flow_node_id(process_instance_id, "End_1")
      assert Enum.map(end_event.input_token["results"], & &1["seen"]) == [nil, 1, 2]
    end
  end

  describe "F4: Standard Loop token chaining" do
    test "each iteration receives the previous output and the condition sees the latest token" do
      process_instance_id =
        http_deploy_and_start("loop_token_chaining.bpmn", "loop-token-chaining", %{
          "payload" => %{"counter" => 0, "label" => "kept"}
        })

      assert {:ok, _process_instance} =
               await_process_instance_state(process_instance_id, "finished")

      iterations =
        for flow_node_instance <- fetch_flow_node_instances(process_instance_id),
            flow_node_instance.flow_node_id == "Count_1",
            flow_node_instance.iteration_index != nil,
            do: flow_node_instance

      assert Enum.map(iterations, & &1.input_token["counter"]) |> Enum.sort() == [0, 1, 2]

      end_event = find_fni_by_flow_node_id(process_instance_id, "End_1")
      assert end_event.input_token["counter"] == 3
      assert end_event.input_token["label"] == "kept"
      refute Map.has_key?(end_event.input_token, "results")
    end
  end

  describe "F5 / F7: output collection and output element variable" do
    test "outputCollection is a key and outputElementVariable picks each iteration's value" do
      process_instance_id =
        http_deploy_and_start(
          "mi_sequential_output_element_variable.bpmn",
          "mi-sequential-output-element-variable",
          %{"payload" => %{"items" => [1, 2], "scores" => [99]}}
        )

      assert {:ok, _process_instance} =
               await_process_instance_state(process_instance_id, "finished")

      end_event = find_fni_by_flow_node_id(process_instance_id, "End_1")
      assert end_event.input_token["scores"] == [2, 4]
      assert Enum.map(end_event.input_token["items"], & &1["label"]) == ["item 1", "item 2"]
    end
  end

  describe "F16: FEEL errors in loop conditions" do
    test "a broken loopBreakCondition fatals the Multi-Instance shell" do
      process_instance_id =
        http_deploy_and_start(
          "mi_sequential_break_condition_error.bpmn",
          "mi-sequential-break-condition-error",
          %{"payload" => %{"items" => [1, 2]}}
        )

      assert {:ok, _process_instance} = await_process_instance_state(process_instance_id, "fatal")
      assert_loop_condition_failed(process_instance_id, "Task_1", "loopBreakCondition")
    end

    test "a broken loopCondition fatals the Standard Loop shell" do
      process_instance_id =
        http_deploy_and_start("loop_token_chaining.bpmn", "loop-condition-error", %{
          "payload" => %{"counter" => 0}
        })

      assert {:ok, _process_instance} = await_process_instance_state(process_instance_id, "fatal")
      assert_loop_condition_failed(process_instance_id, "Broken_Count", "loopCondition")
    end
  end

  defp count_flow_node_instances(process_instance_id, flow_node_id) do
    process_instance_id
    |> fetch_flow_node_instances()
    |> Enum.count(&(&1.flow_node_id == flow_node_id))
  end

  defp start_first_wins_parent(items \\ ["a", "b"]) do
    {201, _} = http_deploy("call_activity_multi_instance_first_wins.bpmn")

    {201, start_body} =
      http_start("CallActivityMiFirstWins", %{"payload" => %{"items" => items}})

    parent_process_instance_id = start_body["processInstanceId"]
    child_process_instance_ids = await_children(parent_process_instance_id, length(items))

    for child_process_instance_id <- child_process_instance_ids do
      {:ok, _work} = await_waiting_fni_by_node_id(child_process_instance_id, "Child_Work")
    end

    {parent_process_instance_id, child_process_instance_ids}
  end

  defp await_children(parent_process_instance_id, count, attempts_left \\ 200) do
    child_process_instance_ids = list_child_process_instance_ids(parent_process_instance_id)

    cond do
      length(child_process_instance_ids) == count ->
        child_process_instance_ids

      attempts_left > 0 ->
        Process.sleep(50)
        await_children(parent_process_instance_id, count, attempts_left - 1)

      true ->
        flunk(
          "expected #{count} child process instances, got #{length(child_process_instance_ids)}"
        )
    end
  end

  defp assert_loop_condition_failed(process_instance_id, flow_node_id, condition) do
    shell =
      process_instance_id
      |> fetch_flow_node_instances()
      |> Enum.find(&(&1.flow_node_id == flow_node_id and is_nil(&1.iteration_index)))

    assert shell.state == "fatal"
    assert shell.error_info["error_code"] == "loop_condition_failed"
    assert shell.error_info["message"] =~ "Loop activity '#{flow_node_id}'"
    assert shell.error_info["message"] =~ condition
  end
end

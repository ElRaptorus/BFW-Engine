defmodule BfwEngine.Integration.Execution.MultiInstanceShellFinishTest do
  @moduledoc "Regression: finishing a Multi-Instance user-task shell through the inbox API is rejected (F15)."
  use BfwEngine.ExecutionCase, async: false

  alias BfwEngine.Execution

  @shell_poll_timeout_ms 5_000
  @shell_poll_interval_ms 25

  describe "F15: finish on a Multi-Instance user-task shell" do
    test "answers 422 fni_is_multi_instance_shell and the process instance stays alive" do
      {201, _} = http_deploy("mi_parallel_user_task.bpmn")

      {201, start_body} =
        http_start("mi-parallel-user-task", %{
          "payload" => %{"items" => [%{"name" => "A"}, %{"name" => "B"}]}
        })

      process_instance_id = start_body["processInstanceId"]
      shell = await_waiting_shell(process_instance_id, "Task_1")
      {:ok, process_instance_pid} = Execution.lookup_process_instance(process_instance_id)

      {status, response_body} = http_finish_user_task(shell.id, %{"approved" => true})

      assert status == 422
      assert response_body["error"] == "fni_is_multi_instance_shell"
      assert Process.alive?(process_instance_pid)

      :ok = finish_waiting_user_task(process_instance_id, result: %{"approved" => true})
      :ok = finish_waiting_user_task(process_instance_id, result: %{"approved" => true})

      assert {:ok, _process_instance} =
               await_process_instance_state(process_instance_id, "finished")
    end
  end

  defp await_waiting_shell(process_instance_id, flow_node_id) do
    deadline = System.monotonic_time(:millisecond) + @shell_poll_timeout_ms
    poll_waiting_shell(process_instance_id, flow_node_id, deadline)
  end

  defp poll_waiting_shell(process_instance_id, flow_node_id, deadline) do
    shell =
      process_instance_id
      |> fetch_flow_node_instances()
      |> Enum.find(&waiting_shell?(&1, flow_node_id))

    cond do
      shell != nil ->
        shell

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("Multi-Instance shell #{flow_node_id} never reached waiting")

      true ->
        Process.sleep(@shell_poll_interval_ms)
        poll_waiting_shell(process_instance_id, flow_node_id, deadline)
    end
  end

  defp waiting_shell?(flow_node_instance, flow_node_id) do
    flow_node_instance.flow_node_id == flow_node_id and
      is_nil(flow_node_instance.iteration_index) and
      flow_node_instance.state == "waiting"
  end
end

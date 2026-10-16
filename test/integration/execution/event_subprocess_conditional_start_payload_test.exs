defmodule BfwEngine.Integration.Execution.EventSubprocessConditionalStartPayloadTest do
  @moduledoc """
  A conditional Event Subprocess start evaluates its condition with `token`
  bound to the scope instance's start payload, also after a resume
  (decision D-10.3).
  """
  use BfwEngine.ExecutionCase, async: false

  alias BfwEngine.Execution
  alias BfwEngine.Execution.ResumeRunner

  @fixture "event_subprocess_conditional_start_payload.bpmn"
  @process_model_id "EspConditionalStartPayload"

  test "token in the condition is the start payload, not the start context" do
    process_instance_id =
      http_deploy_and_start(@fixture, @process_model_id, %{
        "payload" => %{"expected" => "go"},
        "context" => %{"expected" => "context-value"}
      })

    {:ok, writer} = await_waiting_fni_by_node_id(process_instance_id, "UserTask_WriteTrigger")
    {204, _} = http_finish_user_task(writer.id, %{"status" => "go"})

    assert_condition_start_fires(process_instance_id)
  end

  test "the condition still reads the start payload after a resume" do
    process_instance_id =
      http_deploy_and_start(@fixture, @process_model_id, %{
        "payload" => %{"expected" => "go"},
        "context" => %{"expected" => "context-value"}
      })

    {:ok, writer} = await_waiting_fni_by_node_id(process_instance_id, "UserTask_WriteTrigger")
    stop_process_instance(process_instance_id)

    {:ok, 1} = ResumeRunner.resume_all()
    {:ok, _pid} = poll_pi_alive(process_instance_id)
    {204, _} = http_finish_user_task(writer.id, %{"status" => "go"})

    assert_condition_start_fires(process_instance_id)
  end

  defp assert_condition_start_fires(process_instance_id) do
    assert {:ok, %{state: "finished"}} =
             await_finished_fni_by_node_id(process_instance_id, "ESP_Conditional")

    {:ok, main_task} = await_waiting_fni_by_node_id(process_instance_id, "Main_UserTask")
    {204, _} = http_finish_user_task(main_task.id, %{})

    assert {:ok, _process_instance} = await_process_instance_state(process_instance_id, "finished")
  end

  defp stop_process_instance(process_instance_id) do
    {:ok, process_instance_pid} = Execution.lookup_process_instance(process_instance_id)
    monitor_reference = Process.monitor(process_instance_pid)
    DynamicSupervisor.terminate_child(BfwEngine.Execution.Supervisor, process_instance_pid)
    assert_receive {:DOWN, ^monitor_reference, :process, ^process_instance_pid, _reason}, 2_000
  end
end

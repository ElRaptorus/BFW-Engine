defmodule BfwEngine.Integration.Execution.EventSubprocessMessageCorrelationTest do
  @moduledoc """
  A message Event Subprocess start evaluates `bfw:correlationKey` with `token`
  bound to its scope instance's start payload: the start request payload for a
  root instance, the mapped input for a subprocess child, and the same value
  after a resume (C5, decision D-9).
  """
  use BfwEngine.ExecutionCase, async: false

  alias BfwEngine.Execution
  alias BfwEngine.Execution.ResumeRunner

  @root_fixture "event_subprocess_message_start_payload_correlation.bpmn"
  @root_process_model_id "EspStartPayloadCorrelation"
  @root_message_name "esp-start-payload-correlation"

  describe "root instance" do
    test "token is the start payload, not the start context" do
      process_instance_id =
        http_deploy_and_start(@root_fixture, @root_process_model_id, %{
          "payload" => %{"orderId" => "A-1"},
          "context" => %{"orderId" => "context-value"}
        })

      _ = poll_fni_state(process_instance_id, "user_task", "waiting")

      assert {200, %{"deliveries" => []}} =
               http_trigger_message(@root_message_name, %{}, "context-value")

      assert {200, %{"deliveries" => [%{"processInstanceId" => ^process_instance_id}]}} =
               http_trigger_message(@root_message_name, %{}, "A-1")

      assert {:ok, %{state: "finished"}} =
               await_finished_fni_by_node_id(process_instance_id, "ESP_Message")
    end

    test "the correlation value is the same after a resume" do
      process_instance_id =
        http_deploy_and_start(@root_fixture, @root_process_model_id, %{
          "payload" => %{"orderId" => "R-9"}
        })

      _ = poll_fni_state(process_instance_id, "user_task", "waiting")
      stop_process_instance(process_instance_id)

      {:ok, 1} = ResumeRunner.resume_all()
      {:ok, _pid} = poll_pi_alive(process_instance_id)

      assert {200, %{"deliveries" => []}} = http_trigger_message(@root_message_name, %{}, "other")

      assert {200, %{"deliveries" => [%{"processInstanceId" => ^process_instance_id}]}} =
               http_trigger_message(@root_message_name, %{}, "R-9")

      assert {:ok, _process_instance} =
               await_process_instance_state(process_instance_id, "finished")
    end
  end

  describe "embedded subprocess child" do
    test "token is the input passed to the child after inputMapping" do
      process_instance_id =
        http_deploy_and_start(
          "event_subprocess_message_subprocess_correlation.bpmn",
          "EspSubprocessCorrelation",
          %{"payload" => %{"order" => %{"id" => "B-7"}}}
        )

      subprocess_shell = poll_fni_state(process_instance_id, "sub_process", "waiting")
      child_process_instance_id = subprocess_shell.type_properties["child_process_instance_id"]
      _ = poll_fni_state(child_process_instance_id, "user_task", "waiting")

      assert {200, %{"deliveries" => []}} =
               http_trigger_message("esp-subprocess-correlation", %{}, "wrong")

      assert {200, %{"deliveries" => [%{"processInstanceId" => ^child_process_instance_id}]}} =
               http_trigger_message("esp-subprocess-correlation", %{}, "B-7")

      assert {:ok, _process_instance} =
               await_process_instance_state(process_instance_id, "finished")
    end
  end

  defp stop_process_instance(process_instance_id) do
    {:ok, process_instance_pid} = Execution.lookup_process_instance(process_instance_id)
    monitor_reference = Process.monitor(process_instance_pid)
    DynamicSupervisor.terminate_child(BfwEngine.Execution.Supervisor, process_instance_pid)
    assert_receive {:DOWN, ^monitor_reference, :process, ^process_instance_pid, _reason}, 2_000
  end
end

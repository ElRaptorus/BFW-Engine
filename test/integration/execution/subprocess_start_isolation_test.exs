defmodule BfwEngine.Integration.Execution.SubprocessStartIsolationTest do
  @moduledoc """
  Integration tests for subprocess start-event isolation.

  A Start Event nested inside an embedded subprocess must never be startable
  directly through the public REST surface or via a Call Activity. Internal-only
  start parameters that arrive on the public surface are ignored, not honored.
  """
  use BfwEngine.ExecutionCase, async: false

  setup do
    original_resolver = Application.get_env(:core_execution, :called_element_resolver)

    Application.put_env(
      :core_execution,
      :called_element_resolver,
      BfwEngine.Persistence.CalledElementResolverImpl
    )

    on_exit(fn ->
      if original_resolver do
        Application.put_env(:core_execution, :called_element_resolver, original_resolver)
      else
        Application.delete_env(:core_execution, :called_element_resolver)
      end
    end)

    :ok
  end

  # -------------------------------------------------------------------
  # Public REST start surface
  # -------------------------------------------------------------------

  describe "REST start surface" do
    test "starting an inner subprocess start event by id returns 422 start_event_not_found" do
      {201, _} = http_deploy("embedded_subprocess_happy_path.bpmn")

      {status, body} =
        http_start("EmbeddedSubprocessHappyPath", %{"startEventId" => "Sub_Start"})

      assert status == 422
      assert body["error"] == "start_event_not_found"
    end

    test "an extraneous subprocessNodeId in the start body is ignored" do
      {201, _} = http_deploy("embedded_subprocess_happy_path.bpmn")

      {status, body} =
        http_start("EmbeddedSubprocessHappyPath", %{"subprocessNodeId" => "SubProcess_1"})

      assert status == 201
      process_instance_id = body["processInstanceId"]
      assert is_binary(process_instance_id)

      # The PI starts at the top-level Start Event and runs the subprocess to
      # completion; it is NOT scoped into the inner subprocess.
      poll_pi_state(process_instance_id, "finished", 10_000)
    end
  end

  # -------------------------------------------------------------------
  # Call Activity cannot reach an inner subprocess scope
  # -------------------------------------------------------------------

  describe "Call Activity cannot reach an inner subprocess scope" do
    test "calledElement targeting a synthetic subprocess model id fatals the parent" do
      {201, _} = http_deploy("embedded_subprocess_happy_path.bpmn")
      {201, _} = http_deploy("subprocess_isolation_ca_synthetic.bpmn")

      {201, body} = http_start("SubprocessIsolationCaSynthetic")
      parent_process_instance_id = body["processInstanceId"]

      poll_pi_state(parent_process_instance_id, "fatal", 10_000)
      assert_pi_state!(parent_process_instance_id, "fatal")
    end

    test "bfw:startEventId targeting an inner subprocess start of the child fatals the parent" do
      {201, _} = http_deploy("embedded_subprocess_happy_path.bpmn")
      {201, _} = http_deploy("subprocess_isolation_ca_inner_start.bpmn")

      {201, body} = http_start("SubprocessIsolationCaInnerStart")
      parent_process_instance_id = body["processInstanceId"]

      poll_pi_state(parent_process_instance_id, "fatal", 10_000)
      assert_pi_state!(parent_process_instance_id, "fatal")
    end
  end
end

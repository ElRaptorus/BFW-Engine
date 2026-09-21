defmodule BfwEngine.Integration.Execution.DataObjectExecutionTest do
  @moduledoc """
  Integration tests for Data Object execution. Each test deploys a real
  BPMN with DataObjects/DOAs, starts a PI via HTTP, and asserts DB state
  and event ordering.
  """
  use BfwEngine.ExecutionCase, async: false

  alias BfwEngine.Execution
  alias BfwEngine.Execution.ResumeRunner
  alias BfwEngine.Test.EventCollector
  alias BfwEngine.Types.Event

  # -------------------------------------------------------------------
  # 1. Simple Write (full token, no expression)
  # -------------------------------------------------------------------

  describe "DO-I1: simple full-token write" do
    test "ScriptTask DOA writes full output to DataObject", %{collector: collector} do
      process_instance_id =
        http_deploy_and_start("data_object_simple_write.bpmn", "DataObjectSimpleWrite", %{
          "payload" => %{"amount" => 42}
        })

      wait_for_process_instance(process_instance_id)

      assert_pi_state!(process_instance_id, "finished")
      assert_all_fnis_state!(process_instance_id, "finished")

      do_snapshot = fetch_data_object(process_instance_id, "DO_1")
      assert do_snapshot != nil, "Expected a DataObject snapshot for DO_1"
      assert do_snapshot.value["order_id"] == "ABC-123"
      assert do_snapshot.value["total"] == 42

      writes = fetch_data_object_writes(process_instance_id, "DO_1")
      assert length(writes) == 1
      [write] = writes
      assert write.value["order_id"] == "ABC-123"

      events = EventCollector.get_events(collector)
      do_events = Enum.filter(events, &match?(%Event.DataObjectWritten{}, &1))
      assert length(do_events) == 1

      [event] = do_events
      assert event.process_instance_id == process_instance_id
      assert event.data_object_id == "DO_1"
      assert event.value["order_id"] == "ABC-123"
      assert event.value["total"] == 42
      assert event.previous_value == nil
      assert event.write_id != nil
      assert %DateTime{} = event.created_at
    end
  end

  # -------------------------------------------------------------------
  # 2. FEEL Expression Write (extract a field)
  # -------------------------------------------------------------------

  describe "DO-I2: FEEL expression write" do
    test "DOA with transformation writes only the evaluated value", %{collector: collector} do
      process_instance_id =
        http_deploy_and_start("data_object_feel_expression.bpmn", "DataObjectFeelExpression", %{
          "payload" => %{"amount" => 10}
        })

      wait_for_process_instance(process_instance_id)

      assert_pi_state!(process_instance_id, "finished")

      do_snapshot = fetch_data_object(process_instance_id, "DO_1")
      assert do_snapshot != nil
      assert do_snapshot.value == 30

      events = EventCollector.get_events(collector)
      do_events = Enum.filter(events, &match?(%Event.DataObjectWritten{}, &1))
      assert length(do_events) == 1
      [event] = do_events
      assert event.data_object_id == "DO_1"
      assert event.value == 30
    end
  end

  # -------------------------------------------------------------------
  # 3. Multi Write (same DO overwritten twice)
  # -------------------------------------------------------------------

  describe "DO-I3: multi write to same DataObject" do
    test "second write replaces first, history has 2 entries", %{collector: collector} do
      process_instance_id =
        http_deploy_and_start("data_object_multi_write.bpmn", "DataObjectMultiWrite", %{
          "payload" => %{"amount" => 5}
        })

      wait_for_process_instance(process_instance_id)

      assert_pi_state!(process_instance_id, "finished")

      do_snapshot = fetch_data_object(process_instance_id, "DO_1")
      assert do_snapshot.value["step"] == 2

      writes = fetch_data_object_writes(process_instance_id, "DO_1")
      assert length(writes) == 2

      events = EventCollector.get_events(collector)
      do_events = Enum.filter(events, &match?(%Event.DataObjectWritten{}, &1))
      assert length(do_events) == 2
    end
  end

  # -------------------------------------------------------------------
  # 4. Value Contract Violation
  # -------------------------------------------------------------------

  describe "DO-I4: value contract violation" do
    test "PI goes fatal when DOA value violates contract", %{collector: collector} do
      process_instance_id =
        http_deploy_and_start("data_object_value_contract_violation.bpmn", "DataObjectContractViolation", %{
          "payload" => %{"amount" => 42}
        })

      wait_for_process_instance(process_instance_id)

      assert_pi_state!(process_instance_id, "fatal")
      assert_no_running_fnis!(process_instance_id)

      flow_node_instances = fetch_flow_node_instances(process_instance_id)
      fatal_fni = Enum.find(flow_node_instances, &(&1.state == "fatal" && &1.flow_node_type == "script_task"))
      assert fatal_fni != nil, "ScriptTask FNI should be fatal"
      assert fatal_fni.error_info != nil

      data_objects = fetch_data_objects(process_instance_id)
      assert data_objects == [], "No DataObject snapshot should exist for violating DO"

      writes = fetch_data_object_writes(process_instance_id)
      assert writes == [], "No write audit rows should exist"

      events = EventCollector.get_events(collector)
      do_events = Enum.filter(events, &match?(%Event.DataObjectWritten{}, &1))
      assert do_events == [], "No DataObjectWritten event should be emitted on failure"
    end
  end

  # -------------------------------------------------------------------
  # 5. Value Contract Pass
  # -------------------------------------------------------------------

  describe "DO-I5: value contract pass" do
    test "PI finishes when DOA value satisfies contract", %{collector: collector} do
      process_instance_id =
        http_deploy_and_start("data_object_value_contract_pass.bpmn", "DataObjectContractPass")

      wait_for_process_instance(process_instance_id)

      assert_pi_state!(process_instance_id, "finished")
      assert_all_fnis_state!(process_instance_id, "finished")

      do_snapshot = fetch_data_object(process_instance_id, "DO_1")
      assert do_snapshot != nil
      assert do_snapshot.value["name"] == "Alice"
      assert do_snapshot.value["email"] == "alice@test.com"

      events = EventCollector.get_events(collector)
      do_events = Enum.filter(events, &match?(%Event.DataObjectWritten{}, &1))
      assert length(do_events) == 1
      [event] = do_events
      assert event.data_object_id == "DO_1"
      assert event.value["name"] == "Alice"
    end
  end

  # -------------------------------------------------------------------
  # 6. Resume — DO survives engine restart
  # -------------------------------------------------------------------

  describe "DO-I6: resume rehydrates data object cache" do
    test "DO written before pause survives restart and is readable via FEEL", %{collector: _collector} do
      process_instance_id =
        http_deploy_and_start("data_object_resume.bpmn", "DataObjectResume", %{
          "payload" => %{"amount" => 3}
        })

      ut_fni = poll_fni_state(process_instance_id, "user_task", "waiting")

      do_snapshot = fetch_data_object(process_instance_id, "DO_1")
      assert do_snapshot != nil
      assert do_snapshot.value["persisted_value"] == 21

      terminate_process_instance(process_instance_id)
      await_process_exit(process_instance_id)
      assert_pi_state!(process_instance_id, "running")

      {:ok, _resumed_count} = ResumeRunner.resume_all()
      {:ok, _pid} = poll_pi_alive(process_instance_id)

      {204, _} = http_finish_user_task(ut_fni.id, %{"approved" => true})

      wait_for_process_instance(process_instance_id)
      assert_pi_state!(process_instance_id, "finished")
      assert_all_fnis_state!(process_instance_id, "finished")
    end
  end

  # -------------------------------------------------------------------
  # 7. Corrupt FEEL on DOA
  # -------------------------------------------------------------------

  describe "DO-I7: corrupt FEEL expression on DOA" do
    test "PI goes fatal, no DO written", %{collector: collector} do
      process_instance_id =
        http_deploy_and_start("data_object_doa_corrupt_feel.bpmn", "DataObjectDoaCorruptFeel", %{
          "payload" => %{"data" => "x"}
        })

      wait_for_process_instance(process_instance_id)

      assert_pi_state!(process_instance_id, "fatal")
      assert_no_running_fnis!(process_instance_id)

      data_objects = fetch_data_objects(process_instance_id)
      assert data_objects == []

      writes = fetch_data_object_writes(process_instance_id)
      assert writes == []

      events = EventCollector.get_events(collector)
      do_events = Enum.filter(events, &match?(%Event.DataObjectWritten{}, &1))
      assert do_events == [], "No DataObjectWritten event should be emitted on failure"
    end
  end

  # -------------------------------------------------------------------
  # 8. Multi Object Mixed Access
  # -------------------------------------------------------------------

  describe "DO-I8: multi object mixed access" do
    test "multiple DOs with read/write from FEEL and DOAs", %{collector: collector} do
      process_instance_id =
        http_deploy_and_start("data_object_multi_object_mixed_access.bpmn", "DataObjectMultiMixed", %{
          "payload" => %{"amount" => 4}
        })

      wait_for_process_instance(process_instance_id)

      assert_pi_state!(process_instance_id, "finished")
      assert_all_fnis_state!(process_instance_id, "finished")

      config_do = fetch_data_object(process_instance_id, "DO_Config")
      assert config_do != nil
      assert config_do.value["multiplier"] == 5
      assert config_do.value["label"] == "test"

      result_do = fetch_data_object(process_instance_id, "DO_Result")
      assert result_do != nil
      assert result_do.value == 120

      result_writes = fetch_data_object_writes(process_instance_id, "DO_Result")
      assert length(result_writes) == 2
      [first, second] = result_writes
      assert first.value == 20
      assert second.value == 120

      events = EventCollector.get_events(collector)
      do_events = Enum.filter(events, &match?(%Event.DataObjectWritten{}, &1))
      assert length(do_events) == 3
    end
  end

  # -------------------------------------------------------------------
  # 9. Shared Reference (two DORs pointing to same DO)
  # -------------------------------------------------------------------

  describe "DO-I9: shared reference" do
    test "two DataObjectReferences writing to same DataObject", %{collector: collector} do
      process_instance_id =
        http_deploy_and_start("data_object_shared_reference.bpmn", "DataObjectSharedRef", %{
          "payload" => %{"amount" => 10}
        })

      wait_for_process_instance(process_instance_id)

      assert_pi_state!(process_instance_id, "finished")
      assert_all_fnis_state!(process_instance_id, "finished")

      do_snapshot = fetch_data_object(process_instance_id, "DO_1")
      assert do_snapshot != nil
      assert do_snapshot.value["source"] == "A_final"
      assert do_snapshot.value["value"] == 999

      writes = fetch_data_object_writes(process_instance_id, "DO_1")
      assert length(writes) == 3
      assert Enum.all?(writes, &(&1.data_object_id == "DO_1"))

      events = EventCollector.get_events(collector)
      do_events = Enum.filter(events, &match?(%Event.DataObjectWritten{}, &1))
      assert length(do_events) == 3
    end
  end

  # -------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------

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
end

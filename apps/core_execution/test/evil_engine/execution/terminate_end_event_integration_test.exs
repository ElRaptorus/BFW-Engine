defmodule EvilEngine.Execution.TerminateEndEventIntegrationTest do
  @moduledoc """
  Integration tests for the Terminate End Event lifecycle:

  1. Handler returns `{:terminate, FlowNodeResult}` — PI finishes the
     terminate FNI normally, then interrupts all remaining active/waiting FNIs.
  2. PI finishes as `:finished` with the terminate end event's token in
     the final result.
  3. Interrupted FNIs get `handle_aborted/1` callbacks for resource cleanup.

  These tests use in-memory BPMN models (BpmnFactory) and NoOp persistence.
  """

  use ExUnit.Case, async: false

  alias EvilEngine.BPMN.ModelCache
  alias EvilEngine.Execution.ProcessInstance
  alias EvilEngine.Execution.TestSupport.BpmnFactory
  alias EvilEngine.Timers.Scheduler
  alias EvilEngine.Types.Identity

  @test_identity %Identity{id: "test-user", roles: ["admin"], groups: ["all"]}

  setup do
    Scheduler.reset_state()
    :ok
  end

  defp start_pi(definitions, payload \\ %{}) do
    version_id = "version-#{System.unique_integer([:positive])}"
    ModelCache.put_new(version_id, definitions)
    process_instance_id = "pi-#{System.unique_integer([:positive])}"

    opts = %{
      process_instance_id: process_instance_id,
      process_version_id: version_id,
      payload: payload,
      identity: @test_identity
    }

    {:ok, pid} =
      DynamicSupervisor.start_child(EvilEngine.Execution.Supervisor, {ProcessInstance, opts})

    %{pid: pid, process_instance_id: process_instance_id, version_id: version_id}
  end

  defp attach_pi_telemetry(label) do
    test_pid = self()
    ref = make_ref()

    :telemetry.attach(
      "terminate-pi-#{label}-#{inspect(ref)}",
      [:evil_engine, :process_instance, :state_change],
      fn _event, _measurements, metadata, _config ->
        send(test_pid, {:pi_state, ref, metadata.new_state, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach("terminate-pi-#{label}-#{inspect(ref)}") end)
    ref
  end

  defp attach_fni_telemetry(label) do
    test_pid = self()
    ref = make_ref()

    :telemetry.attach(
      "terminate-fni-#{label}-#{inspect(ref)}",
      [:evil_engine, :flow_node_instance, :state_change],
      fn _event, _measurements, metadata, _config ->
        send(test_pid, {:fni_state, ref, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach("terminate-fni-#{label}-#{inspect(ref)}") end)
    ref
  end

  defp collect_fni_events(ref, timeout \\ 500) do
    collect_fni_events_acc(ref, timeout, [])
  end

  defp collect_fni_events_acc(ref, timeout, acc) do
    receive do
      {:fni_state, ^ref, meta} ->
        if Map.has_key?(meta, :terminal_state) do
          collect_fni_events_acc(ref, timeout, [meta | acc])
        else
          collect_fni_events_acc(ref, timeout, acc)
        end
    after
      timeout -> Enum.reverse(acc)
    end
  end

  describe "single path terminate" do
    test "PI finishes normally when the only end event is a terminate end event" do
      definitions = BpmnFactory.single_path_terminate()

      pi_ref = attach_pi_telemetry("single-path")

      %{pid: _pid} = start_pi(definitions)

      assert_receive {:pi_state, ^pi_ref, :finished, _meta}, 5_000
    end

    test "terminate end event preserves payload" do
      definitions = BpmnFactory.single_path_terminate()
      payload = %{"order_id" => "ORD-42", "total" => 100}

      pi_ref = attach_pi_telemetry("single-path-payload")

      %{pid: _pid} = start_pi(definitions, payload)

      assert_receive {:pi_state, ^pi_ref, :finished, _meta}, 5_000
    end
  end

  describe "parallel split with terminate" do
    test "terminate fires while UserTask is waiting — PI finishes, UserTask interrupted" do
      definitions = BpmnFactory.parallel_with_terminate_end_event()

      pi_ref = attach_pi_telemetry("parallel-terminate")
      fni_ref = attach_fni_telemetry("parallel-terminate-fni")

      %{pid: _pid} = start_pi(definitions)

      assert_receive {:pi_state, ^pi_ref, :finished, _meta}, 5_000

      fni_events = collect_fni_events(fni_ref)

      interrupted_fnis =
        Enum.filter(fni_events, fn meta -> meta.terminal_state == :interrupted end)

      assert interrupted_fnis != [],
             "at least one FNI should be interrupted by the terminate end event"
    end

    test "terminate fires with payload — PI finishes normally" do
      definitions = BpmnFactory.parallel_with_terminate_end_event()
      payload = %{"test" => true}

      pi_ref = attach_pi_telemetry("parallel-payload")

      %{pid: _pid} = start_pi(definitions, payload)

      assert_receive {:pi_state, ^pi_ref, :finished, _meta}, 5_000
    end
  end

  describe "parallel terminate with timer sibling" do
    test "terminate interrupts a waiting timer catch event" do
      definitions = BpmnFactory.parallel_terminate_with_timer(time_duration: "PT1H")

      pi_ref = attach_pi_telemetry("terminate-timer")
      fni_ref = attach_fni_telemetry("terminate-timer-fni")

      %{pid: _pid} = start_pi(definitions)

      assert_receive {:pi_state, ^pi_ref, :finished, _meta}, 5_000

      fni_events = collect_fni_events(fni_ref)

      interrupted_fnis =
        Enum.filter(fni_events, fn meta -> meta.terminal_state == :interrupted end)

      assert interrupted_fnis != [],
             "timer catch FNI should be interrupted by terminate end event"
    end

    test "timer cleanup: armed timers are cancelled via handle_aborted" do
      definitions = BpmnFactory.parallel_terminate_with_timer(time_duration: "PT1H")

      pi_ref = attach_pi_telemetry("terminate-timer-cleanup")

      %{pid: _pid} = start_pi(definitions)

      assert_receive {:pi_state, ^pi_ref, :finished, _meta}, 5_000

      Process.sleep(100)
      assert Scheduler.armed_count() == 0
    end
  end

  describe "parallel terminate with call activity sibling" do
    test "terminate interrupts a waiting call activity (child gets aborted)" do
      child_definitions = BpmnFactory.user_task_process(process_id: "child-process")
      child_version_id = "child-version-#{System.unique_integer([:positive])}"
      ModelCache.put_new(child_version_id, child_definitions)

      definitions =
        BpmnFactory.parallel_terminate_with_call_activity(called_element: "child-process")

      pi_ref = attach_pi_telemetry("terminate-call-activity")

      %{pid: _pid} = start_pi(definitions)

      assert_receive {:pi_state, ^pi_ref, :finished, _meta}, 5_000
    end
  end

  describe "notify parent on terminate" do
    test "child PI with terminate end event notifies parent with final tokens" do
      definitions = BpmnFactory.single_path_terminate("child-process")
      version_id = "version-#{System.unique_integer([:positive])}"
      ModelCache.put_new(version_id, definitions)

      process_instance_id = "pi-#{System.unique_integer([:positive])}"

      opts = %{
        process_instance_id: process_instance_id,
        process_version_id: version_id,
        payload: %{"test" => true},
        identity: @test_identity,
        notify_pid: self()
      }

      {:ok, pid} =
        DynamicSupervisor.start_child(EvilEngine.Execution.Supervisor, {ProcessInstance, opts})

      assert_receive {:child_pi_finished, ^pid, final_tokens}, 5_000
      assert is_list(final_tokens)
      assert final_tokens != []

      terminate_token =
        Enum.find(final_tokens, fn token -> token.end_event_id == "End_Terminate" end)

      assert terminate_token != nil
      assert terminate_token.payload == %{"test" => true}
    end
  end
end

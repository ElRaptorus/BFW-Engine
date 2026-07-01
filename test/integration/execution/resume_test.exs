defmodule EvilEngine.Integration.Execution.ResumeTest do
  @moduledoc "Integration tests for resume-on-startup (Item 15)."
  use EvilEngine.ExecutionCase, async: false

  alias EvilEngine.Execution
  alias EvilEngine.Execution.ProcessInstance
  alias EvilEngine.Execution.ResumeRunner
  alias EvilEngine.Plugins.Loader
  alias EvilEngine.Test.EventCollector
  alias EvilEngine.Test.ExamplePlugin
  alias EvilEngine.Types.Event

  # -------------------------------------------------------------------
  # I1: Resume user task
  # -------------------------------------------------------------------

  describe "I1: resume user task" do
    test "resumed PI with waiting user task can be finished", %{collector: _collector} do
      process_instance_id = http_deploy_and_start("user_task_simple.bpmn", "UserTaskSimple", %{"payload" => %{"key" => "value"}})

      ut_fni = poll_fni_state(process_instance_id, "user_task", "waiting")

      terminate_process_instance(process_instance_id)
      await_process_exit(process_instance_id)
      assert_pi_state!(process_instance_id, "running")

      {:ok, resumed_count} = ResumeRunner.resume_all()
      assert resumed_count == 1

      {:ok, process_instance_pid} = poll_pi_alive(process_instance_id)
      assert Process.alive?(process_instance_pid)

      {204, _} = http_finish_user_task(ut_fni.id, %{"approved" => true})

      wait_for_process_instance(process_instance_id)
      assert_pi_state!(process_instance_id, "finished")
    end
  end

  # -------------------------------------------------------------------
  # I2: Resume async service task
  # -------------------------------------------------------------------

  describe "I2: resume async service task" do
    test "resumed PI with async service task can be completed via plugin", %{collector: _collector} do
      register_test_plugin()

      process_instance_id = http_deploy_and_start("service_task_async_park.bpmn", "ServiceTaskAsyncPark")

      st_fni = poll_fni_state(process_instance_id, "service_task", "waiting")

      terminate_process_instance(process_instance_id)
      await_process_exit(process_instance_id)
      assert_pi_state!(process_instance_id, "running")

      {:ok, _} = ResumeRunner.resume_all()

      {:ok, process_instance_pid} = poll_pi_alive(process_instance_id)
      assert [{^process_instance_pid, :async}] = Registry.lookup(EvilEngine.Execution.Registry, {:fni, st_fni.id})

      assert :ok = ProcessInstance.finish_async_service_task(process_instance_pid, st_fni.id, %{"result" => "done"})

      wait_for_process_instance(process_instance_id)
      assert_pi_state!(process_instance_id, "finished")
    end
  end

  # -------------------------------------------------------------------
  # I3: Resume manual task (confirm)
  # -------------------------------------------------------------------

  describe "I3: resume manual task with confirmation" do
    test "resumed PI with waiting manual task can be finished", %{collector: _collector} do
      process_instance_id = http_deploy_and_start("manual_task_confirm.bpmn", "ManualTaskConfirm")

      mt_fni = poll_fni_state(process_instance_id, "manual_task", "waiting")

      terminate_process_instance(process_instance_id)
      await_process_exit(process_instance_id)
      assert_pi_state!(process_instance_id, "running")

      {:ok, _} = ResumeRunner.resume_all()

      {:ok, _process_instance_pid} = poll_pi_alive(process_instance_id)
      {204, _} = http_finish_user_task(mt_fni.id, %{})

      wait_for_process_instance(process_instance_id)
      assert_pi_state!(process_instance_id, "finished")
    end
  end

  # -------------------------------------------------------------------
  # I4: Resume preserves payload
  # -------------------------------------------------------------------

  describe "I4: resume preserves payload" do
    test "started_with_context and input_token are preserved after resume", %{collector: _collector} do
      payload = %{"key" => "value", "nested" => %{"a" => 1}}
      process_instance_id = http_deploy_and_start("user_task_simple.bpmn", "UserTaskSimple", %{"payload" => payload})

      ut_fni = poll_fni_state(process_instance_id, "user_task", "waiting")

      process_instance_before = fetch_process_instance!(process_instance_id)

      terminate_process_instance(process_instance_id)
      await_process_exit(process_instance_id)
      assert_pi_state!(process_instance_id, "running")

      {:ok, _} = ResumeRunner.resume_all()

      {:ok, process_instance_pid} = poll_pi_alive(process_instance_id)
      {:running, state} = :sys.get_state(process_instance_pid)

      assert state.started_with_context == process_instance_before.started_with_context
      resumed_entry = state.flow_node_instance_states[ut_fni.id]
      assert resumed_entry.token.payload == ut_fni.input_token
    end
  end

  # -------------------------------------------------------------------
  # I5: Resume + complete + verify DB
  # -------------------------------------------------------------------

  describe "I5: resume + complete + verify DB" do
    test "DB shows finished state after resume and completion", %{collector: _collector} do
      register_test_plugin()

      process_instance_id = http_deploy_and_start("service_task_async_park.bpmn", "ServiceTaskAsyncPark")

      st_fni = poll_fni_state(process_instance_id, "service_task", "waiting")

      terminate_process_instance(process_instance_id)
      await_process_exit(process_instance_id)
      assert_pi_state!(process_instance_id, "running")

      {:ok, _} = ResumeRunner.resume_all()

      {:ok, process_instance_pid} = poll_pi_alive(process_instance_id)
      assert :ok = ProcessInstance.finish_async_service_task(process_instance_pid, st_fni.id, %{"done" => true})

      wait_for_process_instance(process_instance_id)

      assert_pi_state!(process_instance_id, "finished")
      assert_all_fnis_state!(process_instance_id, "finished")
    end
  end

  # -------------------------------------------------------------------
  # I6: Resume skips finished PIs
  # -------------------------------------------------------------------

  describe "I6: resume skips finished PIs" do
    test "only running PIs are resumed", %{collector: _collector} do
      _finished_process_instance_id = http_deploy_and_start("linear_start_end.bpmn", "LinearStartEnd")

      waiting_process_instance_id = http_deploy_and_start("user_task_simple.bpmn", "UserTaskSimple")

      ut_fni = poll_fni_state(waiting_process_instance_id, "user_task", "waiting")
      assert ut_fni.state == "waiting"

      terminate_process_instance(waiting_process_instance_id)
      await_process_exit(waiting_process_instance_id)
      assert_pi_state!(waiting_process_instance_id, "running")

      {:ok, resumed_count} = ResumeRunner.resume_all()
      assert resumed_count == 1

      assert {:ok, _pid} = poll_pi_alive(waiting_process_instance_id)
    end
  end

  # -------------------------------------------------------------------
  # I7: Resume handles fatal PIs
  # -------------------------------------------------------------------

  describe "I7: resume handles fatal PIs" do
    test "fatal PIs are not resumed", %{collector: _collector} do
      process_instance_id = http_deploy_and_start("dead_end.bpmn", "DeadEnd")
      wait_for_process_instance(process_instance_id, 5_000)

      assert_pi_state!(process_instance_id, "fatal")
      assert_no_running_fnis!(process_instance_id)

      {:ok, resumed_count} = ResumeRunner.resume_all()
      assert resumed_count == 0
    end
  end

  # -------------------------------------------------------------------
  # I_paginate: Multi-batch resume (PF-1)
  # -------------------------------------------------------------------

  describe "I_paginate: ResumeRunner drives the pagination loop across batches" do
    setup do
      previous_batch_size = Application.get_env(:core_execution, :resume_batch_size)
      Application.put_env(:core_execution, :resume_batch_size, 5)

      on_exit(fn ->
        if previous_batch_size do
          Application.put_env(:core_execution, :resume_batch_size, previous_batch_size)
        else
          Application.delete_env(:core_execution, :resume_batch_size)
        end
      end)

      :ok
    end

    test "resumes 12 PIs across 3 batches with batch_size=5", %{collector: _collector} do
      {201, _} = http_deploy("user_task_simple.bpmn")

      process_instance_ids =
        Enum.map(1..12, fn i ->
          {201, body} = http_start("UserTaskSimple", %{"payload" => %{"n" => i}})
          process_instance_id = body["processInstanceId"]

          poll_fni_state(process_instance_id, "user_task", "waiting")
          terminate_process_instance(process_instance_id)
          await_process_exit(process_instance_id)
          assert_pi_state!(process_instance_id, "running")

          process_instance_id
        end)

      {:ok, resumed_count} = ResumeRunner.resume_all()

      assert resumed_count == 12

      Enum.each(process_instance_ids, fn process_instance_id ->
        assert {:ok, pid} = poll_pi_alive(process_instance_id)
        assert Process.alive?(pid)
      end)
    end
  end

  # -------------------------------------------------------------------
  # I_cap: cap is bypassed during resume but enforced for new starts
  # -------------------------------------------------------------------

  describe "I_cap: cap is bypassed during resume but enforced for new starts" do
    setup do
      previous_cap = Application.get_env(:core_execution, :max_concurrent_process_instances)

      on_exit(fn ->
        if previous_cap do
          Application.put_env(:core_execution, :max_concurrent_process_instances, previous_cap)
        else
          Application.delete_env(:core_execution, :max_concurrent_process_instances)
        end
      end)

      :ok
    end

    test "resumes all PIs ignoring EVIL_MAX_CONCURRENT_PIS; new HTTP starts return 503",
         %{collector: _collector} do
      cap = 3
      total = 5

      {201, _} = http_deploy("user_task_simple.bpmn")

      process_instance_ids =
        Enum.map(1..total, fn i ->
          {201, body} = http_start("UserTaskSimple", %{"payload" => %{"n" => i}})
          process_instance_id = body["processInstanceId"]

          poll_fni_state(process_instance_id, "user_task", "waiting")
          terminate_process_instance(process_instance_id)
          await_process_exit(process_instance_id)
          assert_pi_state!(process_instance_id, "running")

          process_instance_id
        end)

      Application.put_env(:core_execution, :max_concurrent_process_instances, cap)

      {:ok, resumed_count} = ResumeRunner.resume_all()
      assert resumed_count == total
      assert DynamicSupervisor.count_children(EvilEngine.Execution.Supervisor).active == total

      Enum.each(process_instance_ids, fn process_instance_id ->
        assert_pi_state!(process_instance_id, "running")
      end)

      {503, body} = http_start("UserTaskSimple", %{"payload" => %{"new" => true}})

      assert body["error"] == "engine_at_capacity"
      assert body["active"] == total
      assert body["limit"] == cap
    end
  end

  # -------------------------------------------------------------------
  # I8: EngineStarted event
  # -------------------------------------------------------------------

  describe "I8: EngineStarted event" do
    test "EngineStarted is emitted after resume completes", %{collector: collector} do
      events_before = length(EventCollector.get_events(collector))

      {:ok, _} = ResumeRunner.resume_all()
      Process.sleep(100)

      events = EventCollector.get_events(collector) |> Enum.drop(events_before)
      engine_started = Enum.find(events, &match?(%Event.EngineStarted{}, &1))
      assert engine_started != nil
      assert engine_started.engine_id != nil
    end
  end

  # -------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------

  defp terminate_process_instance(process_instance_id) do
    case Execution.lookup_process_instance(process_instance_id) do
      {:ok, pid} ->
        DynamicSupervisor.terminate_child(EvilEngine.Execution.Supervisor, pid)

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

  defp register_test_plugin do
    Application.put_env(:core_execution, :service_task_dispatch, EvilEngine.Plugins.RegistryDispatch)
    facade = Loader.facade_for_plugin("evil:test_resume")
    ExamplePlugin.on_load(facade)
  end
end

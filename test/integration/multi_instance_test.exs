defmodule BfwEngine.Integration.MultiInstanceTest do
  @moduledoc """
  Umbrella-level integration tests for Multi-Instance (parallel and sequential)
  execution via the lightweight iteration scope architecture.

  Exercises the full HTTP deploy → start → interact → assert lifecycle against
  real PostgreSQL persistence, covering happy paths, error handling, boundary
  events, empty/capped collections, nested MI, resume, and retry.
  """
  use BfwEngine.ExecutionCase, async: false

  require Ash.Query

  alias BfwEngine.Test.EventCollector
  alias BfwEngine.Types.Event

  @default_timeout 15_000

  # ===================================================================
  # Section 1: Parallel MI — Happy Paths
  # ===================================================================

  describe "Section 1 — parallel MI happy paths" do
    test "1.1 parallel MI script task — 3 items processed", %{collector: collector} do
      {201, _} = http_deploy("mi_parallel_script_task.bpmn")

      {201, body} =
        http_start("mi-parallel-script-task", %{
          "payload" => %{"items" => [%{"value" => 1}, %{"value" => 2}, %{"value" => 3}]}
        })

      process_instance_id = body["processInstanceId"]
      wait_for_process_instance(process_instance_id, @default_timeout)

      assert_pi_state!(process_instance_id, "finished")

      events = EventCollector.get_events(collector)

      multi_instance_started = Enum.find(events, &match?(%Event.MultiInstanceStarted{}, &1))
      assert multi_instance_started != nil
      assert multi_instance_started.loop_type == "parallel_mi"
      assert multi_instance_started.total_iterations == 3

      multi_instance_completed = Enum.find(events, &match?(%Event.MultiInstanceCompleted{}, &1))
      assert multi_instance_completed != nil
      assert multi_instance_completed.completed_iterations == 3
      assert multi_instance_completed.early_break == false

      iteration_records =
        BfwEngine.Persistence.Resources.FlowNodeInstance
        |> Ash.Query.filter(
          process_instance_id == ^process_instance_id and not is_nil(multi_instance_id)
        )
        |> Ash.read!(authorize?: false)

      finished_iterations =
        Enum.filter(iteration_records, fn record ->
          record.state == "finished" and is_integer(record.iteration_index)
        end)

      assert length(finished_iterations) == 3

      for record <- finished_iterations do
        assert is_map(record.output_token),
               "iteration FNI #{record.id} must persist output_token on :update_finished, got #{inspect(record.output_token)}"
      end
    end

    test "1.2 parallel MI user task — finish each iteration", %{collector: _collector} do
      {201, _} = http_deploy("mi_parallel_user_task.bpmn")

      {201, body} =
        http_start("mi-parallel-user-task", %{
          "payload" => %{"items" => [%{"name" => "A"}, %{"name" => "B"}]}
        })

      process_instance_id = body["processInstanceId"]

      waiting_user_task_fnis =
        await_multiple_waiting_flow_node_instances(
          process_instance_id,
          "user_task",
          2,
          timeout: @default_timeout
        )

      for flow_node_instance <- waiting_user_task_fnis do
        {204, _} = http_finish_user_task(flow_node_instance.id, %{"approved" => true})
      end

      wait_for_process_instance(process_instance_id, @default_timeout)
      assert_pi_state!(process_instance_id, "finished")
    end

    test "1.3 parallel MI completion condition — stops early", %{collector: collector} do
      {201, _} = http_deploy("mi_parallel_completion_condition.bpmn")

      {201, body} =
        http_start("mi-parallel-completion-condition", %{
          "payload" => %{
            "items" => Enum.map(1..5, fn index -> %{"value" => index} end)
          }
        })

      process_instance_id = body["processInstanceId"]
      wait_for_process_instance(process_instance_id, @default_timeout)

      assert_pi_state!(process_instance_id, "finished")

      events = EventCollector.get_events(collector)

      multi_instance_completed = Enum.find(events, &match?(%Event.MultiInstanceCompleted{}, &1))
      assert multi_instance_completed != nil
      assert multi_instance_completed.early_break == true
    end

    test "1.4 parallel MI BRT — business rule per item" do
      {201, _} = http_deploy("mi_parallel_brt.bpmn")

      {201, body} =
        http_start("mi-parallel-brt", %{
          "payload" => %{"items" => [%{"amount" => 100}, %{"amount" => 200}]}
        })

      process_instance_id = body["processInstanceId"]
      wait_for_process_instance(process_instance_id, @default_timeout)

      assert_pi_state!(process_instance_id, "finished")
    end

    test "1.5 parallel MI service task — async completion per iteration" do
      register_test_service_task_handler()

      {201, _} = http_deploy("mi_parallel_service_task.bpmn")

      {201, body} =
        http_start("mi-parallel-service-task", %{
          "payload" => %{"items" => [%{"value" => 1}, %{"value" => 2}]}
        })

      process_instance_id = body["processInstanceId"]

      waiting_service_task_fnis =
        await_multiple_waiting_flow_node_instances(
          process_instance_id,
          "service_task",
          2,
          timeout: @default_timeout
        )

      for flow_node_instance <- waiting_service_task_fnis do
        :ok = finish_async_service_task(flow_node_instance.id, %{"done" => true})
      end

      wait_for_process_instance(process_instance_id, @default_timeout)
      assert_pi_state!(process_instance_id, "finished")
    end

    test "1.6 parallel MI subprocess — embedded subprocess per iteration" do
      {201, _} = http_deploy("mi_parallel_subprocess.bpmn")

      {201, body} =
        http_start("mi-parallel-subprocess", %{
          "payload" => %{"items" => [%{"value" => 1}, %{"value" => 2}]}
        })

      process_instance_id = body["processInstanceId"]
      wait_for_process_instance(process_instance_id, @default_timeout)

      assert_pi_state!(process_instance_id, "finished")
    end

    test "1.7 parallel MI call activity — child process per iteration" do
      {201, _} = http_deploy("mi_parallel_ca_child.bpmn")
      {201, _} = http_deploy("mi_parallel_call_activity.bpmn")

      {201, body} =
        http_start("mi-parallel-call-activity", %{
          "payload" => %{"items" => [%{"value" => 1}, %{"value" => 2}]}
        })

      process_instance_id = body["processInstanceId"]
      wait_for_process_instance(process_instance_id, @default_timeout)

      assert_pi_state!(process_instance_id, "finished")
    end
  end

  # ===================================================================
  # Section 2: Sequential MI — Happy Paths
  # ===================================================================

  describe "Section 2 — sequential MI happy paths" do
    test "2.1 sequential MI script task — 3 items in order" do
      {201, _} = http_deploy("mi_sequential_script_task.bpmn")

      {201, body} =
        http_start("mi-sequential-script-task", %{
          "payload" => %{"items" => [%{"value" => 1}, %{"value" => 2}, %{"value" => 3}]}
        })

      process_instance_id = body["processInstanceId"]
      wait_for_process_instance(process_instance_id, @default_timeout)

      assert_pi_state!(process_instance_id, "finished")
    end

    test "2.2 sequential MI with interval delay" do
      {201, _} = http_deploy("mi_sequential_with_interval.bpmn")

      {201, body} =
        http_start("mi-sequential-with-interval", %{
          "payload" => %{"items" => [%{"v" => 1}, %{"v" => 2}]}
        })

      process_instance_id = body["processInstanceId"]
      wait_for_process_instance(process_instance_id, 30_000)

      assert_pi_state!(process_instance_id, "finished")
    end

    test "2.3 sequential MI break condition — stops early" do
      {201, _} = http_deploy("mi_sequential_break_condition.bpmn")

      {201, body} =
        http_start("mi-sequential-break-condition", %{
          "payload" => %{
            "items" => Enum.map(1..5, fn index -> %{"value" => index} end)
          }
        })

      process_instance_id = body["processInstanceId"]
      wait_for_process_instance(process_instance_id, @default_timeout)

      assert_pi_state!(process_instance_id, "finished")
    end

    test "2.4 sequential MI user task — finish one at a time" do
      {201, _} = http_deploy("mi_sequential_user_task.bpmn")

      {201, body} =
        http_start("mi-sequential-user-task", %{
          "payload" => %{"items" => [%{"name" => "A"}, %{"name" => "B"}]}
        })

      process_instance_id = body["processInstanceId"]

      {:ok, first_user_task_fni} =
        await_waiting_flow_node_instance(process_instance_id, "user_task",
          timeout: @default_timeout
        )

      {204, _} = http_finish_user_task(first_user_task_fni.id, %{"approved" => true})

      {:ok, second_user_task_fni} =
        await_waiting_flow_node_instance(process_instance_id, "user_task",
          timeout: @default_timeout
        )

      assert second_user_task_fni.id != first_user_task_fni.id
      {204, _} = http_finish_user_task(second_user_task_fni.id, %{"approved" => true})

      wait_for_process_instance(process_instance_id, @default_timeout)
      assert_pi_state!(process_instance_id, "finished")
    end

    test "2.5 sequential MI service task — async completion one at a time" do
      register_test_service_task_handler()

      {201, _} = http_deploy("mi_sequential_service_task.bpmn")

      {201, body} =
        http_start("mi-sequential-service-task", %{
          "payload" => %{"items" => [%{"value" => 1}, %{"value" => 2}]}
        })

      process_instance_id = body["processInstanceId"]

      {:ok, first_service_task_fni} =
        await_waiting_flow_node_instance(process_instance_id, "service_task",
          timeout: @default_timeout
        )

      :ok = finish_async_service_task(first_service_task_fni.id, %{"done" => true})

      {:ok, second_service_task_fni} =
        await_waiting_flow_node_instance(process_instance_id, "service_task",
          timeout: @default_timeout
        )

      assert second_service_task_fni.id != first_service_task_fni.id
      :ok = finish_async_service_task(second_service_task_fni.id, %{"done" => true})

      wait_for_process_instance(process_instance_id, @default_timeout)
      assert_pi_state!(process_instance_id, "finished")
    end

    test "2.6 sequential MI subprocess" do
      {201, _} = http_deploy("mi_sequential_subprocess.bpmn")

      {201, body} =
        http_start("mi-sequential-subprocess", %{
          "payload" => %{"items" => [%{"value" => 1}, %{"value" => 2}]}
        })

      process_instance_id = body["processInstanceId"]
      wait_for_process_instance(process_instance_id, @default_timeout)

      assert_pi_state!(process_instance_id, "finished")
    end

    test "2.7 sequential MI call activity" do
      {201, _} = http_deploy("mi_sequential_ca_child.bpmn")
      {201, _} = http_deploy("mi_sequential_call_activity.bpmn")

      {201, body} =
        http_start("mi-sequential-call-activity", %{
          "payload" => %{"items" => [%{"value" => 1}, %{"value" => 2}]}
        })

      process_instance_id = body["processInstanceId"]
      wait_for_process_instance(process_instance_id, @default_timeout)

      assert_pi_state!(process_instance_id, "finished")
    end
  end

  # ===================================================================
  # Section 3: Edge Cases
  # ===================================================================

  describe "Section 3 — edge cases" do
    test "3.1 empty collection — MI completes immediately with zero iterations",
         %{collector: collector} do
      {201, _} = http_deploy("mi_empty_collection.bpmn")

      {201, body} =
        http_start("mi-empty-collection", %{
          "payload" => %{"items" => []}
        })

      process_instance_id = body["processInstanceId"]
      wait_for_process_instance(process_instance_id, @default_timeout)

      assert_pi_state!(process_instance_id, "finished")

      events = EventCollector.get_events(collector)

      multi_instance_completed = Enum.find(events, &match?(%Event.MultiInstanceCompleted{}, &1))
      assert multi_instance_completed != nil
      assert multi_instance_completed.completed_iterations == 0
    end

    test "3.2 max iterations cap — only first N items processed" do
      {201, _} = http_deploy("mi_max_iterations_cap.bpmn")

      {201, body} =
        http_start("mi-max-iterations-cap", %{
          "payload" => %{
            "items" => Enum.map(1..10, fn index -> %{"value" => index} end)
          }
        })

      process_instance_id = body["processInstanceId"]
      wait_for_process_instance(process_instance_id, @default_timeout)

      assert_pi_state!(process_instance_id, "finished")
    end
  end

  # ===================================================================
  # Section 4: Error Handling
  # ===================================================================

  describe "Section 4 — error handling" do
    test "4.1 parallel MI one fatal — PI ends in fatal" do
      {201, _} = http_deploy("mi_parallel_one_fatal.bpmn")

      {201, body} =
        http_start("mi-parallel-one-fatal", %{
          "payload" => %{"items" => [%{"fail" => false}, %{"fail" => true}, %{"fail" => false}]}
        })

      process_instance_id = body["processInstanceId"]

      {:ok, _} =
        await_process_instance_state(process_instance_id, "fatal",
          timeout: @default_timeout
        )

      assert_pi_state!(process_instance_id, "fatal")
    end

    test "4.2 sequential MI fatal — loop stops" do
      {201, _} = http_deploy("mi_sequential_fatal.bpmn")

      {201, body} =
        http_start("mi-sequential-fatal", %{
          "payload" => %{"items" => [%{"fail" => true}]}
        })

      process_instance_id = body["processInstanceId"]

      {:ok, _} =
        await_process_instance_state(process_instance_id, "fatal",
          timeout: @default_timeout
        )

      assert_pi_state!(process_instance_id, "fatal")
    end

    test "4.3 parallel MI error boundary catches iteration error" do
      {201, _} = http_deploy("mi_parallel_error_boundary.bpmn")

      {201, body} =
        http_start("mi-parallel-error-boundary", %{
          "payload" => %{"items" => [%{"fail" => true}]}
        })

      process_instance_id = body["processInstanceId"]
      wait_for_process_instance(process_instance_id, @default_timeout)

      assert_pi_state!(process_instance_id, "finished")
    end
  end

  # ===================================================================
  # Section 5: Nested MI
  # ===================================================================

  describe "Section 5 — nested MI" do
    test "5.1 nested parallel in sequential" do
      {201, _} = http_deploy("mi_nested_parallel_in_sequential.bpmn")

      {201, body} =
        http_start("mi-nested-parallel-in-sequential", %{
          "payload" => %{
            "items" => [
              [1, 2],
              [3, 4]
            ]
          }
        })

      process_instance_id = body["processInstanceId"]
      wait_for_process_instance(process_instance_id, 30_000)

      assert_pi_state!(process_instance_id, "finished")
    end

    test "5.2 call activity child with MI inside" do
      {201, _} = http_deploy("mi_nested_ca_mi_child.bpmn")
      {201, _} = http_deploy("mi_nested_ca_with_mi_child.bpmn")

      {201, body} =
        http_start("mi-nested-ca-with-mi-child", %{
          "payload" => %{"items" => [%{"orderId" => 1}, %{"orderId" => 2}]}
        })

      process_instance_id = body["processInstanceId"]
      wait_for_process_instance(process_instance_id, 30_000)

      assert_pi_state!(process_instance_id, "finished")
    end
  end

  # ===================================================================
  # Section 6: MI Events on FNIs
  # ===================================================================

  describe "Section 6 — MI fields on FNI events" do
    test "6.1 iteration FNI events carry multi_instance_id and iteration_index",
         %{collector: collector} do
      {201, _} = http_deploy("mi_parallel_script_task.bpmn")

      {201, body} =
        http_start("mi-parallel-script-task", %{
          "payload" => %{"items" => [%{"value" => 1}, %{"value" => 2}]}
        })

      process_instance_id = body["processInstanceId"]
      wait_for_process_instance(process_instance_id, @default_timeout)

      events = EventCollector.get_events(collector)

      iteration_started_events =
        Enum.filter(events, fn
          %Event.FlowNodeInstanceStarted{multi_instance_id: multi_instance_id}
          when multi_instance_id != nil ->
            true

          _ ->
            false
        end)

      assert length(iteration_started_events) == 2

      for event <- iteration_started_events do
        assert event.multi_instance_id != nil
        assert event.iteration_index != nil
        assert event.iteration_index in [0, 1]
      end
    end

    test "6.2 MultiInstanceStarted and MultiInstanceCompleted events are emitted",
         %{collector: collector} do
      {201, _} = http_deploy("mi_sequential_script_task.bpmn")

      {201, body} =
        http_start("mi-sequential-script-task", %{
          "payload" => %{"items" => [%{"value" => 1}, %{"value" => 2}, %{"value" => 3}]}
        })

      process_instance_id = body["processInstanceId"]
      wait_for_process_instance(process_instance_id, @default_timeout)

      events = EventCollector.get_events(collector)

      multi_instance_started = Enum.find(events, &match?(%Event.MultiInstanceStarted{}, &1))
      assert multi_instance_started != nil
      assert multi_instance_started.process_instance_id == process_instance_id
      assert multi_instance_started.loop_type == "sequential_mi"
      assert multi_instance_started.total_iterations == 3

      multi_instance_completed = Enum.find(events, &match?(%Event.MultiInstanceCompleted{}, &1))
      assert multi_instance_completed != nil
      assert multi_instance_completed.process_instance_id == process_instance_id
      assert multi_instance_completed.completed_iterations == 3
      assert multi_instance_completed.early_break == false
    end
  end

  # ===================================================================
  # Section 7: Boundary Events on MI Activities
  # ===================================================================

  describe "Section 7 — boundary events on MI activities" do
    test "7.1 timer boundary on parallel MI user task — fires on timeout" do
      {201, _} = http_deploy("mi_parallel_timer_boundary.bpmn")

      {201, body} =
        http_start("mi-parallel-timer-boundary", %{
          "payload" => %{"items" => [%{"name" => "A"}, %{"name" => "B"}]}
        })

      process_instance_id = body["processInstanceId"]

      waiting_user_task_fnis =
        await_multiple_waiting_flow_node_instances(
          process_instance_id,
          "user_task",
          2,
          timeout: @default_timeout
        )

      assert length(waiting_user_task_fnis) == 2

      boundary_fni =
        poll_fni_state(process_instance_id, "boundary_event", "waiting", @default_timeout)

      assert boundary_fni != nil

      {200, _} = http_trigger_timer_event(boundary_fni.id)

      wait_for_process_instance(process_instance_id, @default_timeout)

      assert_pi_state!(process_instance_id, "finished")

      end_timeout_fni = find_fni_by_flow_node_id(process_instance_id, "End_Timeout")
      assert end_timeout_fni != nil
      assert end_timeout_fni.state == "finished"
    end
  end

  # ===================================================================
  # Section 8: Resume (Persistence Round-Trip)
  # ===================================================================

  describe "Section 8 — resume (persistence round-trip)" do
    test "8.1 parallel MI user task — resume after persistence" do
      {201, _} = http_deploy("mi_parallel_resume.bpmn")

      {201, body} =
        http_start("mi-parallel-resume", %{
          "payload" => %{"items" => [%{"name" => "A"}, %{"name" => "B"}]}
        })

      process_instance_id = body["processInstanceId"]

      waiting_user_task_fnis =
        await_multiple_waiting_flow_node_instances(
          process_instance_id,
          "user_task",
          2,
          timeout: @default_timeout
        )

      assert_pi_state!(process_instance_id, "running")

      for flow_node_instance <- waiting_user_task_fnis do
        assert flow_node_instance.state == "waiting"
      end

      for flow_node_instance <- waiting_user_task_fnis do
        {204, _} = http_finish_user_task(flow_node_instance.id, %{"approved" => true})
      end

      wait_for_process_instance(process_instance_id, @default_timeout)

      assert_pi_state!(process_instance_id, "finished")
      assert_all_fnis_terminal!(process_instance_id)
    end
  end

  # ===================================================================
  # Section 9: Retry
  # ===================================================================

  describe "Section 9 — retry" do
    test "9.1 retry whole MI after fatal" do
      {201, _} = http_deploy("mi_retry_whole.bpmn")

      {201, body} =
        http_start("mi-retry-whole", %{
          "payload" => %{"items" => ["good", "fatal", "good"]}
        })

      process_instance_id = body["processInstanceId"]

      {:ok, _} =
        await_process_instance_state(process_instance_id, "fatal",
          timeout: @default_timeout
        )

      assert_pi_state!(process_instance_id, "fatal")

      {204, nil} =
        http_retry_process_instance(process_instance_id, %{})

      poll_pi_alive(process_instance_id, @default_timeout)

      {:ok, _} =
        await_process_instance_state(process_instance_id, "fatal",
          timeout: @default_timeout
        )
    end
  end

  # -------------------------------------------------------------------
  # Private helpers
  # -------------------------------------------------------------------

  defp await_multiple_waiting_flow_node_instances(
         process_instance_id,
         flow_node_type,
         expected_count,
         opts
       ) do
    timeout = Keyword.get(opts, :timeout, 5_000)
    interval = Keyword.get(opts, :poll_interval, 50)
    deadline = System.monotonic_time(:millisecond) + timeout

    do_poll_multiple_waiting(process_instance_id, flow_node_type, expected_count, interval, deadline)
  end

  defp do_poll_multiple_waiting(
         process_instance_id,
         flow_node_type,
         expected_count,
         interval,
         deadline
       ) do
    waiting_flow_node_instances =
      BfwEngine.Persistence.Resources.FlowNodeInstance
      |> Ash.Query.filter(
        process_instance_id == ^process_instance_id and
          flow_node_type == ^flow_node_type and
          state == "waiting"
      )
      |> Ash.read!(authorize?: false)
      |> Enum.reject(fn flow_node_instance ->
        type_properties = flow_node_instance.type_properties || %{}

        Map.get(type_properties, "mi_shell") == true or
          Map.get(type_properties, :mi_shell) == true
      end)

    if length(waiting_flow_node_instances) >= expected_count do
      waiting_flow_node_instances
    else
      if System.monotonic_time(:millisecond) >= deadline do
        raise "Expected #{expected_count} waiting #{flow_node_type} FNIs for PI " <>
                "#{process_instance_id}, but found #{length(waiting_flow_node_instances)} " <>
                "within timeout"
      else
        Process.sleep(interval)

        do_poll_multiple_waiting(
          process_instance_id,
          flow_node_type,
          expected_count,
          interval,
          deadline
        )
      end
    end
  end

  defp register_test_service_task_handler do
    Application.put_env(
      :core_execution,
      :service_task_dispatch,
      BfwEngine.Plugins.RegistryDispatch
    )

    BfwEngine.Plugins.Registry.register_capability(
      "test_mi_plugin",
      :service_task_handler,
      %{implementation: "test", module: BfwEngine.Test.ExamplePlugin.AsyncParkHandler}
    )
  end
end

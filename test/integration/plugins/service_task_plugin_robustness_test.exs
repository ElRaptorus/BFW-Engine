defmodule BfwEngine.Plugins.Integration.ServiceTaskPluginRobustnessTest do
  @moduledoc """
  Service Task and Named Script plugins at their edges: a completion that
  arrives before `handle_enter/3` returned, a raising or exiting handler, an
  async failure caught by an Error Event Subprocess, Multi-Instance shells,
  and the built-in HTTP handler's request lost to an engine restart.
  """
  use BfwEngine.ExecutionCase, async: false

  alias BfwEngine.Execution
  alias BfwEngine.Execution.ResumeRunner
  alias BfwEngine.Plugins.Builtin.HttpServiceTaskHandler
  alias BfwEngine.Plugins.FacadeBuilder
  alias BfwEngine.Plugins.Registry
  alias BfwEngine.Test.ExamplePlugin

  @plugin_name "evil:test_plugin_robustness"

  setup do
    previous_dispatch = Application.fetch_env(:core_execution, :service_task_dispatch)

    Application.put_env(
      :core_execution,
      :service_task_dispatch,
      BfwEngine.Plugins.RegistryDispatch
    )

    facade = FacadeBuilder.build(@plugin_name)
    ExamplePlugin.on_load(facade)

    on_exit(fn ->
      Registry.unregister_plugin_capabilities(@plugin_name)

      case previous_dispatch do
        {:ok, dispatch} -> Application.put_env(:core_execution, :service_task_dispatch, dispatch)
        :error -> Application.delete_env(:core_execution, :service_task_dispatch)
      end
    end)

    {:ok, facade: facade}
  end

  describe "E1: completion before handle_enter returned" do
    setup do
      Process.register(self(), ExamplePlugin.EarlyCompletionHandler)
      :ok
    end

    test "an early finish_async is answered at once and applied once the task is parked" do
      process_instance_id =
        http_deploy_and_start(
          "service_task_early_completion.bpmn",
          "ServiceTaskEarlyCompletion",
          %{
            "payload" => %{"order" => 7}
          }
        )

      assert_receive {:early_completion_result, flow_node_instance_id, :ok}, 5_000

      poll_pi_state(process_instance_id, "finished")
      service_task = find_fni_by_flow_node_id(process_instance_id, "ServiceTask_Early")

      assert service_task.id == flow_node_instance_id
      assert service_task.state == "finished"
      assert service_task.output_token == %{"early" => true, "input" => %{"order" => 7}}
      assert find_fni_by_flow_node_id(process_instance_id, "End_Done").state == "finished"
      assert find_fni_by_flow_node_id(process_instance_id, "End_Failed") == nil

      assert Enum.count(
               fetch_flow_node_instances(process_instance_id),
               &(&1.flow_node_id == "End_Done")
             ) == 1
    end

    test "an early fail_async is applied once the task is parked and reaches the error boundary" do
      process_instance_id =
        http_deploy_and_start(
          "service_task_early_completion.bpmn",
          "ServiceTaskEarlyCompletion",
          %{
            "payload" => %{"fail" => true}
          }
        )

      assert_receive {:early_completion_result, _flow_node_instance_id, :ok}, 5_000

      poll_pi_state(process_instance_id, "finished")
      assert find_fni_by_flow_node_id(process_instance_id, "End_Failed").state == "finished"
      assert find_fni_by_flow_node_id(process_instance_id, "End_Done") == nil
    end

    test "a stored early completion is dropped when the handler returns an error" do
      process_instance_id =
        http_deploy_and_start(
          "service_task_early_completion.bpmn",
          "ServiceTaskEarlyCompletion",
          %{
            "payload" => %{"then_fail" => true}
          }
        )

      assert_receive {:early_completion_result, flow_node_instance_id, :ok}, 5_000

      poll_pi_state(process_instance_id, "fatal")
      service_task = find_fni_by_flow_node_id(process_instance_id, "ServiceTask_Early")
      assert service_task.id == flow_node_instance_id
      assert service_task.state == "fatal"
      assert find_fni_by_flow_node_id(process_instance_id, "End_Done") == nil
    end

    test "an early finish_async that violates the result contract fails the parked task" do
      process_instance_id =
        http_deploy_and_start(
          "service_task_early_completion_contract.bpmn",
          "ServiceTaskEarlyContractFatal"
        )

      assert_receive {:early_completion_result, flow_node_instance_id, :ok}, 5_000

      poll_pi_state(process_instance_id, "fatal")
      service_task = find_fni_by_flow_node_id(process_instance_id, "ServiceTask_Fatal")
      assert service_task.id == flow_node_instance_id
      assert service_task.state == "fatal"
      assert service_task.error_info["error_code"] == "service_task_contract_violation"
      assert find_fni_by_flow_node_id(process_instance_id, "End_Fatal") == nil
    end

    test "an early finish_async that violates the result contract reaches a catch-all error boundary" do
      process_instance_id =
        http_deploy_and_start(
          "service_task_early_completion_contract.bpmn",
          "ServiceTaskEarlyContractBoundary"
        )

      assert_receive {:early_completion_result, _flow_node_instance_id, :ok}, 5_000

      poll_pi_state(process_instance_id, "finished")
      assert find_fni_by_flow_node_id(process_instance_id, "End_Failed").state == "finished"
      assert find_fni_by_flow_node_id(process_instance_id, "End_Done") == nil
    end

    test "a completion from a Task the handler awaits is answered at once and applied after the park" do
      process_instance_id =
        http_deploy_and_start(
          "service_task_early_completion.bpmn",
          "ServiceTaskEarlyCompletion",
          %{
            "payload" => %{"nested" => true}
          }
        )

      assert_receive {:early_completion_result, flow_node_instance_id, :ok}, 3_000

      poll_pi_state(process_instance_id, "finished")
      service_task = find_fni_by_flow_node_id(process_instance_id, "ServiceTask_Early")
      assert service_task.id == flow_node_instance_id
      assert service_task.output_token == %{"early" => true, "input" => %{"nested" => true}}
    end

    test "a second early completion of the same task is rejected" do
      process_instance_id =
        http_deploy_and_start(
          "service_task_early_completion.bpmn",
          "ServiceTaskEarlyCompletion",
          %{
            "payload" => %{"twice" => true}
          }
        )

      assert_receive {:early_completion_result, _flow_node_instance_id,
                      {:ok, {:error, :fni_not_waiting}}},
                     3_000

      poll_pi_state(process_instance_id, "finished")
    end

    test "early completions of parallel Multi-Instance iterations are applied after each park" do
      process_instance_id =
        http_deploy_and_start(
          "mi_parallel_service_task_early_completion.bpmn",
          "MiParallelServiceTaskEarlyCompletion",
          %{"payload" => %{"items" => [1, 2]}}
        )

      assert_receive {:early_completion_result, _first_iteration_id, :ok}, 5_000
      assert_receive {:early_completion_result, _second_iteration_id, :ok}, 5_000

      poll_pi_state(process_instance_id, "finished")

      iterations =
        process_instance_id
        |> fetch_flow_node_instances()
        |> Enum.filter(&(&1.flow_node_id == "ServiceTask_Early" and &1.multi_instance_id != nil))

      assert length(iterations) == 2
      assert Enum.all?(iterations, &(&1.state == "finished" and &1.output_token["early"] == true))
    end

    test "an early finish_async on a Service Task compensation handler is held and applied" do
      process_instance_id =
        http_deploy_and_start(
          "compensation_service_task_early_completion.bpmn",
          "CompensationServiceTaskEarlyCompletion"
        )

      assert_receive {:early_completion_result, flow_node_instance_id, :ok}, 5_000

      handler = poll_fni_state(process_instance_id, "service_task", "finished")

      assert handler.id == flow_node_instance_id
      assert handler.flow_node_id == "ServiceTask_Undo_A"
    end
  end

  describe "E5: a raising or exiting plugin handler (handler_raised)" do
    test "a Named Script exit reaches a catch-all boundary and a Service Task raise a handler_raised boundary" do
      process_instance_id =
        http_deploy_and_start(
          "plugin_handler_raise_boundaries.bpmn",
          "PluginHandlerRaiseBoundaries"
        )

      poll_pi_state(process_instance_id, "finished")

      assert find_fni_by_flow_node_id(process_instance_id, "End_Caught").state == "finished"

      script_error =
        inspect(find_fni_by_flow_node_id(process_instance_id, "ServiceTask_Raise").input_token)

      assert script_error =~ "handler_raised"
      assert script_error =~ "exited (a :deliberate_script_exit tuple)"
      refute script_error =~ "never in a message"

      service_error =
        inspect(find_fni_by_flow_node_id(process_instance_id, "End_Caught").input_token)

      assert service_error =~ "handler_raised"
      assert service_error =~ "deliberate handler failure"
    end

    test "a Service Task raise is caught by a handler_raised Error Event Subprocess start" do
      process_instance_id =
        http_deploy_and_start("plugin_handler_raise_error_esp.bpmn", "PluginHandlerRaiseErrorEsp")

      poll_pi_state(process_instance_id, "finished")

      assert find_fni_by_flow_node_id(process_instance_id, "ServiceTask_Raise").state == "error"
      assert find_fni_by_flow_node_id(process_instance_id, "End_Done") == nil
      assert [_event_subprocess_child] = list_child_process_instance_ids(process_instance_id)
    end
  end

  describe "E4: async failure and Error Event Subprocess starts" do
    test "fail_async is caught by an Error Event Subprocess start like an enter-time error" do
      process_instance_id =
        http_deploy_and_start("service_task_fail_error_esp.bpmn", "ServiceTaskFailErrorEsp")

      poll_pi_state(process_instance_id, "finished")

      assert find_fni_by_flow_node_id(process_instance_id, "ServiceTask_Fail").state == "error"
      assert find_fni_by_flow_node_id(process_instance_id, "End_Done") == nil
      assert [_event_subprocess_child] = list_child_process_instance_ids(process_instance_id)
    end
  end

  describe "an async Service Task used as a compensation handler" do
    test "finish_async lets the Compensate Throw continue" do
      process_instance_id =
        http_deploy_and_start(
          "compensation_service_task_async_handler.bpmn",
          "CompensationServiceTaskAsyncHandler"
        )

      handler = poll_fni_state(process_instance_id, "service_task", "waiting")
      assert :ok = Execution.finish_async_service_task(handler.id, %{"undone" => true})

      poll_pi_state(process_instance_id, "finished")

      assert find_fni_by_flow_node_id(process_instance_id, "Throw_Compensation").state ==
               "finished"

      assert find_fni_by_flow_node_id(process_instance_id, "End_1").state == "finished"
    end

    test "finish_async after an engine restart lets the Compensate Throw continue" do
      process_instance_id =
        http_deploy_and_start(
          "compensation_service_task_async_handler.bpmn",
          "CompensationServiceTaskAsyncHandler"
        )

      handler = poll_fni_state(process_instance_id, "service_task", "waiting")
      assert handler.type_properties["compensation_throw_fni_id"] != nil

      stop_process_instance(process_instance_id)
      {:ok, _resumed_count} = ResumeRunner.resume_all()
      {:ok, _process_instance_pid} = poll_pi_alive(process_instance_id)

      assert :ok = Execution.finish_async_service_task(handler.id, %{"undone" => true})

      poll_pi_state(process_instance_id, "finished")
      assert find_fni_by_flow_node_id(process_instance_id, "End_1").state == "finished"
    end
  end

  describe "a completion reaching a stopping instance" do
    test "is answered engine_shutting_down when the instance stops for a shutdown" do
      process_instance_id =
        http_deploy_and_start("service_task_async_park.bpmn", "ServiceTaskAsyncPark")

      service_task = poll_fni_state(process_instance_id, "service_task", "waiting")
      {:ok, process_instance_pid} = poll_pi_alive(process_instance_id)

      :ok = :sys.suspend(process_instance_pid)
      completion = Task.async(fn -> Execution.finish_async_service_task(service_task.id, %{}) end)
      await_queued_message(process_instance_pid)
      :ok = :sys.terminate(process_instance_pid, :shutdown)

      assert Task.await(completion) == {:error, :engine_shutting_down}
    end
  end

  describe "Multi-Instance shells take no plugin completion" do
    test "fail_async with the shell's id finds no instance; the iteration still completes the task",
         %{facade: facade} do
      _registration =
        facade.register_service_task_handler.("test", ExamplePlugin.AsyncParkHandler)

      process_instance_id =
        http_deploy_and_start("mi_sequential_service_task.bpmn", "mi-sequential-service-task", %{
          "payload" => %{"items" => [%{"value" => 1}]}
        })

      iteration = await_waiting_iteration(process_instance_id)
      shell = find_multi_instance_shell(process_instance_id)

      assert {:error, :process_instance_not_found} =
               Execution.fail_async_service_task(shell.id, "SHELL_FAILURE", "not for shells")

      assert :ok = Execution.finish_async_service_task(iteration.id, %{"done" => true})
      poll_pi_state(process_instance_id, "finished")
    end
  end

  describe "a raising handle_resume" do
    test "fails the task with handler_resume_raised, which its error boundary catches" do
      process_instance_id =
        http_deploy_and_start("service_task_resume_raise.bpmn", "ServiceTaskResumeRaise")

      poll_fni_state(process_instance_id, "service_task", "waiting")

      stop_process_instance(process_instance_id)
      {:ok, _resumed_count} = ResumeRunner.resume_all()

      poll_pi_state(process_instance_id, "finished")
      assert find_fni_by_flow_node_id(process_instance_id, "End_Done") == nil
      caught_token = find_fni_by_flow_node_id(process_instance_id, "End_Failed").input_token
      assert inspect(caught_token) =~ "handler_resume_raised"

      assert inspect(caught_token) =~
               "The handle_resume/2 callback of the plugin handler for implementation 'resume_raising' " <>
                 "of flow node 'ServiceTask_Resume' raised an exception instead of returning a result: " <>
                 "deliberate resume failure"
    end
  end

  describe "handle_resume for a row parked before implementation and mapped_input were stored" do
    test "the implementation comes from the model and the input from the input token" do
      Process.register(self(), ExamplePlugin.AsyncParkHandler)

      process_instance_id =
        http_deploy_and_start("service_task_mapped_park.bpmn", "ServiceTaskMappedPark", %{
          "payload" => %{"amount" => 5}
        })

      service_task = poll_fni_state(process_instance_id, "service_task", "waiting")
      assert service_task.type_properties["mapped_input"] == %{"amount" => 10}

      stop_process_instance(process_instance_id)

      BfwEngine.Persistence.Repo.query!(
        "UPDATE flow_node_instances SET type_properties = type_properties - 'implementation' - 'mapped_input' " <>
          "WHERE id = $1",
        [Ecto.UUID.dump!(service_task.id)]
      )

      {:ok, _resumed_count} = ResumeRunner.resume_all()

      assert_receive {:service_task_resumed, resume_input}, 5_000
      assert resume_input.implementation == "async_park"
      assert resume_input.flow_node_id == "ServiceTask_Park"
      assert resume_input.mapped_input == %{"amount" => 5}
    end
  end

  describe "E2: built-in HTTP handler after an engine restart" do
    setup %{facade: facade} do
      _registration = facade.register_service_task_handler.("http", HttpServiceTaskHandler)
      previous_options = Application.get_env(:engine_plugins, :http_req_options)

      Application.put_env(:engine_plugins, :http_req_options,
        plug: {Req.Test, __MODULE__},
        retry: false
      )

      Req.Test.set_req_test_to_shared()

      on_exit(fn ->
        Req.Test.set_req_test_to_private()

        if previous_options do
          Application.put_env(:engine_plugins, :http_req_options, previous_options)
        else
          Application.delete_env(:engine_plugins, :http_req_options)
        end
      end)

      :ok
    end

    test "a waiting HTTP task is failed with HTTP_INTERRUPTED and its error boundary decides" do
      test_process = self()

      Req.Test.stub(__MODULE__, fn connection ->
        send(test_process, {:http_request_in_flight, self()})

        receive do
          :never -> Plug.Conn.send_resp(connection, 200, "{}")
        end
      end)

      process_instance_id =
        http_deploy_and_start("http_service_task_interrupted.bpmn", "HttpServiceTaskInterrupted")

      assert_receive {:http_request_in_flight, request_process}, 5_000
      poll_fni_state(process_instance_id, "service_task", "waiting")

      stop_process_instance(process_instance_id)
      Process.exit(request_process, :kill)

      {:ok, _resumed_count} = ResumeRunner.resume_all()

      poll_pi_state(process_instance_id, "finished")
      assert find_fni_by_flow_node_id(process_instance_id, "End_Interrupted").state == "finished"
      assert find_fni_by_flow_node_id(process_instance_id, "End_Done") == nil

      caught_token =
        inspect(find_fni_by_flow_node_id(process_instance_id, "End_Interrupted").input_token)

      assert caught_token =~ "HTTP_INTERRUPTED"
      assert caught_token =~ "Call Slow API"
      refute caught_token =~ "slow.test.local"
    end
  end

  defp stop_process_instance(process_instance_id) do
    {:ok, pid} = Execution.lookup_process_instance(process_instance_id)
    monitor_reference = Process.monitor(pid)
    :ok = DynamicSupervisor.terminate_child(BfwEngine.Execution.Supervisor, pid)
    assert_receive {:DOWN, ^monitor_reference, :process, ^pid, _reason}, 5_000
  end

  defp await_waiting_iteration(process_instance_id, attempts \\ 100) do
    case Enum.find(
           fetch_flow_node_instances(process_instance_id),
           &(is_binary(&1.multi_instance_id) and &1.state == "waiting")
         ) do
      nil when attempts > 0 ->
        Process.sleep(50)
        await_waiting_iteration(process_instance_id, attempts - 1)

      iteration ->
        iteration
    end
  end

  defp find_multi_instance_shell(process_instance_id) do
    Enum.find(
      fetch_flow_node_instances(process_instance_id),
      &(&1.flow_node_id == "Task_1" and is_nil(&1.multi_instance_id))
    )
  end

  defp await_queued_message(pid) do
    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, 0} ->
        Process.sleep(5)
        await_queued_message(pid)

      {:message_queue_len, _count} ->
        :ok
    end
  end
end

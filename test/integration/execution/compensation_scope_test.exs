defmodule BfwEngine.Integration.Execution.CompensationScopeTest do
  @moduledoc """
  Which activities a Compensate Throw compensates, live and after an engine
  restart: an activity is compensated at most once, the registry follows
  completion order, and compensating a completed embedded subprocess or
  Multi-Instance activity reaches its inner activities and iterations. Inner
  handlers of a subprocess run in the subprocess's own instance, with its
  Data Objects and lane.
  """
  use BfwEngine.ExecutionCase, async: false

  alias BfwEngine.Execution
  alias BfwEngine.Execution.ResumeRunner
  alias BfwEngine.Plugins.FacadeBuilder
  alias BfwEngine.Plugins.Registry
  alias BfwEngine.Test.EventCollector
  alias BfwEngine.Test.ExamplePlugin
  alias BfwEngine.Types.Event

  describe "G1: an activity is compensated at most once" do
    test "a second Compensate Throw does not run the handler again" do
      process_instance_id =
        http_deploy_and_start("compensation_double_throw.bpmn", "CompensationDoubleThrow")

      {:ok, wait} = await_waiting_fni_by_node_id(process_instance_id, "UT_Wait")
      {204, _} = http_finish_user_task(wait.id, %{})

      assert {:ok, _process_instance} =
               await_process_instance_state(process_instance_id, "finished")

      assert [%{state: "finished"}] = flow_node_instances_for(process_instance_id, "Task_Undo_A")
    end

    test "a Compensate Throw after a restart does not run a handler that ran before it" do
      process_instance_id =
        http_deploy_and_start("compensation_double_throw.bpmn", "CompensationDoubleThrow")

      {:ok, wait} = await_waiting_fni_by_node_id(process_instance_id, "UT_Wait")
      restart_engine(process_instance_id)
      {204, _} = http_finish_user_task(wait.id, %{})

      assert {:ok, _process_instance} =
               await_process_instance_state(process_instance_id, "finished")

      assert [%{state: "finished"}] = flow_node_instances_for(process_instance_id, "Task_Undo_A")
    end

    test "the registry rebuilt after a restart keeps completion order, not start order" do
      process_instance_id =
        http_deploy_and_start("compensation_completion_order.bpmn", "CompensationCompletionOrder")

      {:ok, task_a} = await_waiting_fni_by_node_id(process_instance_id, "UT_A")
      {:ok, task_b} = await_waiting_fni_by_node_id(process_instance_id, "UT_B")
      assert DateTime.compare(task_a.started_at, task_b.started_at) == :lt

      {204, _} = http_finish_user_task(task_b.id, %{})
      {:ok, _task_b} = await_fni_state(process_instance_id, "UT_B", "finished")
      {204, _} = http_finish_user_task(task_a.id, %{})
      {:ok, wait} = await_waiting_fni_by_node_id(process_instance_id, "UT_Wait")

      restart_engine(process_instance_id)
      {204, _} = http_finish_user_task(wait.id, %{})

      assert {:ok, _process_instance} =
               await_process_instance_state(process_instance_id, "finished")

      [undo_a] = flow_node_instances_for(process_instance_id, "Task_Undo_A")
      [undo_b] = flow_node_instances_for(process_instance_id, "Task_Undo_B")

      assert DateTime.compare(undo_a.started_at, undo_b.started_at) == :lt,
             "A completed last, so its handler runs first"
    end
  end

  describe "G2: compensating a completed embedded subprocess" do
    test "compensates its inner activities in its own instance, latest completion first" do
      process_instance_id =
        http_deploy_and_start(
          "compensation_subprocess_propagation.bpmn",
          "CompensationSubprocessPropagation"
        )

      {:ok, _throw} = await_waiting_fni_by_node_id(process_instance_id, "Throw_Comp")
      [child_process_instance_id] = list_child_process_instance_ids(process_instance_id)

      {:ok, undo_flight} =
        await_waiting_fni_by_node_id(child_process_instance_id, "UT_Undo_Flight")

      assert flow_node_instances_for(child_process_instance_id, "UT_Undo_Hotel") == []
      assert flow_node_instances_for(process_instance_id, "UT_Undo_Flight") == []
      [flight] = flow_node_instances_for(child_process_instance_id, "Task_Flight")
      assert undo_flight.type_properties["compensation_for"] == flight.id

      {204, _} = http_finish_user_task(undo_flight.id, %{})

      {:ok, undo_hotel} =
        await_waiting_fni_by_node_id(child_process_instance_id, "UT_Undo_Hotel")

      {204, _} = http_finish_user_task(undo_hotel.id, %{})

      assert {:ok, _process_instance} =
               await_process_instance_state(process_instance_id, "finished")

      assert [%{state: "finished"}] = flow_node_instances_for(process_instance_id, "Throw_Comp")

      assert to_string(fetch_process_instance!(child_process_instance_id).state) == "finished"
    end

    test "continues with the next inner handler after a restart and runs none twice" do
      process_instance_id =
        http_deploy_and_start(
          "compensation_subprocess_propagation.bpmn",
          "CompensationSubprocessPropagation"
        )

      {:ok, _throw} = await_waiting_fni_by_node_id(process_instance_id, "Throw_Comp")
      [child_process_instance_id] = list_child_process_instance_ids(process_instance_id)

      {:ok, undo_flight} =
        await_waiting_fni_by_node_id(child_process_instance_id, "UT_Undo_Flight")

      restart_engine(process_instance_id)
      {:ok, _child_pid} = poll_pi_alive(child_process_instance_id)

      {204, _} = http_finish_user_task(undo_flight.id, %{})

      {:ok, undo_hotel} =
        await_waiting_fni_by_node_id(child_process_instance_id, "UT_Undo_Hotel")

      {204, _} = http_finish_user_task(undo_hotel.id, %{})

      assert {:ok, _process_instance} =
               await_process_instance_state(process_instance_id, "finished")

      undo_flight_id = undo_flight.id

      assert [%{id: ^undo_flight_id, state: "finished"}] =
               flow_node_instances_for(child_process_instance_id, "UT_Undo_Flight")

      assert [%{state: "finished"}] =
               flow_node_instances_for(child_process_instance_id, "UT_Undo_Hotel")
    end
  end

  describe "the scope of an inner compensation handler" do
    test "reads and writes the subprocess's Data Objects and takes its lane, the child stays finished",
         %{collector: collector} do
      process_instance_id =
        http_deploy_and_start(
          "compensation_scope_data_objects.bpmn",
          "CompensationScopeDataObjects"
        )

      assert {:ok, _process_instance} =
               await_process_instance_state(process_instance_id, "finished")

      [child_process_instance_id] = list_child_process_instance_ids(process_instance_id)

      assert flow_node_instances_for(process_instance_id, "Task_Undo_Book") == []

      assert [%{state: "finished", lane_name: "booking"} = handler] =
               flow_node_instances_for(child_process_instance_id, "Task_Undo_Book")

      [throw] = flow_node_instances_for(process_instance_id, "Throw_Comp")
      assert handler.type_properties["compensation_throw_fni_id"] == throw.id

      inner_status = fetch_data_object(child_process_instance_id, "DO_Status")
      assert inner_status.value["phase"] == "undone"
      assert inner_status.value["seen"] == "booked"
      assert fetch_data_object(process_instance_id, "DO_Status").value["phase"] == "outer"

      assert to_string(fetch_process_instance!(child_process_instance_id).state) == "finished"

      child_state_changes =
        collector
        |> EventCollector.get_events()
        |> Enum.filter(
          &match?(
            %Event.ProcessInstanceStateChanged{process_instance_id: ^child_process_instance_id},
            &1
          )
        )

      assert [%{new_state: finished_state}] =
               Enum.filter(child_state_changes, &(to_string(&1.old_state) == "running"))

      assert to_string(finished_state) == "finished"
      refute Enum.any?(child_state_changes, &(to_string(&1.old_state) == "finished"))
    end

    test "a handler of a subprocess inside a subprocess runs in the innermost instance" do
      process_instance_id =
        http_deploy_and_start("compensation_scope_nested.bpmn", "CompensationScopeNested")

      {:ok, throw} = await_waiting_fni_by_node_id(process_instance_id, "Throw_Comp")
      [child_process_instance_id] = list_child_process_instance_ids(process_instance_id)

      [grandchild_process_instance_id] =
        list_child_process_instance_ids(child_process_instance_id)

      {:ok, undo_book} =
        await_waiting_fni_by_node_id(grandchild_process_instance_id, "UT_Undo_Book")

      assert undo_book.type_properties["compensation_throw_fni_id"] == throw.id
      assert flow_node_instances_for(child_process_instance_id, "UT_Undo_Book") == []

      {204, _} = http_finish_user_task(undo_book.id, %{})

      assert {:ok, _process_instance} =
               await_process_instance_state(process_instance_id, "finished")

      for scope_instance_id <- [child_process_instance_id, grandchild_process_instance_id] do
        assert to_string(fetch_process_instance!(scope_instance_id).state) == "finished"
      end
    end

    test "each iteration of a Multi-Instance subprocess is compensated in its own instance, latest first" do
      process_instance_id =
        http_deploy_and_start(
          "compensation_scope_multi_instance_subprocess.bpmn",
          "CompensationScopeMultiInstanceSubprocess",
          %{"payload" => %{"items" => ["a", "b", "c"]}}
        )

      assert {:ok, _process_instance} =
               await_process_instance_state(process_instance_id, "finished")

      iteration_child_ids =
        process_instance_id
        |> flow_node_instances_for("SubProcess_Items")
        |> Enum.filter(&(&1.iteration_index != nil))
        |> Enum.sort_by(& &1.iteration_index)
        |> Enum.map(& &1.type_properties["child_process_instance_id"])

      assert length(iteration_child_ids) == 3
      assert Enum.all?(iteration_child_ids, &is_binary/1)
      assert length(Enum.uniq(iteration_child_ids)) == 3

      handlers =
        Enum.flat_map(iteration_child_ids, fn child_process_instance_id ->
          assert [handler] = flow_node_instances_for(child_process_instance_id, "Task_Undo_Item")
          [handler]
        end)

      handled_items =
        handlers
        |> Enum.sort_by(& &1.started_at, DateTime)
        |> Enum.map(& &1.input_token["processed"])

      assert handled_items == ["c", "b", "a"]
      assert flow_node_instances_for(process_instance_id, "Task_Undo_Item") == []
    end

    test "a Cancel End counts the handlers that ran inside a compensated subprocess",
         %{collector: collector} do
      process_instance_id =
        http_deploy_and_start(
          "compensation_scope_transaction_cancel.bpmn",
          "CompensationScopeTransactionCancel"
        )

      assert {:ok, _process_instance} =
               await_process_instance_state(process_instance_id, "finished")

      [transaction_id] = list_child_process_instance_ids(process_instance_id)
      [_inner_id, _plain_id] = inner_ids = list_child_process_instance_ids(transaction_id)

      assert [%{state: "finished"}] = flow_node_instances_for(transaction_id, "Task_Undo_B")

      assert [%{state: "finished"}] =
               Enum.flat_map(inner_ids, &flow_node_instances_for(&1, "Task_Undo_A"))

      transaction_cancelled =
        collector
        |> EventCollector.get_events()
        |> Enum.find(&match?(%Event.TransactionCancelled{}, &1))

      assert transaction_cancelled.compensation_handler_count == 2
    end

    test "an activityRef naming a subprocess without a handler compensates its inside only" do
      process_instance_id =
        http_deploy_and_start(
          "compensation_scope_activity_ref.bpmn",
          "CompensationScopeActivityRef"
        )

      assert {:ok, _process_instance} =
               await_process_instance_state(process_instance_id, "finished")

      [child_process_instance_id] = list_child_process_instance_ids(process_instance_id)

      assert [%{state: "finished"}] =
               flow_node_instances_for(child_process_instance_id, "Task_Undo_Hotel")

      assert flow_node_instances_for(process_instance_id, "Task_Undo_Other") == []
    end

    test "an activity the subprocess compensated itself is not compensated again" do
      process_instance_id =
        http_deploy_and_start(
          "compensation_scope_already_compensated.bpmn",
          "CompensationScopeAlreadyCompensated"
        )

      assert {:ok, _process_instance} =
               await_process_instance_state(process_instance_id, "finished")

      [child_process_instance_id] = list_child_process_instance_ids(process_instance_id)
      [inner_throw] = flow_node_instances_for(child_process_instance_id, "Throw_Inner")

      assert [%{state: "finished"} = handler] =
               flow_node_instances_for(child_process_instance_id, "Task_Undo_Hotel")

      assert handler.type_properties["compensation_throw_fni_id"] == inner_throw.id
    end

    test "aborting the requester aborts the waiting inner handler, the child stays finished" do
      process_instance_id =
        http_deploy_and_start(
          "compensation_subprocess_propagation.bpmn",
          "CompensationSubprocessPropagation"
        )

      {:ok, _throw} = await_waiting_fni_by_node_id(process_instance_id, "Throw_Comp")
      [child_process_instance_id] = list_child_process_instance_ids(process_instance_id)

      {:ok, undo_flight} =
        await_waiting_fni_by_node_id(child_process_instance_id, "UT_Undo_Flight")

      {204, _} =
        http_abort_process_instance(process_instance_id, "test_abort", %{
          "abort_process_instance" => "all"
        })

      assert {:ok, _process_instance} =
               await_process_instance_state(process_instance_id, "aborted")

      undo_flight_id = undo_flight.id

      assert {:ok, %{id: ^undo_flight_id}} =
               await_fni_state(child_process_instance_id, "UT_Undo_Flight", "aborted")

      assert to_string(fetch_process_instance!(child_process_instance_id).state) == "finished"
    end

    test "a Terminate End in another branch aborts the waiting inner handler" do
      process_instance_id =
        http_deploy_and_start("compensation_scope_terminate.bpmn", "CompensationScopeTerminate")

      {:ok, _throw} = await_waiting_fni_by_node_id(process_instance_id, "Throw_Comp")
      {:ok, stop} = await_waiting_fni_by_node_id(process_instance_id, "UT_Stop")

      child_process_instance_id =
        process_instance_id
        |> flow_node_instances_for("SubProcess_Booking")
        |> then(fn [shell] -> shell.type_properties["child_process_instance_id"] end)

      {:ok, undo_book} = await_waiting_fni_by_node_id(child_process_instance_id, "UT_Undo_Book")

      {204, _} = http_finish_user_task(stop.id, %{})

      assert {:ok, _process_instance} =
               await_process_instance_state(process_instance_id, "finished")

      undo_book_id = undo_book.id

      assert {:ok, %{id: ^undo_book_id}} =
               await_fni_state(child_process_instance_id, "UT_Undo_Book", "aborted")

      assert [%{state: "interrupted"}] =
               flow_node_instances_for(process_instance_id, "Throw_Comp")

      assert to_string(fetch_process_instance!(child_process_instance_id).state) == "finished"
    end
  end

  describe "a failing inner compensation handler" do
    setup do
      previous_dispatch = Application.fetch_env(:core_execution, :service_task_dispatch)

      Application.put_env(
        :core_execution,
        :service_task_dispatch,
        BfwEngine.Plugins.RegistryDispatch
      )

      plugin_name = "evil:compensation_scope_test"
      ExamplePlugin.on_load(FacadeBuilder.build(plugin_name))

      on_exit(fn ->
        Registry.unregister_plugin_capabilities(plugin_name)

        case previous_dispatch do
          {:ok, dispatch} ->
            Application.put_env(:core_execution, :service_task_dispatch, dispatch)

          :error ->
            Application.delete_env(:core_execution, :service_task_dispatch)
        end
      end)
    end

    test "fatals the requester with compensation_scope_failed; a retry runs the handler once more" do
      process_instance_id =
        http_deploy_and_start(
          "compensation_scope_handler_failure.bpmn",
          "CompensationScopeHandlerFailure"
        )

      {:ok, _throw} = await_waiting_fni_by_node_id(process_instance_id, "Throw_Comp")
      [child_process_instance_id] = list_child_process_instance_ids(process_instance_id)

      {:ok, first_handler} =
        await_waiting_fni_by_node_id(child_process_instance_id, "ST_Undo_Book")

      assert :ok =
               Execution.fail_async_service_task(
                 first_handler.id,
                 "UNDO_FAILED",
                 "the booking could not be undone"
               )

      assert {:ok, fatal_instance} = await_process_instance_state(process_instance_id, "fatal")
      assert fatal_instance.error_info["error_code"] == "compensation_scope_failed"
      assert fatal_instance.error_info["message"] =~ "SubProcess_Booking"
      assert fatal_instance.error_info["message"] =~ child_process_instance_id
      assert to_string(fetch_process_instance!(child_process_instance_id).state) == "finished"

      {204, _} = http_retry_process_instance(process_instance_id)

      {:ok, second_handler} =
        await_waiting_fni_by_node_id(child_process_instance_id, "ST_Undo_Book")

      assert second_handler.id != first_handler.id
      assert :ok = Execution.finish_async_service_task(second_handler.id, %{"undone" => true})

      assert {:ok, _process_instance} =
               await_process_instance_state(process_instance_id, "finished")

      handler_states =
        child_process_instance_id
        |> flow_node_instances_for("ST_Undo_Book")
        |> Enum.map(& &1.state)
        |> Enum.sort()

      assert handler_states == ["fatal", "finished"]
      assert to_string(fetch_process_instance!(child_process_instance_id).state) == "finished"
    end
  end

  describe "G2: compensating a completed Multi-Instance activity" do
    test "runs the handler once per iteration with that iteration's output, latest first" do
      process_instance_id =
        http_deploy_and_start(
          "compensation_multi_instance_iterations.bpmn",
          "CompensationMultiInstanceIterations",
          %{"payload" => %{"items" => ["a", "b", "c"]}}
        )

      assert {:ok, _process_instance} =
               await_process_instance_state(process_instance_id, "finished")

      handled_items =
        process_instance_id
        |> flow_node_instances_for("Task_Undo")
        |> Enum.sort_by(& &1.started_at, DateTime)
        |> Enum.map(& &1.input_token["processed"])

      assert handled_items == ["c", "b", "a"]
    end
  end

  describe "compensating a completed Call Activity" do
    test "without its own handler compensates inside its child instance, nested Call Activities included; with a handler only the handler runs",
         %{collector: collector} do
      process_instance_id =
        http_deploy_and_start("compensation_call_activity.bpmn", "CompensationCallActivity")

      {:ok, _throw} = await_waiting_fni_by_node_id(process_instance_id, "Throw_Comp")
      {:ok, undo_handled} = await_waiting_fni_by_node_id(process_instance_id, "UT_Undo_Handled")
      {204, _} = http_finish_user_task(undo_handled.id, %{})

      booking_instance_id = called_instance_id(process_instance_id, "Call_Booking")
      car_instance_id = called_instance_id(booking_instance_id, "Call_Car")

      {:ok, undo_car} = await_waiting_fni_by_node_id(car_instance_id, "UT_Undo_Car")
      assert flow_node_instances_for(booking_instance_id, "UT_Undo_Hotel") == []
      {204, _} = http_finish_user_task(undo_car.id, %{})

      {:ok, undo_hotel} = await_waiting_fni_by_node_id(booking_instance_id, "UT_Undo_Hotel")
      {204, _} = http_finish_user_task(undo_hotel.id, %{})

      assert {:ok, _process_instance} =
               await_process_instance_state(process_instance_id, "finished")

      handled_instance_id = called_instance_id(process_instance_id, "Call_Handled")
      assert flow_node_instances_for(handled_instance_id, "UT_Undo_Car") == []

      for scope_instance_id <- [booking_instance_id, car_instance_id, handled_instance_id] do
        assert to_string(fetch_process_instance!(scope_instance_id).state) == "finished"
      end

      [%{id: task_car_id}] = flow_node_instances_for(car_instance_id, "Task_Car")

      assert Enum.any?(
               EventCollector.get_events(collector),
               &match?(
                 %Event.ActivityCompensated{
                   process_instance_id: ^car_instance_id,
                   compensated_fni_id: ^task_car_id,
                   handler_activity_id: "UT_Undo_Car"
                 },
                 &1
               )
             )
    end
  end

  describe "a compensated scope with a Compensation Event Subprocess" do
    test "fires that Event Subprocess in place of its inner handlers, for subprocesses and Call Activities" do
      process_instance_id =
        http_deploy_and_start(
          "compensation_scope_event_subprocess.bpmn",
          "CompensationScopeEventSubprocess"
        )

      {:ok, _throw} = await_waiting_fni_by_node_id(process_instance_id, "Throw_Comp")

      car_instance_id = called_instance_id(process_instance_id, "Call_Car")
      plain_instance_id = called_instance_id(process_instance_id, "SubProcess_Plain")
      hotel_instance_id = called_instance_id(process_instance_id, "SubProcess_Hotel")

      for {scope_instance_id, esp_node_id, user_task_node_id} <- [
            {car_instance_id, "ESP_Comp_Car", "UT_Esp_Car"},
            {plain_instance_id, "ESP_Comp_Plain", "UT_Esp_Plain"},
            {hotel_instance_id, "ESP_Comp_Hotel", "UT_Esp_Hotel"}
          ] do
        {:ok, _esp_shell} = await_waiting_fni_by_node_id(scope_instance_id, esp_node_id)
        esp_instance_id = called_instance_id(scope_instance_id, esp_node_id)
        {:ok, user_task} = await_waiting_fni_by_node_id(esp_instance_id, user_task_node_id)
        {204, _} = http_finish_user_task(user_task.id, %{})
      end

      assert {:ok, _process_instance} =
               await_process_instance_state(process_instance_id, "finished")

      assert flow_node_instances_for(hotel_instance_id, "UT_Undo_Hotel") == []

      for scope_instance_id <- [car_instance_id, plain_instance_id, hotel_instance_id] do
        assert to_string(fetch_process_instance!(scope_instance_id).state) == "finished"
      end
    end

    for {outcome, expected_code} <- [{"error", "UNDO_FAILED"}, {"escalation", "UNDO_ESCALATED"}] do
      test "an uncaught #{outcome} end in that Event Subprocess fatals the requester" do
        process_instance_id =
          http_deploy_and_start(
            "compensation_scope_esp_uncaught_end.bpmn",
            "CompensationScopeEspUncaughtEnd"
          )

        {:ok, _throw} = await_waiting_fni_by_node_id(process_instance_id, "Throw_Comp")
        scope_instance_id = called_instance_id(process_instance_id, "SubProcess_Booking")
        {:ok, _esp_shell} = await_waiting_fni_by_node_id(scope_instance_id, "ESP_Comp_Booking")
        esp_instance_id = called_instance_id(scope_instance_id, "ESP_Comp_Booking")
        {:ok, user_task} = await_waiting_fni_by_node_id(esp_instance_id, "UT_Decide")
        {:ok, scope_pid} = Execution.lookup_process_instance(scope_instance_id)
        scope_monitor = Process.monitor(scope_pid)

        {204, _} = http_finish_user_task(user_task.id, %{"outcome" => unquote(outcome)})

        assert {:ok, fatal_instance} = await_process_instance_state(process_instance_id, "fatal")
        assert fatal_instance.error_info["error_code"] == "compensation_scope_failed"
        assert fatal_instance.error_info["message"] =~ unquote(expected_code)
        assert fatal_instance.error_info["message"] =~ "SubProcess_Booking"
        assert_receive {:DOWN, ^scope_monitor, :process, ^scope_pid, :normal}, 5_000
        assert to_string(fetch_process_instance!(scope_instance_id).state) == "finished"
      end
    end
  end

  defp called_instance_id(process_instance_id, call_activity_node_id) do
    [call_activity] = flow_node_instances_for(process_instance_id, call_activity_node_id)
    call_activity.type_properties["child_process_instance_id"]
  end

  defp restart_engine(process_instance_id) do
    BfwEngine.Execution.Supervisor
    |> DynamicSupervisor.which_children()
    |> Enum.each(fn {_id, pid, _type, _modules} ->
      monitor_reference = Process.monitor(pid)
      DynamicSupervisor.terminate_child(BfwEngine.Execution.Supervisor, pid)
      assert_receive {:DOWN, ^monitor_reference, :process, ^pid, _reason}, 5_000
    end)

    {:ok, _resumed_count} = ResumeRunner.resume_all()
    {:ok, _process_instance_pid} = poll_pi_alive(process_instance_id)
  end

  defp await_fni_state(process_instance_id, flow_node_id, state, attempts_left \\ 100) do
    case Enum.find(
           flow_node_instances_for(process_instance_id, flow_node_id),
           &(&1.state == state)
         ) do
      nil when attempts_left > 0 ->
        Process.sleep(50)
        await_fni_state(process_instance_id, flow_node_id, state, attempts_left - 1)

      nil ->
        {:error, :timeout}

      flow_node_instance ->
        {:ok, flow_node_instance}
    end
  end

  defp flow_node_instances_for(process_instance_id, flow_node_id) do
    process_instance_id
    |> fetch_flow_node_instances()
    |> Enum.filter(&(&1.flow_node_id == flow_node_id))
  end
end

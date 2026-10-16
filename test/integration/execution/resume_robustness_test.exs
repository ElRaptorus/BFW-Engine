defmodule BfwEngine.Integration.Execution.ResumeRobustnessTest do
  @moduledoc """
  Regression tests for process instance crash-safety and resume (bug hunt Batch 1).

  Each test stops every running process instance the way an engine restart
  does, optionally edits persisted rows to reproduce a crash window, and
  resumes through `ResumeRunner.resume_all/0`.
  """
  use BfwEngine.ExecutionCase, async: false

  alias BfwEngine.Events.MessageSubscriptions
  alias BfwEngine.Events.SignalSubscriptions
  alias BfwEngine.Execution.FlowNodes.ChildLifecycle
  alias BfwEngine.Execution.Persistence
  alias BfwEngine.Execution.ResumeRunner
  alias BfwEngine.Persistence.ExecutionAdapter
  alias BfwEngine.Persistence.Repo
  alias BfwEngine.Persistence.Resources.FlowNodeInstance
  alias BfwEngine.Test.EventCollector
  alias BfwEngine.Test.ServiceReset
  alias BfwEngine.Types.Event

  @domain BfwEngine.Persistence.Api

  defmodule ChildLookupFailingAdapter do
    @moduledoc false

    for {name, arity} <- Persistence.behaviour_info(:callbacks),
        name != :get_process_instance_for_retry do
      arguments = Macro.generate_arguments(arity, __MODULE__)

      def unquote(name)(unquote_splicing(arguments)),
        do: ExecutionAdapter.unquote(name)(unquote_splicing(arguments))
    end

    def get_process_instance_for_retry(_process_instance_id), do: {:error, :connection_lost}
  end

  describe "A2: successors lost between a finished write and successor creation" do
    test "a finished user task without successor rows continues to its End Event" do
      process_instance_id = http_deploy_and_start("user_task_simple.bpmn", "UserTaskSimple")
      user_task = poll_fni_state(process_instance_id, "user_task", "waiting")

      stop_all_process_instances()
      mark_finished(user_task.id, %{"approved" => true})

      {:ok, 1} = ResumeRunner.resume_all()

      assert {:ok, _process_instance} =
               await_process_instance_state(process_instance_id, "finished")

      assert [%{state: "finished", input_token: %{"approved" => true}}] =
               flow_node_instances_for(process_instance_id, "End_1")
    end

    test "a finished exclusive split re-evaluates its conditions and dispatches only the selected branch" do
      process_instance_id =
        http_deploy_and_start(
          "resume_lost_successor_exclusive.bpmn",
          "ResumeLostSuccessorExclusive"
        )

      {:ok, review} = await_waiting_fni_by_node_id(process_instance_id, "UT_Review")
      {204, _} = http_finish_user_task(review.id, %{"approved" => true})
      {:ok, ship} = await_waiting_fni_by_node_id(process_instance_id, "UT_Ship")

      stop_all_process_instances()
      delete_flow_node_instance(ship.id)

      {:ok, 1} = ResumeRunner.resume_all()

      {:ok, resumed_ship} = await_waiting_fni_by_node_id(process_instance_id, "UT_Ship")
      refute resumed_ship.id == ship.id

      assert [_single_review] = flow_node_instances_for(process_instance_id, "UT_Review")
      assert [_single_gateway] = flow_node_instances_for(process_instance_id, "Gateway_Approved")
      assert [] == flow_node_instances_for(process_instance_id, "End_Rejected")

      {204, _} = http_finish_user_task(resumed_ship.id, %{})

      assert {:ok, _process_instance} =
               await_process_instance_state(process_instance_id, "finished")
    end

    test "a split that no longer selects a branch fatals the instance instead of finishing it" do
      process_instance_id =
        http_deploy_and_start(
          "resume_lost_successor_no_default.bpmn",
          "ResumeLostSuccessorNoDefault"
        )

      {:ok, review} = await_waiting_fni_by_node_id(process_instance_id, "UT_Review")
      {204, _} = http_finish_user_task(review.id, %{"approved" => true})
      {:ok, ship} = await_waiting_fni_by_node_id(process_instance_id, "UT_Ship")

      stop_all_process_instances()
      delete_flow_node_instance(ship.id)

      process_instance_id
      |> flow_node_instances_for("Gateway_Approved")
      |> Enum.each(&mark_finished(&1.id, %{}))

      {:ok, 1} = ResumeRunner.resume_all()

      assert {:ok, process_instance} = await_process_instance_state(process_instance_id, "fatal")
      assert process_instance.error_info["error_code"] == "lost_successor_repair_failed"
      assert process_instance.error_info["message"] =~ "Gateway_Approved"
    end
  end

  describe "D-10.1: boundary rows of a host whose finish was persisted before the restart" do
    test "a waiting error boundary is interrupted and the host's successor is created" do
      assert_finished_host_continues(
        "resume_finished_host_error_boundary.bpmn",
        "ResumeFinishedHostErrorBoundary"
      )
    end

    test "a waiting timer boundary is interrupted and the host's successor is created" do
      assert_finished_host_continues(
        "timer_boundary_resume_host_finished.bpmn",
        "TimerBoundaryResumeHostFinished"
      )
    end
  end

  describe "D-10 9a: a process instance whose Start Event row was never persisted" do
    test "is persisted fatal with resume_failed instead of finishing" do
      process_instance_id = http_deploy_and_start("user_task_simple.bpmn", "UserTaskSimple")
      _user_task = poll_fni_state(process_instance_id, "user_task", "waiting")
      stop_all_process_instances()

      Repo.query!("DELETE FROM flow_node_instances WHERE process_instance_id = $1", [
        Ecto.UUID.dump!(process_instance_id)
      ])

      {:ok, _resumed_count} = ResumeRunner.resume_all()

      process_instance =
        assert_pi_state!(process_instance_id, "fatal", verify_execution_chain: false)

      assert process_instance.error_info["error_code"] == "resume_failed"
      assert process_instance.error_info["message"] =~ "its Start Event was never recorded"
      assert process_instance.error_info["detail"] == "start_event_never_recorded"
    end
  end

  describe "A3/A4/A12: root resume loads every flow node instance" do
    test "the compensation registry survives a restart and snapshots the activity output" do
      process_instance_id =
        http_deploy_and_start("resume_compensation_user_task.bpmn", "ResumeCompensationUserTask")

      {:ok, confirm} = await_waiting_fni_by_node_id(process_instance_id, "UT_Confirm")
      error_boundary = find_fni_by_flow_node_id(process_instance_id, "BE_Error_Confirm")

      stop_all_process_instances()
      {:ok, 1} = ResumeRunner.resume_all()
      {:ok, _process_instance_pid} = poll_pi_alive(process_instance_id)

      assert [] == Registry.lookup(BfwEngine.Execution.Registry, {:fni, error_boundary.id})
      refute rehydrated_event?(error_boundary.id)

      {204, _} = http_finish_user_task(confirm.id, %{})
      {:ok, undo} = await_waiting_fni_by_node_id(process_instance_id, "UT_Undo")
      book = find_fni_by_flow_node_id(process_instance_id, "Task_Book")

      assert book.output_token == %{"booked" => true}
      assert undo.input_token == book.output_token

      {204, _} = http_finish_user_task(undo.id, %{})

      assert {:ok, _process_instance} =
               await_process_instance_state(process_instance_id, "finished")
    end

    test "an Event-Based Gateway winner interrupts its sibling after a restart" do
      process_instance_id =
        http_deploy_and_start("resume_event_based_gateway.bpmn", "ResumeEventBasedGateway")

      {:ok, _catch_a} = await_waiting_fni_by_node_id(process_instance_id, "Catch_A")
      {:ok, catch_b} = await_waiting_fni_by_node_id(process_instance_id, "Catch_B")

      stop_all_process_instances()
      {:ok, 1} = ResumeRunner.resume_all()
      {:ok, _process_instance_pid} = poll_pi_alive(process_instance_id)

      {200, _} = http_trigger_message("resume-ebg-a")

      assert {:ok, _process_instance} =
               await_process_instance_state(process_instance_id, "finished")

      assert [%{state: "interrupted"}] = flow_node_instances_for(process_instance_id, "Catch_B")
      assert [] == flow_node_instances_for(process_instance_id, "End_B")
      assert find_fni_by_flow_node_id(process_instance_id, "Catch_B").id == catch_b.id
    end
  end

  describe "A3: finished Multi-Instance iterations are visible to the resumed shell" do
    test "a sequential multi-instance user task does not re-run finished iterations" do
      process_instance_id =
        http_deploy_and_start("mi_sequential_user_task.bpmn", "mi-sequential-user-task", %{
          "payload" => %{"items" => ["first", "second"]}
        })

      {:ok, first_iteration} = await_waiting_iteration(process_instance_id, 0)
      {204, _} = http_finish_user_task(first_iteration.id, %{"decision" => "first done"})
      {:ok, _second_iteration} = await_waiting_iteration(process_instance_id, 1)

      stop_all_process_instances()
      {:ok, 1} = ResumeRunner.resume_all()
      {:ok, _process_instance_pid} = poll_pi_alive(process_instance_id)

      {:ok, second_iteration} = await_waiting_iteration(process_instance_id, 1)
      {204, _} = http_finish_user_task(second_iteration.id, %{"decision" => "second done"})

      assert {:ok, _process_instance} =
               await_process_instance_state(process_instance_id, "finished")

      iteration_indices =
        process_instance_id
        |> flow_node_instances_for("Task_1")
        |> Enum.reject(&is_nil(&1.iteration_index))
        |> Enum.map(& &1.iteration_index)
        |> Enum.sort()

      assert iteration_indices == [0, 1]
      [end_event] = flow_node_instances_for(process_instance_id, "End_1")
      assert length(end_event.input_token["reviewResults"]) == 2
    end

    test "a sequential multi-instance whose break condition is met by a finished iteration stops" do
      process_instance_id =
        http_deploy_and_start("inbox_sequential_mi_break.bpmn", "InboxSequentialMiBreak", %{
          "payload" => %{"items" => ["first", "second", "third"]}
        })

      {:ok, first_iteration} = await_waiting_iteration(process_instance_id, 0)

      stop_all_process_instances()
      mark_finished(first_iteration.id, %{"decision" => "first done"})
      {:ok, 1} = ResumeRunner.resume_all()

      assert {:ok, _process_instance} =
               await_process_instance_state(process_instance_id, "finished")

      assert [0] ==
               process_instance_id
               |> flow_node_instances_for("Task_1")
               |> Enum.reject(&is_nil(&1.iteration_index))
               |> Enum.map(& &1.iteration_index)
    end
  end

  describe "A5: resumed child process instances keep their root" do
    test "events of a resumed Call Activity child carry the parent as root", %{
      collector: collector
    } do
      {201, _} = http_deploy("call_activity_resume_child.bpmn")

      process_instance_id =
        http_deploy_and_start("call_activity_resume_parent.bpmn", "CallActivityResumeParent")

      [child_process_instance_id] = await_child_process_instance_ids(process_instance_id)
      {:ok, child_task} = await_waiting_fni_by_node_id(child_process_instance_id, "UserTask_1")

      stop_all_process_instances()
      {:ok, 1} = ResumeRunner.resume_all()
      {:ok, _child_pid} = poll_pi_alive(child_process_instance_id)

      {204, _} = http_finish_user_task(child_task.id, %{})

      assert {:ok, _process_instance} =
               await_process_instance_state(process_instance_id, "finished")

      finished_event =
        collector
        |> EventCollector.get_events()
        |> Enum.find(fn event ->
          match?(%Event.FlowNodeInstanceFinished{}, event) and
            event.flow_node_instance_id == child_task.id
        end)

      assert finished_event.process_instance_id == child_process_instance_id
      assert finished_event.root_process_instance_id == process_instance_id
    end
  end

  describe "A6: compensation run state is rebuilt" do
    test "a compensation run parked on a handler user task continues after a restart" do
      process_instance_id =
        http_deploy_and_start("resume_compensation_user_task.bpmn", "ResumeCompensationUserTask")

      {:ok, confirm} = await_waiting_fni_by_node_id(process_instance_id, "UT_Confirm")
      {204, _} = http_finish_user_task(confirm.id, %{})
      {:ok, undo} = await_waiting_fni_by_node_id(process_instance_id, "UT_Undo")

      stop_all_process_instances()
      {:ok, 1} = ResumeRunner.resume_all()
      {:ok, _process_instance_pid} = poll_pi_alive(process_instance_id)

      {204, _} = http_finish_user_task(undo.id, %{})

      assert {:ok, _process_instance} =
               await_process_instance_state(process_instance_id, "finished")

      assert [%{state: "finished"}] = flow_node_instances_for(process_instance_id, "Throw_Comp")
      assert [%{state: "finished"}] = flow_node_instances_for(process_instance_id, "End_1")
    end

    test "a handler that finished before the restart is not run again" do
      process_instance_id =
        http_deploy_and_start(
          "resume_compensation_two_handlers.bpmn",
          "ResumeCompensationTwoHandlers"
        )

      {:ok, undo_hotel} = await_waiting_fni_by_node_id(process_instance_id, "UT_Undo_Hotel")
      {204, _} = http_finish_user_task(undo_hotel.id, %{})
      {:ok, undo_flight} = await_waiting_fni_by_node_id(process_instance_id, "UT_Undo_Flight")

      stop_all_process_instances()
      {:ok, 1} = ResumeRunner.resume_all()
      {:ok, _process_instance_pid} = poll_pi_alive(process_instance_id)

      {204, _} = http_finish_user_task(undo_flight.id, %{})

      assert {:ok, _process_instance} =
               await_process_instance_state(process_instance_id, "finished")

      assert [%{state: "finished"}] = flow_node_instances_for(process_instance_id, "UT_Undo_Hotel")

      assert [%{state: "finished"}] =
               flow_node_instances_for(process_instance_id, "UT_Undo_Flight")
    end
  end

  describe "Error and Escalation End Events whose terminal write was lost" do
    test "an uncaught Error End Event still ends the resumed instance in error" do
      process_instance_id =
        http_deploy_and_start("error_end_event_standalone.bpmn", "ErrorEndStandalone")

      {:ok, _process_instance} = await_process_instance_state(process_instance_id, "error")

      reopen_process_instance(process_instance_id)
      {:ok, 1} = ResumeRunner.resume_all()

      assert {:ok, _process_instance} =
               await_process_instance_state(process_instance_id, "error")
    end

    test "an uncaught Escalation End Event still ends the resumed instance escalated" do
      process_instance_id =
        http_deploy_and_start("escalation_end_event_standalone.bpmn", "EscalationEndStandalone")

      {:ok, _process_instance} = await_process_instance_state(process_instance_id, "escalated")

      reopen_process_instance(process_instance_id)
      {:ok, 1} = ResumeRunner.resume_all()

      assert {:ok, _process_instance} =
               await_process_instance_state(process_instance_id, "escalated")
    end
  end

  describe "A7: resumed ad-hoc children keep their completion options" do
    test "an engine-managed ad-hoc subprocess completes after a restart" do
      process_instance_id =
        http_deploy_and_start("adhoc_with_user_tasks.bpmn", "AdHocWithUserTasks")

      [child_process_instance_id] = await_child_process_instance_ids(process_instance_id)
      {:ok, review} = await_waiting_fni_by_node_id(child_process_instance_id, "UserTask_Review")
      {:ok, approve} = await_waiting_fni_by_node_id(child_process_instance_id, "UserTask_Approve")

      stop_all_process_instances()
      {:ok, 1} = ResumeRunner.resume_all()
      {:ok, _child_pid} = poll_pi_alive(child_process_instance_id)

      {204, _} = http_finish_user_task(review.id, %{})
      {204, _} = http_finish_user_task(approve.id, %{})

      assert {:ok, _child} = await_process_instance_state(child_process_instance_id, "finished")

      assert {:ok, _process_instance} =
               await_process_instance_state(process_instance_id, "finished")
    end

    test "a sequential ad-hoc subprocess activates its next activity when that activation was lost" do
      process_instance_id =
        http_deploy_and_start("adhoc_sequential_user_task.bpmn", "AdHocSequentialUserTask")

      [child_process_instance_id] = await_child_process_instance_ids(process_instance_id)

      {:ok, blocking} =
        await_waiting_fni_by_node_id(child_process_instance_id, "UserTask_Blocking")

      stop_all_process_instances()
      mark_finished(blocking.id, %{"blocking" => "done"})
      {:ok, 1} = ResumeRunner.resume_all()

      assert {:ok, _process_instance} =
               await_process_instance_state(process_instance_id, "finished")

      assert [%{state: "finished"}] =
               flow_node_instances_for(child_process_instance_id, "ScriptTask_After")
    end

    test "a plugin-managed ad-hoc subprocess waits for its completion signal after a restart" do
      process_instance_id =
        http_deploy_and_start("adhoc_plugin_managed.bpmn", "AdHocPluginManaged")

      [child_process_instance_id] = await_child_process_instance_ids(process_instance_id)
      {activate_status, _body} = http_adhoc_activate(child_process_instance_id, "ScriptTask_Plugin_A")
      assert activate_status in [200, 201]

      {:ok, _activity} =
        await_finished_fni_by_node_id(child_process_instance_id, "ScriptTask_Plugin_A")

      stop_all_process_instances()
      {:ok, 1} = ResumeRunner.resume_all()
      {:ok, child_pid} = poll_pi_alive(child_process_instance_id)
      _state = :sys.get_state(child_pid)

      assert_pi_state!(child_process_instance_id, "running")

      {200, _body} = http_adhoc_complete(child_process_instance_id)
      assert {:ok, _child} = await_process_instance_state(child_process_instance_id, "finished")

      assert {:ok, _process_instance} =
               await_process_instance_state(process_instance_id, "finished")
    end
  end

  describe "A8: Event Subprocess triggers that already fired" do
    test "a fired non-interrupting duration timer is not armed again on resume" do
      process_instance_id =
        http_deploy_and_start(
          "event_subprocess_timer_non_interrupting.bpmn",
          "EventSubprocessTimerNonInterrupting"
        )

      {:ok, _shell} =
        await_finished_fni_by_node_id(process_instance_id, "ESP_Timer", timeout: 5_000)

      stop_all_process_instances()
      {:ok, 1} = ResumeRunner.resume_all()
      {:ok, _process_instance_pid} = poll_pi_alive(process_instance_id)

      # The assertion is that nothing fires: wait well past the one-second timer.
      Process.sleep(2_500)
      assert [_single_fire] = flow_node_instances_for(process_instance_id, "ESP_Timer")

      {:ok, main_task} = await_waiting_fni_by_node_id(process_instance_id, "Main_UserTask")
      {204, _} = http_finish_user_task(main_task.id, %{})

      assert {:ok, _process_instance} =
               await_process_instance_state(process_instance_id, "finished")
    end
  end

  describe "A9: a running Event Subprocess child is resumed, not duplicated" do
    test "the persisted ESP child resumes and no second child is spawned" do
      process_instance_id =
        http_deploy_and_start("resume_event_subprocess_child.bpmn", "ResumeEventSubprocessChild")

      {:ok, main_task} = await_waiting_fni_by_node_id(process_instance_id, "Main_UserTask")
      {200, _} = http_trigger_message("resume-esp-escalate")
      [child_process_instance_id] = await_child_process_instance_ids(process_instance_id)
      {:ok, esp_task} = await_waiting_fni_by_node_id(child_process_instance_id, "ESP_UserTask")

      stop_all_process_instances()
      {:ok, 1} = ResumeRunner.resume_all()
      {:ok, _child_pid} = poll_pi_alive(child_process_instance_id)

      {204, _} = http_finish_user_task(esp_task.id, %{})
      assert {:ok, _child} = await_process_instance_state(child_process_instance_id, "finished")
      assert [child_process_instance_id] == list_child_process_instance_ids(process_instance_id)

      {204, _} = http_finish_user_task(main_task.id, %{})

      assert {:ok, _process_instance} =
               await_process_instance_state(process_instance_id, "finished")
    end
  end

  describe "A10: a child spawned afresh on resume is recorded on its shell" do
    test "the subprocess shell points at the new child after its old child vanished" do
      process_instance_id =
        http_deploy_and_start("embedded_subprocess_user_task.bpmn", "EmbeddedSubprocessUserTask")

      [old_child_process_instance_id] = await_child_process_instance_ids(process_instance_id)
      {:ok, _task} = await_waiting_fni_by_node_id(old_child_process_instance_id, "Sub_UserTask")

      stop_all_process_instances()
      delete_process_instance(old_child_process_instance_id)

      {:ok, 1} = ResumeRunner.resume_all()

      [new_child_process_instance_id] = await_child_process_instance_ids(process_instance_id)
      refute new_child_process_instance_id == old_child_process_instance_id

      {:ok, new_task} =
        await_waiting_fni_by_node_id(new_child_process_instance_id, "Sub_UserTask")

      shell = find_fni_by_flow_node_id(process_instance_id, "SubProcess_1")
      assert shell.type_properties["child_process_instance_id"] == new_child_process_instance_id

      {204, _} = http_finish_user_task(new_task.id, %{})

      assert {:ok, _process_instance} =
               await_process_instance_state(process_instance_id, "finished")
    end
  end

  describe "A23: a child row that cannot be read on resume is not mistaken for a deleted child" do
    setup do
      previous_adapter = Application.get_env(:core_execution, :persistence_adapter)
      on_exit(fn -> Application.put_env(:core_execution, :persistence_adapter, previous_adapter) end)
    end

    test "an embedded subprocess shell fatals and spawns no second child" do
      process_instance_id =
        http_deploy_and_start("embedded_subprocess_user_task.bpmn", "EmbeddedSubprocessUserTask")

      [child_process_instance_id] = await_child_process_instance_ids(process_instance_id)
      {:ok, _task} = await_waiting_fni_by_node_id(child_process_instance_id, "Sub_UserTask")

      stop_all_process_instances()
      Application.put_env(:core_execution, :persistence_adapter, ChildLookupFailingAdapter)
      {:ok, 1} = ResumeRunner.resume_all()

      assert_shell_resume_failed(process_instance_id, "SubProcess_1", child_process_instance_id)
    end

    test "an Event Subprocess shell fatals and spawns no second child" do
      process_instance_id =
        http_deploy_and_start("resume_event_subprocess_child.bpmn", "ResumeEventSubprocessChild")

      {:ok, _main_task} = await_waiting_fni_by_node_id(process_instance_id, "Main_UserTask")
      {200, _} = http_trigger_message("resume-esp-escalate")
      [child_process_instance_id] = await_child_process_instance_ids(process_instance_id)
      {:ok, _esp_task} = await_waiting_fni_by_node_id(child_process_instance_id, "ESP_UserTask")

      stop_all_process_instances()
      Application.put_env(:core_execution, :persistence_adapter, ChildLookupFailingAdapter)
      {:ok, 1} = ResumeRunner.resume_all()

      assert_shell_resume_failed(process_instance_id, "ESP_Escalate", child_process_instance_id)
    end

    test "retry of an unknown process instance still answers 404" do
      assert {404, %{"error" => "not_found"}} = http_retry_process_instance(Ash.UUIDv7.generate())
    end

    test "retry answers 503 service_unavailable when the process instance cannot be read" do
      Application.put_env(:core_execution, :persistence_adapter, ChildLookupFailingAdapter)

      assert {503, %{"error" => "service_unavailable"}} =
               http_retry_process_instance(Ash.UUIDv7.generate())
    end
  end

  describe "A11: shell type_properties survive resume and retry" do
    test "resuming an active transaction shell keeps is_transaction" do
      process_instance_id =
        http_deploy_and_start(
          "transaction_with_embedded_subprocess.bpmn",
          "transaction_with_embedded_subprocess"
        )

      [transaction_child_id] = await_child_process_instance_ids(process_instance_id)
      {:ok, _gate} = await_waiting_fni_by_node_id(transaction_child_id, "Tx_CancelGate")
      shell = find_fni_by_flow_node_id(process_instance_id, "Tx_1")
      assert shell.type_properties["is_transaction"] == true

      stop_all_process_instances()
      reset_flow_node_instance(shell.id, "active", shell.type_properties)

      {:ok, 1} = ResumeRunner.resume_all()
      {:ok, resumed_shell} = await_waiting_fni_by_node_id(process_instance_id, "Tx_1")

      assert resumed_shell.type_properties["is_transaction"] == true
      assert resumed_shell.type_properties["child_process_instance_id"] == transaction_child_id
    end

    test "a retry reset keeps the structural markers of subprocess shells" do
      process_instance_id = http_deploy_and_start("user_task_simple.bpmn", "UserTaskSimple")
      user_task = poll_fni_state(process_instance_id, "user_task", "waiting")
      stop_all_process_instances()

      shell_type_properties = %{
        "child_process_instance_id" => Ash.UUIDv7.generate(),
        "is_transaction" => true,
        "is_ad_hoc" => true,
        "error" => true
      }

      shell_id =
        insert_finished_shell(process_instance_id, user_task.id, shell_type_properties)

      {:ok, _reactivation} =
        ExecutionAdapter.execute_retry_reset(process_instance_id, %{
          reset_fni_ids: [{shell_id, "active"}]
        })

      reset_shell = Ash.get!(FlowNodeInstance, shell_id, domain: @domain, authorize?: false)
      assert reset_shell.state == "active"
      assert reset_shell.type_properties == Map.delete(shell_type_properties, "error")
    end
  end

  describe "A15: a child that ended before it was monitored" do
    test "the persisted terminal state decides the outcome, not the :noproc exit" do
      {201, _} = http_deploy("call_activity_resume_child.bpmn")

      process_instance_id =
        http_deploy_and_start("call_activity_resume_parent.bpmn", "CallActivityResumeParent")

      [child_process_instance_id] = await_child_process_instance_ids(process_instance_id)
      {:ok, child_task} = await_waiting_fni_by_node_id(child_process_instance_id, "UserTask_1")
      {204, _} = http_finish_user_task(child_task.id, %{"result" => "done"})
      {:ok, _child} = await_process_instance_state(child_process_instance_id, "finished")

      dead_pid = spawn(fn -> :ok end)
      dead_reference = Process.monitor(dead_pid)
      assert_receive {:DOWN, ^dead_reference, :process, ^dead_pid, _reason}
      reference = Process.monitor(dead_pid)

      assert {:finished, [%{payload: %{"values" => %{"result" => "done"}}}]} =
               ChildLifecycle.await_child_completion(
                 dead_pid,
                 reference,
                 child_process_instance_id,
                 nil,
                 nil,
                 self()
               )
    end

    test "a cancelled child is replayed to the transaction shell's cancel handler" do
      {201, _} = http_deploy("call_activity_resume_child.bpmn")

      process_instance_id =
        http_deploy_and_start("call_activity_resume_parent.bpmn", "CallActivityResumeParent")

      [child_process_instance_id] = await_child_process_instance_ids(process_instance_id)
      {:ok, child_task} = await_waiting_fni_by_node_id(child_process_instance_id, "UserTask_1")
      {204, _} = http_finish_user_task(child_task.id, %{"result" => "done"})
      {:ok, _child} = await_process_instance_state(child_process_instance_id, "finished")

      Repo.query!("UPDATE process_instances SET state = 'cancelled' WHERE id = $1", [
        Ecto.UUID.dump!(child_process_instance_id)
      ])

      cancel_handler = fn
        {:child_pi_cancelled, _child_pid, final_tokens} -> {:handled, {:cancel_seen, final_tokens}}
        _other -> :skip
      end

      assert {:cancel_seen, [_final_token]} =
               await_dead_child(child_process_instance_id, cancel_handler)

      assert {:crashed, :noproc} = await_dead_child(child_process_instance_id, nil)
    end
  end

  describe "A1: orderly shutdown" do
    setup do
      on_exit(fn ->
        _restart_result =
          Supervisor.restart_child(
            BfwEngine.Execution.ApplicationSupervisor,
            BfwEngine.Execution.Supervisor
          )
      end)
    end

    test "prep_stop stops every process instance and leaves its rows for the next resume" do
      process_instance_id = http_deploy_and_start("user_task_simple.bpmn", "UserTaskSimple")
      user_task = poll_fni_state(process_instance_id, "user_task", "waiting")
      {:ok, process_instance_pid} = poll_pi_alive(process_instance_id)

      assert :application_state == BfwEngineWeb.Application.prep_stop(:application_state)

      refute Process.alive?(process_instance_pid)

      assert_pi_state!(process_instance_id, "running", verify_execution_chain: false)
      assert [%{state: "waiting"}] = flow_node_instances_for(process_instance_id, "UserTask_1")

      {:ok, _supervisor} =
        Supervisor.restart_child(
          BfwEngine.Execution.ApplicationSupervisor,
          BfwEngine.Execution.Supervisor
        )

      {:ok, 1} = ResumeRunner.resume_all()
      {204, _} = http_finish_user_task(user_task.id, %{})

      assert {:ok, _process_instance} =
               await_process_instance_state(process_instance_id, "finished")
    end

    test "starts after prep_stop answer engine_shutting_down instead of crashing" do
      {201, _} = http_deploy("user_task_simple.bpmn")
      {201, _} = http_deploy("message_start_event.bpmn")
      MessageSubscriptions.mark_ready()

      assert :application_state == BfwEngineWeb.Application.prep_stop(:application_state)

      assert {503, %{"error" => "engine_shutting_down"}} = http_start("UserTaskSimple")

      assert {200, %{"startedProcessInstanceIds" => []}} =
               http_trigger_message("test-message", %{"data" => "during shutdown"})
    end
  end

  describe "A17: readiness waits for re-registered subscriptions" do
    test "resume_all reports ready only after resumed catch events subscribed again" do
      process_instance_id =
        http_deploy_and_start("resume_event_based_gateway.bpmn", "ResumeEventBasedGateway")

      {:ok, _catch_a} = await_waiting_fni_by_node_id(process_instance_id, "Catch_A")
      {:ok, _catch_b} = await_waiting_fni_by_node_id(process_instance_id, "Catch_B")

      stop_all_process_instances()
      ServiceReset.message_subscriptions()
      in_engine_publisher = Task.async(fn -> MessageSubscriptions.await_ready(10_000) end)
      assert nil == Task.yield(in_engine_publisher, 200)

      {:ok, 1} = ResumeRunner.resume_all()

      assert MessageSubscriptions.has_subscriptions_for_message?("resume-ebg-a")
      assert MessageSubscriptions.has_subscriptions_for_message?("resume-ebg-b")
      assert :ok == Task.await(in_engine_publisher)

      {200, _} = http_trigger_message("resume-ebg-b")

      assert {:ok, _process_instance} =
               await_process_instance_state(process_instance_id, "finished")
    end

    test "await_ready gives up after its timeout while the engine is not ready" do
      ServiceReset.message_subscriptions()
      ServiceReset.signal_subscriptions()

      assert {:error, :timeout} == MessageSubscriptions.await_ready(50)
      assert {:error, :timeout} == SignalSubscriptions.await_ready(50)

      MessageSubscriptions.mark_ready()
      SignalSubscriptions.mark_ready()

      assert :ok == MessageSubscriptions.await_ready(50)
      assert :ok == SignalSubscriptions.await_ready(50)
    end

    test "a subscriptions server restarted after readiness stays ready" do
      MessageSubscriptions.mark_ready()
      SignalSubscriptions.mark_ready()

      for subscriptions <- [MessageSubscriptions, SignalSubscriptions] do
        :ok = Supervisor.terminate_child(BfwEngine.Events.Supervisor, subscriptions)
        {:ok, _pid} = Supervisor.restart_child(BfwEngine.Events.Supervisor, subscriptions)
      end

      assert :ok == MessageSubscriptions.await_ready(50)
      assert :ok == SignalSubscriptions.await_ready(50)
      assert MessageSubscriptions.ready?()
      assert SignalSubscriptions.ready?()
    end
  end

  describe "A13: resume that raises" do
    test "an exception while rebuilding state persists the instance fatal and announces it", %{
      collector: collector
    } do
      process_instance_id = http_deploy_and_start("user_task_simple.bpmn", "UserTaskSimple")
      user_task = poll_fni_state(process_instance_id, "user_task", "waiting")
      stop_all_process_instances()

      Repo.query!(
        "UPDATE flow_node_instances SET flow_node_id = 'Missing_Node', " <>
          "type_properties = '{\"compensation_run\": true}'::jsonb WHERE id = $1",
        [Ecto.UUID.dump!(user_task.id)]
      )

      {:ok, _resumed_count} = ResumeRunner.resume_all()

      process_instance =
        assert_pi_state!(process_instance_id, "fatal", verify_execution_chain: false)

      assert process_instance.error_info["error_code"] == "resume_failed"
      assert process_instance.error_info["message"] =~ "internal error"
      refute Map.has_key?(process_instance.error_info, "detail")

      assert collector
             |> EventCollector.get_events()
             |> Enum.any?(fn event ->
               match?(%Event.ProcessInstanceStateChanged{old_state: :running, new_state: :fatal}, event) and
                 event.process_instance_id == process_instance_id
             end)
    end
  end

  describe "A19: resume does not re-announce the start of a process instance" do
    test "no ProcessInstanceStateChanged nil -> running is published on resume", %{
      collector: collector
    } do
      process_instance_id = http_deploy_and_start("user_task_simple.bpmn", "UserTaskSimple")
      _user_task = poll_fni_state(process_instance_id, "user_task", "waiting")
      stop_all_process_instances()
      events_before_resume = length(EventCollector.get_events(collector))

      {:ok, 1} = ResumeRunner.resume_all()
      {:ok, process_instance_pid} = poll_pi_alive(process_instance_id)
      _state = :sys.get_state(process_instance_pid)

      refute collector
             |> EventCollector.get_events()
             |> Enum.drop(events_before_resume)
             |> Enum.any?(fn event ->
               match?(%Event.ProcessInstanceStateChanged{old_state: nil}, event) and
                 event.process_instance_id == process_instance_id
             end)
    end
  end

  # -------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------

  defp assert_shell_resume_failed(process_instance_id, shell_node_id, child_process_instance_id) do
    _process_instance = poll_pi_state(process_instance_id, "fatal")
    shell = find_fni_by_flow_node_id(process_instance_id, shell_node_id)

    assert shell.state == "fatal"
    assert shell.error_info["error_code"] == "child_resume_failed"
    assert shell.error_info["message"] =~ child_process_instance_id
    assert [child_process_instance_id] == list_child_process_instance_ids(process_instance_id)
  end

  defp assert_finished_host_continues(fixture_name, process_model_id) do
    process_instance_id = http_deploy_and_start(fixture_name, process_model_id)
    first_task = poll_fni_state(process_instance_id, "user_task", "waiting")
    boundary = poll_fni_state(process_instance_id, "boundary_event", "waiting")

    stop_all_process_instances()
    mark_finished(first_task.id, %{})

    {:ok, 1} = ResumeRunner.resume_all()

    {:ok, second_task} = await_waiting_fni_by_node_id(process_instance_id, "Task_Second")
    assert [%{state: "interrupted"}] = flow_node_instances_for(process_instance_id, boundary.flow_node_id)

    {204, _} = http_finish_user_task(second_task.id, %{})

    assert {:ok, _process_instance} =
             await_process_instance_state(process_instance_id, "finished")

    assert [_single_first_task] = flow_node_instances_for(process_instance_id, "Task_First")
  end

  defp stop_all_process_instances do
    BfwEngine.Execution.Supervisor
    |> DynamicSupervisor.which_children()
    |> Enum.each(fn {_id, pid, _type, _modules} ->
      monitor_reference = Process.monitor(pid)
      DynamicSupervisor.terminate_child(BfwEngine.Execution.Supervisor, pid)
      assert_receive {:DOWN, ^monitor_reference, :process, ^pid, _reason}, 5_000
    end)
  end

  defp await_dead_child(child_process_instance_id, extra_message_handler) do
    dead_pid = spawn(fn -> :ok end)
    dead_reference = Process.monitor(dead_pid)
    assert_receive {:DOWN, ^dead_reference, :process, ^dead_pid, _reason}

    ChildLifecycle.await_child_completion(
      dead_pid,
      Process.monitor(dead_pid),
      child_process_instance_id,
      nil,
      nil,
      self(),
      extra_message_handler
    )
  end

  defp flow_node_instances_for(process_instance_id, flow_node_id) do
    process_instance_id
    |> fetch_flow_node_instances()
    |> Enum.filter(&(&1.flow_node_id == flow_node_id))
  end

  defp mark_finished(flow_node_instance_id, output_token) do
    FlowNodeInstance
    |> Ash.get!(flow_node_instance_id, domain: @domain, authorize?: false)
    |> Ash.Changeset.for_update(:update_finished, %{
      state: "finished",
      finished_at: DateTime.utc_now(),
      output_token: output_token
    })
    |> Ash.update!(domain: @domain, authorize?: false)
  end

  defp reset_flow_node_instance(flow_node_instance_id, state, type_properties) do
    FlowNodeInstance
    |> Ash.get!(flow_node_instance_id, domain: @domain, authorize?: false)
    |> Ash.Changeset.for_update(:retry_reset, %{state: state, type_properties: type_properties})
    |> Ash.update!(domain: @domain, authorize?: false)
  end

  defp insert_finished_shell(process_instance_id, previous_flow_node_instance_id, type_properties) do
    shell_id = Ash.UUIDv7.generate()

    {:ok, _shell} =
      Ash.create(
        FlowNodeInstance,
        %{
          id: shell_id,
          process_instance_id: process_instance_id,
          flow_node_id: "SubProcess_Shell",
          flow_node_type: "sub_process",
          state: "active",
          started_at: DateTime.utc_now(),
          previous_flow_node_instance_ids: [previous_flow_node_instance_id],
          type_properties: type_properties
        },
        domain: @domain,
        authorize?: false
      )

    reset_flow_node_instance(shell_id, "fatal", type_properties)
    shell_id
  end

  defp reopen_process_instance(process_instance_id) do
    Repo.query!("UPDATE process_instances SET state = 'running' WHERE id = $1", [
      Ecto.UUID.dump!(process_instance_id)
    ])
  end

  defp delete_flow_node_instance(flow_node_instance_id) do
    Repo.query!("DELETE FROM flow_node_instances WHERE id = $1", [
      Ecto.UUID.dump!(flow_node_instance_id)
    ])
  end

  defp delete_process_instance(process_instance_id) do
    process_instance_id_binary = Ecto.UUID.dump!(process_instance_id)

    Repo.query!("DELETE FROM flow_node_instances WHERE process_instance_id = $1", [
      process_instance_id_binary
    ])

    Repo.query!("DELETE FROM process_instances WHERE id = $1", [process_instance_id_binary])
  end

  defp await_waiting_iteration(process_instance_id, iteration_index, attempts_left \\ 100) do
    process_instance_id
    |> flow_node_instances_for("Task_1")
    |> Enum.find(&(&1.iteration_index == iteration_index and &1.state == "waiting"))
    |> case do
      nil when attempts_left > 0 ->
        Process.sleep(50)
        await_waiting_iteration(process_instance_id, iteration_index, attempts_left - 1)

      nil ->
        {:error, :timeout}

      iteration ->
        {:ok, iteration}
    end
  end

  defp rehydrated_event?(flow_node_instance_id) do
    EventCollector.current()
    |> EventCollector.get_events()
    |> Enum.any?(fn event ->
      match?(%Event.PluginAsyncFlowNodeRehydrated{}, event) and
        event.flow_node_instance_id == flow_node_instance_id
    end)
  end
end

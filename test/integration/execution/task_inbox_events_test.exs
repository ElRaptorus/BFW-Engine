defmodule BfwEngine.Integration.TaskInboxEventsTest do
  @moduledoc """
  Umbrella-level integration tests for the task inbox events
  (`UserTaskCreated`, `UserTaskFinished`) published by
  `BfwEngine.Execution.TaskInboxEvents`.

  Exercises the full HTTP deploy -> start -> interact -> assert lifecycle
  against real PostgreSQL persistence, covering confirming and
  non-confirming Manual Tasks, User Tasks, every withdrawal path that must
  publish exactly one `UserTaskFinished{outcome: :aborted}`, and the
  Multi-Instance per-iteration contract.
  """

  use BfwEngine.ExecutionCase, async: false

  alias BfwEngine.Test.EventCollector
  alias BfwEngine.Types.Event

  @default_timeout 10_000

  defp user_task_created_events(collector, flow_node_id) do
    collector
    |> EventCollector.get_events()
    |> Enum.filter(&match?(%Event.UserTaskCreated{flow_node_id: ^flow_node_id}, &1))
  end

  defp user_task_finished_events(collector, flow_node_id) do
    collector
    |> EventCollector.get_events()
    |> Enum.filter(&match?(%Event.UserTaskFinished{flow_node_id: ^flow_node_id}, &1))
  end

  describe "confirming Manual Task" do
    test "publishes UserTaskCreated(manual_task) then UserTaskFinished(:completed)",
         %{collector: collector} do
      {201, _} = http_deploy("manual_task_confirm.bpmn")
      {201, body} = http_start("ManualTaskConfirm")
      process_instance_id = body["processInstanceId"]

      {:ok, manual_task_fni} =
        await_waiting_flow_node_instance(process_instance_id, "manual_task",
          timeout: @default_timeout
        )

      created_events = user_task_created_events(collector, "ManualTask_1")
      assert length(created_events) == 1
      assert hd(created_events).flow_node_type == :manual_task

      {204, _} = http_confirm_manual_task(manual_task_fni.id)
      wait_for_process_instance(process_instance_id, @default_timeout)
      assert_pi_state!(process_instance_id, "finished")

      finished_events = user_task_finished_events(collector, "ManualTask_1")
      assert length(finished_events) == 1
      assert hd(finished_events).flow_node_type == :manual_task
      assert hd(finished_events).outcome == :completed
    end
  end

  describe "non-confirming Manual Task" do
    test "publishes no task inbox events", %{collector: collector} do
      {201, _} = http_deploy("manual_task_passthrough.bpmn")
      {201, body} = http_start("ManualTaskPassthrough")
      process_instance_id = body["processInstanceId"]

      wait_for_process_instance(process_instance_id, @default_timeout)
      assert_pi_state!(process_instance_id, "finished")

      assert user_task_created_events(collector, "ManualTask_1") == []
      assert user_task_finished_events(collector, "ManualTask_1") == []
    end
  end

  describe "User Task" do
    test "Created and Finished carry flow_node_type :user_task", %{collector: collector} do
      {201, _} = http_deploy("user_task_simple.bpmn")
      {201, body} = http_start("UserTaskSimple")
      process_instance_id = body["processInstanceId"]

      {:ok, user_task_fni} =
        await_waiting_flow_node_instance(process_instance_id, "user_task",
          timeout: @default_timeout
        )

      created_events = user_task_created_events(collector, "UserTask_1")
      assert length(created_events) == 1
      assert hd(created_events).flow_node_type == :user_task

      {204, _} = http_finish_user_task(user_task_fni.id, %{"approved" => true})
      wait_for_process_instance(process_instance_id, @default_timeout)
      assert_pi_state!(process_instance_id, "finished")

      finished_events = user_task_finished_events(collector, "UserTask_1")
      assert length(finished_events) == 1
      assert hd(finished_events).flow_node_type == :user_task
      assert hd(finished_events).outcome == :completed
    end
  end

  describe "withdrawal paths publish UserTaskFinished(:aborted) exactly once" do
    test "explicit cancel via PUT /user-tasks/:id/cancel", %{collector: collector} do
      {201, _} = http_deploy("user_task_simple.bpmn")
      {201, body} = http_start("UserTaskSimple")
      process_instance_id = body["processInstanceId"]

      {:ok, user_task_fni} =
        await_waiting_flow_node_instance(process_instance_id, "user_task",
          timeout: @default_timeout
        )

      {204, _} = http_cancel_user_task(user_task_fni.id, "user_abort")
      wait_for_process_instance(process_instance_id, @default_timeout)
      assert_pi_state!(process_instance_id, "aborted", verify_execution_chain: false)

      finished_events = user_task_finished_events(collector, "UserTask_1")
      assert length(finished_events) == 1
      assert hd(finished_events).outcome == :aborted
    end

    test "interrupting timer boundary event on a waiting User Task", %{collector: collector} do
      {201, _} = http_deploy("timer_boundary_interrupting.bpmn")
      {201, body} = http_start("TimerBoundaryInterrupting")
      process_instance_id = body["processInstanceId"]

      wait_for_process_instance(process_instance_id, @default_timeout)
      assert_pi_state!(process_instance_id, "finished")

      finished_events = user_task_finished_events(collector, "UserTask_1")
      assert length(finished_events) == 1
      assert hd(finished_events).outcome == :aborted
    end

    test "PI abort while a confirming Manual Task is waiting", %{collector: collector} do
      {201, _} = http_deploy("manual_task_confirm.bpmn")
      {201, body} = http_start("ManualTaskConfirm")
      process_instance_id = body["processInstanceId"]

      {:ok, _manual_task_fni} =
        await_waiting_flow_node_instance(process_instance_id, "manual_task",
          timeout: @default_timeout
        )

      {204, _} =
        http_abort_process_instance(process_instance_id, "user_abort", %{
          "abort_process_instance" => "all"
        })

      wait_for_process_instance(process_instance_id, @default_timeout)
      assert_pi_state!(process_instance_id, "aborted", verify_execution_chain: false)

      finished_events = user_task_finished_events(collector, "ManualTask_1")
      assert length(finished_events) == 1
      assert hd(finished_events).outcome == :aborted
    end

    test "Terminate End Event on a sibling parallel branch", %{collector: collector} do
      {201, _} = http_deploy("terminate_end_event_parallel.bpmn")
      {201, body} = http_start("TerminateParallel")
      process_instance_id = body["processInstanceId"]

      wait_for_process_instance(process_instance_id, @default_timeout)
      assert_pi_state!(process_instance_id, "finished")

      finished_events = user_task_finished_events(collector, "UserTask_Wait")
      assert length(finished_events) == 1
      assert hd(finished_events).outcome == :aborted
    end

    test "Error End Event cascade on a concurrent branch", %{collector: collector} do
      {201, _} = http_deploy("error_end_event_concurrent.bpmn")
      {201, body} = http_start("ErrorEndConcurrent")
      process_instance_id = body["processInstanceId"]

      wait_for_process_instance(process_instance_id, @default_timeout)
      assert_pi_state!(process_instance_id, "error")

      finished_events = user_task_finished_events(collector, "UserTask_1")
      assert length(finished_events) == 1
      assert hd(finished_events).outcome == :aborted
    end
  end

  describe "Multi-Instance User Task" do
    test "one Created/Finished pair per iteration, none for the shell",
         %{collector: collector} do
      {201, _} = http_deploy("mi_parallel_user_task.bpmn")

      {201, body} =
        http_start("mi-parallel-user-task", %{
          "payload" => %{"items" => [%{"name" => "A"}, %{"name" => "B"}]}
        })

      process_instance_id = body["processInstanceId"]

      waiting_user_task_fnis =
        await_multiple_waiting_flow_node_instances(process_instance_id, "user_task", 2,
          timeout: @default_timeout
        )

      assert length(user_task_created_events(collector, "Task_1")) == 2

      for flow_node_instance <- waiting_user_task_fnis do
        {204, _} = http_finish_user_task(flow_node_instance.id, %{"approved" => true})
      end

      wait_for_process_instance(process_instance_id, @default_timeout)
      assert_pi_state!(process_instance_id, "finished")

      finished_events = user_task_finished_events(collector, "Task_1")
      assert length(finished_events) == 2
      assert Enum.all?(finished_events, &(&1.outcome == :completed))
      assert Enum.all?(finished_events, &(&1.flow_node_type == :user_task))
    end
  end

  describe "early break withdraws the remaining iteration" do
    test "one completed and one aborted UserTaskFinished, none for the shell",
         %{collector: collector} do
      {201, _} = http_deploy("mi_parallel_user_task_early_break.bpmn")

      {201, body} =
        http_start("mi-parallel-user-task-early-break", %{
          "payload" => %{"items" => [%{"name" => "A"}, %{"name" => "B"}]}
        })

      process_instance_id = body["processInstanceId"]

      [first_iteration | _rest] =
        await_multiple_waiting_flow_node_instances(process_instance_id, "user_task", 2,
          timeout: @default_timeout
        )

      {204, _} = http_finish_user_task(first_iteration.id, %{"approved" => true})

      wait_for_process_instance(process_instance_id, @default_timeout)
      assert_pi_state!(process_instance_id, "finished")

      finished_events =
        collector
        |> EventCollector.get_events()
        |> Enum.filter(&match?(%Event.UserTaskFinished{flow_node_id: "Task_1"}, &1))

      completed = Enum.filter(finished_events, &(&1.outcome == :completed))
      aborted = Enum.filter(finished_events, &(&1.outcome == :aborted))
      assert length(completed) == 1
      assert hd(completed).flow_node_instance_id == first_iteration.id
      assert length(aborted) == 1
      assert hd(aborted).flow_node_instance_id != first_iteration.id

      shell =
        process_instance_id
        |> fetch_flow_node_instances()
        |> Enum.find(&(&1.flow_node_id == "Task_1" and is_nil(&1.iteration_index)))

      assert shell != nil
      refute Enum.any?(finished_events, &(&1.flow_node_instance_id == shell.id))
    end
  end

  describe "Complex Join cancels the waiting user task" do
    test "the cancelled user task has exactly one aborted UserTaskFinished",
         %{collector: collector} do
      process_instance_id =
        http_deploy_and_start(
          "complex_gateway_cancel_region.bpmn",
          "ComplexGatewayCancelRegion",
          %{"payload" => %{"a" => true, "b" => true, "c" => true}}
        )

      {:ok, user_a} =
        await_waiting_fni_by_node_id(process_instance_id, "UserTask_A", timeout: @default_timeout)

      {:ok, user_b} =
        await_waiting_fni_by_node_id(process_instance_id, "UserTask_B", timeout: @default_timeout)

      {:ok, _user_c} =
        await_waiting_fni_by_node_id(process_instance_id, "UserTask_C", timeout: @default_timeout)

      {204, _} = http_finish_user_task(user_a.id, %{"done" => true})
      {204, _} = http_finish_user_task(user_b.id, %{"done" => true})

      wait_for_process_instance(process_instance_id, @default_timeout)
      assert_pi_state!(process_instance_id, "finished")

      cancelled = user_task_finished_events(collector, "UserTask_C")
      assert length(cancelled) == 1
      assert hd(cancelled).outcome == :aborted
    end
  end

  describe "fatal collateral withdraws the waiting user task" do
    test "UserTask_A receives exactly one aborted UserTaskFinished", %{collector: collector} do
      plugin_name = "task_inbox_fatal_collateral"

      :ok =
        BfwEngine.Plugins.Registry.register_capability(
          plugin_name,
          :service_task_handler,
          %{
            implementation: "nonexistent_handler",
            module: BfwEngine.Test.ExamplePlugin.AsyncParkHandler
          }
        )

      on_exit(fn -> BfwEngine.Plugins.Registry.unregister_plugin_capabilities(plugin_name) end)

      process_instance_id =
        http_deploy_and_start(
          "inclusive_gateway_fatal_on_branch.bpmn",
          "InclusiveGatewayFatalOnBranch",
          %{"payload" => %{"a" => true, "b" => true}}
        )

      {:ok, user_task} =
        await_waiting_fni_by_node_id(process_instance_id, "UserTask_A", timeout: @default_timeout)

      {:ok, service_task} =
        await_waiting_fni_by_node_id(process_instance_id, "ServiceTask_Bad",
          timeout: @default_timeout
        )

      assert :ok =
               BfwEngine.Execution.fail_async_service_task(
                 service_task.id,
                 "sibling_fatal",
                 "Sibling branch failed after the user task was waiting."
               )

      wait_for_process_instance(process_instance_id, @default_timeout)
      assert_pi_state!(process_instance_id, "fatal")

      finished_events = user_task_finished_events(collector, "UserTask_A")
      assert length(finished_events) == 1
      assert hd(finished_events).outcome == :aborted
      assert hd(finished_events).flow_node_instance_id == user_task.id
    end
  end

  describe "Cancel End withdraws the waiting user task" do
    test "Tx_UserTask receives exactly one aborted UserTaskFinished", %{collector: collector} do
      {201, _} = http_deploy("transaction_parallel_cancel.bpmn")
      {201, body} = http_start("transaction_parallel_cancel")
      process_instance_id = body["processInstanceId"]

      {:ok, _transaction_child_id} =
        finish_transaction_cancel_gate_after_nested_idle(
          process_instance_id,
          {:on_transaction_child, "Tx_UserTask"}
        )

      wait_for_process_instance(process_instance_id, @default_timeout)
      assert_pi_state!(process_instance_id, "finished")

      finished_events = user_task_finished_events(collector, "Tx_UserTask")
      assert length(finished_events) == 1
      assert hd(finished_events).outcome == :aborted
    end
  end

  describe "remaining withdrawal paths" do
    test "Escalation End interrupts the waiting user task", %{collector: collector} do
      {201, _} = http_deploy("inbox_escalation_end_interrupt.bpmn")
      {201, body} = http_start("InboxEscalationEndInterrupt")
      process_instance_id = body["processInstanceId"]

      {:ok, _user_task} =
        await_waiting_fni_by_node_id(process_instance_id, "UserTask_Wait",
          timeout: @default_timeout
        )

      wait_for_process_instance(process_instance_id, @default_timeout)
      assert_pi_state!(process_instance_id, "escalated", verify_execution_chain: false)

      finished_events = user_task_finished_events(collector, "UserTask_Wait")
      assert length(finished_events) == 1
      assert hd(finished_events).outcome == :aborted
    end

    test "an interrupting Event Subprocess withdraws the waiting user task", %{
      collector: collector
    } do
      {201, _} = http_deploy("event_subprocess_timer_interrupting.bpmn")
      {201, body} = http_start("EventSubprocessTimerInterrupting")
      process_instance_id = body["processInstanceId"]

      wait_for_process_instance(process_instance_id, @default_timeout)
      assert_pi_state!(process_instance_id, "finished")

      finished_events = user_task_finished_events(collector, "Main_UserTask")
      assert length(finished_events) == 1
      assert hd(finished_events).outcome == :aborted
    end

    test "ad-hoc cancelRemainingInstances withdraws the other user task", %{collector: collector} do
      {201, _} = http_deploy("inbox_adhoc_cancel_remaining.bpmn")
      {201, body} = http_start("InboxAdhocCancelRemaining")
      process_instance_id = body["processInstanceId"]

      [child_process_instance_id] = await_child_process_instance_ids(process_instance_id)

      {:ok, review} =
        await_waiting_fni_by_node_id(child_process_instance_id, "UserTask_Review",
          timeout: @default_timeout
        )

      {:ok, _approve} =
        await_waiting_fni_by_node_id(child_process_instance_id, "UserTask_Approve",
          timeout: @default_timeout
        )

      {204, _} = http_finish_user_task(review.id, %{"done" => true})
      wait_for_process_instance(process_instance_id, @default_timeout)
      assert_pi_state!(process_instance_id, "finished")

      approve_events = user_task_finished_events(collector, "UserTask_Approve")
      assert length(approve_events) == 1
      assert hd(approve_events).outcome == :aborted
    end

    test "an error cascade inside a child process instance withdraws its user task",
         %{collector: collector} do
      {201, _} = http_deploy("error_end_event_concurrent.bpmn")
      {201, _} = http_deploy("inbox_error_cascade_parent.bpmn")
      {201, body} = http_start("InboxErrorCascadeParent")
      process_instance_id = body["processInstanceId"]

      wait_for_process_instance(process_instance_id, @default_timeout)

      finished_events = user_task_finished_events(collector, "UserTask_1")
      assert length(finished_events) == 1
      assert hd(finished_events).outcome == :aborted
    end

    test "aborting the parent withdraws the child user task", %{collector: collector} do
      {201, _} = http_deploy("ca_cascade_waiting_child.bpmn")
      {201, _} = http_deploy("ca_cascade_simple_parent.bpmn")
      {201, body} = http_start("CaCascadeSimpleParent")
      process_instance_id = body["processInstanceId"]

      [child_process_instance_id] = await_child_process_instance_ids(process_instance_id)

      {:ok, _user_task} =
        await_waiting_fni_by_node_id(child_process_instance_id, "UserTask_1",
          timeout: @default_timeout
        )

      {204, _} =
        http_abort_process_instance(process_instance_id, "user_abort", %{
          "abort_process_instance" => "all"
        })

      wait_for_process_instance(process_instance_id, @default_timeout)
      wait_for_process_instance(child_process_instance_id, @default_timeout)

      finished_events = user_task_finished_events(collector, "UserTask_1")
      assert length(finished_events) == 1
      assert hd(finished_events).outcome == :aborted
    end

    test "sequential multi-instance break finishes after one iteration", %{collector: collector} do
      {201, _} = http_deploy("inbox_sequential_mi_break.bpmn")

      {201, body} =
        http_start("InboxSequentialMiBreak", %{
          "payload" => %{"items" => [%{"name" => "A"}, %{"name" => "B"}]}
        })

      process_instance_id = body["processInstanceId"]

      {:ok, first_iteration} =
        await_waiting_flow_node_instance(process_instance_id, "user_task",
          timeout: @default_timeout
        )

      {204, _} = http_finish_user_task(first_iteration.id, %{"decision" => "stop"})
      wait_for_process_instance(process_instance_id, @default_timeout)
      assert_pi_state!(process_instance_id, "finished")

      finished_events = user_task_finished_events(collector, "Task_1")
      assert length(finished_events) == 1
      assert hd(finished_events).outcome == :completed
    end

    test "an interrupting timer boundary withdraws a confirming manual task",
         %{collector: collector} do
      {201, _} = http_deploy("inbox_manual_task_timer_boundary.bpmn")
      {201, body} = http_start("InboxManualTaskTimerBoundary")
      process_instance_id = body["processInstanceId"]

      wait_for_process_instance(process_instance_id, @default_timeout)
      assert_pi_state!(process_instance_id, "finished")

      finished_events = user_task_finished_events(collector, "ManualTask_1")
      assert length(finished_events) == 1
      assert hd(finished_events).flow_node_type == :manual_task
      assert hd(finished_events).outcome == :aborted
    end
  end

  describe "resume" do
    test "does not publish UserTaskCreated again for a task that is already waiting",
         %{collector: collector} do
      {201, _} = http_deploy("user_task_simple.bpmn")
      {201, body} = http_start("UserTaskSimple")
      process_instance_id = body["processInstanceId"]

      {:ok, user_task} =
        await_waiting_fni_by_node_id(process_instance_id, "UserTask_1", timeout: @default_timeout)

      assert length(user_task_created_events(collector, "UserTask_1")) == 1

      {:ok, pid} = BfwEngine.Execution.lookup_process_instance(process_instance_id)
      :ok = DynamicSupervisor.terminate_child(BfwEngine.Execution.Supervisor, pid)
      await_process_exit(pid)

      assert {:ok, _resumed_count} = BfwEngine.Execution.ResumeRunner.resume_all()
      {:ok, _resumed_pid} = poll_pi_alive(process_instance_id)

      assert length(user_task_created_events(collector, "UserTask_1")) == 1

      {204, _} = http_finish_user_task(user_task.id, %{"approved" => true})
      wait_for_process_instance(process_instance_id, @default_timeout)
    end
  end

  defp await_process_exit(pid) do
    reference = Process.monitor(pid)

    receive do
      {:DOWN, ^reference, :process, ^pid, _reason} -> :ok
    after
      2_000 -> :ok
    end
  end

  defp await_multiple_waiting_flow_node_instances(
         process_instance_id,
         flow_node_type,
         expected_count,
         opts
       ) do
    timeout = Keyword.get(opts, :timeout, 5_000)
    interval = Keyword.get(opts, :poll_interval, 50)
    deadline = System.monotonic_time(:millisecond) + timeout

    do_poll_multiple_waiting(
      process_instance_id,
      flow_node_type,
      expected_count,
      interval,
      deadline
    )
  end

  defp do_poll_multiple_waiting(
         process_instance_id,
         flow_node_type,
         expected_count,
         interval,
         deadline
       ) do
    waiting_flow_node_instances =
      process_instance_id
      |> fetch_flow_node_instances()
      |> Enum.filter(&(&1.flow_node_type == flow_node_type and &1.state == "waiting"))
      |> Enum.reject(&(Map.get(&1.type_properties || %{}, "mi_shell") == true))

    cond do
      length(waiting_flow_node_instances) >= expected_count ->
        waiting_flow_node_instances

      System.monotonic_time(:millisecond) >= deadline ->
        flunk(
          "Timed out waiting for #{expected_count} waiting #{flow_node_type} FNIs, got #{length(waiting_flow_node_instances)}"
        )

      true ->
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

defmodule BfwEngine.Integration.Execution.TimerCycleCatchUpTest do
  @moduledoc """
  Cycle timers skip occurrences that were missed (decision D-2), an Event
  Subprocess cycle honours its repetition count and emits `TimerFired` (D5),
  a resumed non-interrupting cycle boundary persists its next occurrence (D9),
  a manual trigger that fires nothing answers `triggered: false` (D10), and a
  boundary never fires for a host that already ended (D12).
  """
  use BfwEngine.ExecutionCase, async: false

  alias BfwEngine.Execution
  alias BfwEngine.Execution.ResumeRunner
  alias BfwEngine.Persistence.Repo
  alias BfwEngine.Persistence.Resources.FlowNodeInstance
  alias BfwEngine.Plugins.FacadeBuilder
  alias BfwEngine.Test.EventCollector
  alias BfwEngine.Types.Event

  @domain BfwEngine.Persistence.Api
  @cycle_interval_seconds 4

  describe "Event Subprocess cycle timer start (D5)" do
    test "fires R2 twice, emits TimerFired for each tick, then stops", %{collector: collector} do
      process_instance_id =
        http_deploy_and_start(
          "event_subprocess_timer_cycle_repetitions.bpmn",
          "EspTimerCycleRepetitions"
        )

      assert :ok = await_flow_node_instance_count(process_instance_id, "ESP_Cycle", 2, 5_000)

      # The assertion is that no third repetition fires one interval later.
      Process.sleep(2_500)
      assert length(flow_node_instances_for_node(process_instance_id, "ESP_Cycle")) == 2

      timer_fired_events =
        collector
        |> EventCollector.get_events()
        |> Enum.filter(&match?(%Event.TimerFired{flow_node_id: "ESP_Start"}, &1))

      assert [%{kind: :start, process_instance_id: ^process_instance_id}, _second] =
               timer_fired_events

      user_task = poll_fni_state(process_instance_id, "user_task", "waiting")
      {204, _body} = http_finish_user_task(user_task.id)
      assert {:ok, _process_instance} = await_process_instance_state(process_instance_id, "finished")
    end
  end

  describe "Event Subprocess cycle timer start across a resume (D-10.4)" do
    test "follows the original schedule, not the time the last shell was created" do
      process_instance_id =
        http_deploy_and_start("event_subprocess_timer_cycle_resume.bpmn", "EspTimerCycleResume")

      assert :ok = await_flow_node_instance_count(process_instance_id, "ESP_Cycle", 1, 5_000)
      [first_shell] = flow_node_instances_for_node(process_instance_id, "ESP_Cycle")
      stop_process_instance(process_instance_id)

      Repo.query!("UPDATE flow_node_instances SET started_at = started_at - interval '1 hour' WHERE id = $1", [
        Ecto.UUID.dump!(first_shell.id)
      ])

      {:ok, 1} = ResumeRunner.resume_all()
      {:ok, _pid} = poll_pi_alive(process_instance_id)

      assert :ok = await_flow_node_instance_count(process_instance_id, "ESP_Cycle", 2, 5_000)
    end
  end

  describe "non-interrupting cycle boundary across a resume (D9)" do
    test "a missed occurrence is skipped and the next one is persisted before it fires" do
      process_instance_id =
        http_deploy_and_start("timer_boundary_cycle_resume.bpmn", "TimerBoundaryCycleResume")

      boundary = poll_fni_state(process_instance_id, "boundary_event", "waiting")
      {:ok, first_fire_at, _offset} = DateTime.from_iso8601(boundary.type_properties["fire_at"])
      stop_process_instance(process_instance_id)

      # The assertion is about an occurrence that passes while the instance is stopped.
      Process.sleep(max(DateTime.diff(first_fire_at, DateTime.utc_now(), :millisecond), 0) + 500)

      {:ok, 1} = ResumeRunner.resume_all()
      {:ok, _pid} = poll_pi_alive(process_instance_id)

      resumed_boundary =
        await_flow_node_instance(boundary.id, fn flow_node_instance ->
          flow_node_instance.type_properties["fire_at"] != boundary.type_properties["fire_at"]
        end)

      {:ok, next_fire_at, _offset} =
        DateTime.from_iso8601(resumed_boundary.type_properties["fire_at"])

      assert DateTime.diff(next_fire_at, first_fire_at, :second) == @cycle_interval_seconds
      assert resumed_boundary.type_properties["cycle_repetitions"] == 4
      assert flow_node_instances_for_node(process_instance_id, "End_Timeout") == []

      user_task = poll_fni_state(process_instance_id, "user_task", "waiting")
      {204, _body} = http_finish_user_task(user_task.id)
      assert {:ok, _process_instance} = await_process_instance_state(process_instance_id, "finished")
    end
  end

  describe "cycle boundary whose occurrences are all in the past (D-2, D10)" do
    test "never fires, and a manual trigger answers triggered: false" do
      process_instance_id =
        http_deploy_and_start("timer_boundary_cycle_exhausted.bpmn", "TimerBoundaryCycleExhausted")

      boundary = poll_fni_state(process_instance_id, "boundary_event", "waiting")
      assert boundary.type_properties["cycle_exhausted"] == true

      assert {200, %{"triggered" => false}} = http_trigger_timer_event(boundary.id)

      user_task = poll_fni_state(process_instance_id, "user_task", "waiting")
      {204, _body} = http_finish_user_task(user_task.id)
      assert {:ok, _process_instance} = await_process_instance_state(process_instance_id, "finished")

      assert flow_node_instances_for_node(process_instance_id, "End_Timeout") == []
      assert find_fni_by_flow_node_id(process_instance_id, "BE_Cycle").state == "interrupted"
    end
  end

  describe "plugin facade timers.trigger_event (D-10 9f)" do
    test "answers triggered: false like REST when the cycle has nothing armed" do
      process_instance_id =
        http_deploy_and_start("timer_boundary_cycle_exhausted.bpmn", "TimerBoundaryCycleExhausted")

      boundary = poll_fni_state(process_instance_id, "boundary_event", "waiting")
      facade = FacadeBuilder.build("timer_trigger_facade_test")

      assert {:ok, %{triggered: false}} = facade.timers.trigger_event.(boundary.id)
      assert find_fni_by_flow_node_id(process_instance_id, "BE_Cycle").state == "waiting"
    end

    test "answers triggered: true when the timer fired and keeps real errors" do
      process_instance_id =
        http_deploy_and_start("timer_catch_manual_trigger.bpmn", "TimerCatchManualTrigger")

      timer = poll_fni_state(process_instance_id, "intermediate_catch_event", "waiting")
      facade = FacadeBuilder.build("timer_trigger_facade_test")

      assert {:ok, %{triggered: true}} = facade.timers.trigger_event.(timer.id)
      assert {:error, :not_found} = facade.timers.trigger_event.(Ash.UUIDv7.generate())
    end
  end

  describe "boundary resumed after its host ended (D12)" do
    test "is interrupted instead of firing" do
      process_instance_id =
        http_deploy_and_start(
          "timer_boundary_resume_host_finished.bpmn",
          "TimerBoundaryResumeHostFinished"
        )

      first_task = poll_fni_state(process_instance_id, "user_task", "waiting")
      boundary = poll_fni_state(process_instance_id, "boundary_event", "waiting")
      {204, _body} = http_finish_user_task(first_task.id)
      _interrupted = await_flow_node_instance(boundary.id, &(&1.state == "interrupted"))
      _second_task = await_flow_node_instance_by_node(process_instance_id, "Task_Second", &(&1.state == "waiting"))

      stop_process_instance(process_instance_id)

      lost_interrupt_type_properties =
        Map.put(boundary.type_properties, "fire_at", "2020-01-01T00:00:00Z")

      reset_flow_node_instance(boundary.id, "waiting", lost_interrupt_type_properties)

      {:ok, 1} = ResumeRunner.resume_all()
      {:ok, _pid} = poll_pi_alive(process_instance_id)

      _interrupted = await_flow_node_instance(boundary.id, &(&1.state == "interrupted"))

      second_task =
        await_flow_node_instance_by_node(process_instance_id, "Task_Second", &(&1.state == "waiting"))

      {204, _body} = http_finish_user_task(second_task.id)
      assert {:ok, _process_instance} = await_process_instance_state(process_instance_id, "finished")
      assert flow_node_instances_for_node(process_instance_id, "End_Timeout") == []
    end
  end

  defp flow_node_instances_for_node(process_instance_id, flow_node_id) do
    process_instance_id
    |> fetch_flow_node_instances()
    |> Enum.filter(&(&1.flow_node_id == flow_node_id))
  end

  defp await_flow_node_instance_count(process_instance_id, flow_node_id, expected_count, timeout) do
    poll(timeout, fn ->
      if length(flow_node_instances_for_node(process_instance_id, flow_node_id)) == expected_count, do: :ok
    end)
  end

  defp await_flow_node_instance(flow_node_instance_id, condition) do
    poll(5_000, fn ->
      flow_node_instance =
        FlowNodeInstance
        |> Ash.get!(flow_node_instance_id, domain: @domain, authorize?: false)

      if condition.(flow_node_instance), do: flow_node_instance
    end)
  end

  defp await_flow_node_instance_by_node(process_instance_id, flow_node_id, condition) do
    poll(5_000, fn ->
      process_instance_id
      |> flow_node_instances_for_node(flow_node_id)
      |> Enum.find(condition)
    end)
  end

  defp poll(timeout, probe) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_poll(deadline, probe)
  end

  defp do_poll(deadline, probe) do
    case probe.() do
      nil ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("condition not met before the timeout")
        else
          Process.sleep(25)
          do_poll(deadline, probe)
        end

      result ->
        result
    end
  end

  defp reset_flow_node_instance(flow_node_instance_id, state, type_properties) do
    FlowNodeInstance
    |> Ash.get!(flow_node_instance_id, domain: @domain, authorize?: false)
    |> Ash.Changeset.for_update(:retry_reset, %{state: state, type_properties: type_properties})
    |> Ash.update!(domain: @domain, authorize?: false)
  end

  defp stop_process_instance(process_instance_id) do
    {:ok, process_instance_pid} = Execution.lookup_process_instance(process_instance_id)
    monitor_reference = Process.monitor(process_instance_pid)
    DynamicSupervisor.terminate_child(BfwEngine.Execution.Supervisor, process_instance_pid)
    assert_receive {:DOWN, ^monitor_reference, :process, ^process_instance_pid, _reason}, 2_000
  end
end

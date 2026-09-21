defmodule BfwEngine.Integration.Execution.EscalationTriggerTest do
  @moduledoc """
  Full-stack tests for `POST /escalations/{code}/trigger`.

  Injects an escalation into waiting catchers (boundary + ESP) without a
  modeled BPMN throw. Auth is covered by the HTTP controller tests; this
  file covers waiter delivery semantics.
  """

  use BfwEngine.ExecutionCase, async: false

  alias BfwEngine.Test.EventCollector
  alias BfwEngine.Types.Event

  test "unknown code with no waiters returns empty deliveries" do
    {200, body} = http_trigger_escalation("NO_SUCH_CODE")
    assert body["escalationCode"] == "NO_SUCH_CODE"
    assert body["deliveries"] == []
    assert body["pending"] == false
  end

  test "interrupting escalation boundary on a waiting user task takes the boundary path", %{
    collector: collector
  } do
    {201, _} = http_deploy("escalation_trigger_user_task_interrupting.bpmn")
    {201, body} = http_start("EscalationTriggerInterrupting")
    process_instance_id = body["processInstanceId"]

    assert wait_for_waiting_flow_node(process_instance_id, "UserTask_1")

    {200, trigger_body} = http_trigger_escalation("ESC_API")
    assert trigger_body["pending"] == false
    assert length(trigger_body["deliveries"]) == 1
    assert hd(trigger_body["deliveries"])["processInstanceId"] == process_instance_id

    wait_for_process_instance(process_instance_id, 10_000)
    assert_pi_state!(process_instance_id, "finished")

    flow_node_instances = fetch_flow_node_instances(process_instance_id)
    user_task = Enum.find(flow_node_instances, &(&1.flow_node_id == "UserTask_1"))
    boundary = Enum.find(flow_node_instances, &(&1.flow_node_id == "BE_Escalation"))
    end_caught = Enum.find(flow_node_instances, &(&1.flow_node_id == "End_Caught"))
    end_normal = Enum.find(flow_node_instances, &(&1.flow_node_id == "End_Normal"))

    assert user_task.state == "interrupted"
    assert boundary.state == "finished"
    assert end_caught.state == "finished"
    assert end_normal == nil

    events = EventCollector.get_events(collector)

    escalation_raised =
      Enum.find(events, &(&1.__struct__ == Event.EscalationRaised))

    assert escalation_raised != nil
    assert escalation_raised.escalation_code == "ESC_API"
    assert escalation_raised.throw_type == :api_trigger
  end

  test "interrupting escalation boundary on an embedded subprocess host takes the boundary path" do
    {201, _} = http_deploy("escalation_trigger_subprocess_interrupting.bpmn")
    {201, body} = http_start("EscalationTriggerSpInterrupting")
    process_instance_id = body["processInstanceId"]

    assert wait_for_waiting_flow_node(process_instance_id, "BE_Escalation")

    {200, trigger_body} = http_trigger_escalation("ESC_API")
    assert length(trigger_body["deliveries"]) == 1
    assert hd(trigger_body["deliveries"])["processInstanceId"] == process_instance_id

    wait_for_process_instance(process_instance_id, 10_000)
    assert_pi_state!(process_instance_id, "finished")

    flow_node_instances = fetch_flow_node_instances(process_instance_id)
    subprocess = Enum.find(flow_node_instances, &(&1.flow_node_id == "SubProcess_1"))
    boundary = Enum.find(flow_node_instances, &(&1.flow_node_id == "BE_Escalation"))
    end_caught = Enum.find(flow_node_instances, &(&1.flow_node_id == "End_Caught"))
    end_normal = Enum.find(flow_node_instances, &(&1.flow_node_id == "End_Normal"))

    assert subprocess.state == "interrupted"
    assert boundary.state == "finished"
    assert end_caught.state == "finished"
    assert end_normal == nil
  end

  test "non-interrupting escalation boundary leaves the host waiting and starts the parallel path" do
    {201, _} = http_deploy("escalation_trigger_user_task_non_interrupting.bpmn")
    {201, body} = http_start("EscalationTriggerNonInterrupting")
    process_instance_id = body["processInstanceId"]

    assert wait_for_waiting_flow_node(process_instance_id, "UserTask_1")

    {200, trigger_body} = http_trigger_escalation("ESC_API")
    assert length(trigger_body["deliveries"]) == 1

    assert wait_until(fn ->
             flow_node_instances = fetch_flow_node_instances(process_instance_id)
             end_caught = Enum.find(flow_node_instances, &(&1.flow_node_id == "End_Caught"))
             user_task = Enum.find(flow_node_instances, &(&1.flow_node_id == "UserTask_1"))
             end_caught && end_caught.state == "finished" && user_task.state == "waiting"
           end)

    flow_node_instances = fetch_flow_node_instances(process_instance_id)
    user_task = Enum.find(flow_node_instances, &(&1.flow_node_id == "UserTask_1"))
    assert user_task.state == "waiting"

    {204, _} = http_finish_user_task(user_task.id, %{})
    wait_for_process_instance(process_instance_id, 10_000)
    assert_pi_state!(process_instance_id, "finished")
  end

  test "ESP escalation start spawns an event-subprocess child", %{collector: collector} do
    {201, _} = http_deploy("escalation_trigger_esp.bpmn")
    {201, body} = http_start("EscalationTriggerEsp")
    process_instance_id = body["processInstanceId"]

    assert wait_for_waiting_flow_node(process_instance_id, "UserTask_1")

    {200, trigger_body} = http_trigger_escalation("ESC_ESP_API")
    assert length(trigger_body["deliveries"]) == 1

    assert wait_until(fn ->
             events = EventCollector.get_events(collector)

             Enum.any?(events, fn event ->
               event.__struct__ == Event.SubProcessChildStarted and
                 event.is_event_subprocess == true
             end)
           end)

    events = EventCollector.get_events(collector)

    assert Enum.any?(events, fn event ->
             event.__struct__ == Event.EventSubprocessTriggered and
               event.trigger_kind == :escalation
           end)

    escalation_raised = Enum.find(events, &(&1.__struct__ == Event.EscalationRaised))
    assert escalation_raised != nil
    assert escalation_raised.throw_type == :api_trigger

    flow_node_instances = fetch_flow_node_instances(process_instance_id)
    user_task = Enum.find(flow_node_instances, &(&1.flow_node_id == "UserTask_1"))
    assert user_task.state == "waiting"
  end

  test "two running instances with the same code both receive the inject" do
    {201, _} = http_deploy("escalation_trigger_user_task_interrupting.bpmn")
    {201, first} = http_start("EscalationTriggerInterrupting")
    {201, second} = http_start("EscalationTriggerInterrupting")
    first_id = first["processInstanceId"]
    second_id = second["processInstanceId"]

    assert wait_for_waiting_flow_node(first_id, "UserTask_1")
    assert wait_for_waiting_flow_node(second_id, "UserTask_1")

    {200, trigger_body} = http_trigger_escalation("ESC_API")
    delivered_ids = Enum.map(trigger_body["deliveries"], & &1["processInstanceId"])
    assert first_id in delivered_ids
    assert second_id in delivered_ids

    wait_for_process_instance(first_id, 10_000)
    wait_for_process_instance(second_id, 10_000)
    assert_pi_state!(first_id, "finished")
    assert_pi_state!(second_id, "finished")
  end

  test "specific code does not fire a different-code boundary; catch-all does fire" do
    {201, _} = http_deploy("escalation_trigger_user_task_interrupting.bpmn")
    {201, specific} = http_start("EscalationTriggerInterrupting")
    specific_id = specific["processInstanceId"]
    assert wait_for_waiting_flow_node(specific_id, "UserTask_1")

    {200, miss} = http_trigger_escalation("ESC_OTHER")
    refute Enum.any?(miss["deliveries"], &(&1["processInstanceId"] == specific_id))

    flow_node_instances = fetch_flow_node_instances(specific_id)
    user_task = Enum.find(flow_node_instances, &(&1.flow_node_id == "UserTask_1"))
    assert user_task.state == "waiting"

    {201, _} = http_deploy("escalation_trigger_user_task_catchall.bpmn")
    {201, catchall} = http_start("EscalationTriggerCatchall")
    catchall_id = catchall["processInstanceId"]
    assert wait_for_waiting_flow_node(catchall_id, "UserTask_1")

    {200, hit} = http_trigger_escalation("ANY_NAMED_CODE")
    assert Enum.any?(hit["deliveries"], &(&1["processInstanceId"] == catchall_id))

    wait_for_process_instance(catchall_id, 10_000)
    assert_pi_state!(catchall_id, "finished")
  end

  defp wait_for_waiting_flow_node(process_instance_id, flow_node_id, timeout_ms \\ 5_000) do
    wait_until(
      fn ->
        flow_node_instances = fetch_flow_node_instances(process_instance_id)
        match = Enum.find(flow_node_instances, &(&1.flow_node_id == flow_node_id))
        match && match.state == "waiting"
      end,
      timeout_ms
    )
  end

  defp wait_until(predicate, timeout_ms \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(predicate, deadline)
  end

  defp do_wait_until(predicate, deadline) do
    cond do
      predicate.() ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(50)
        do_wait_until(predicate, deadline)
    end
  end
end

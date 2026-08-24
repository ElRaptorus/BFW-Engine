defmodule EvilEngine.Integration.TimerStartPersistenceTest do
  @moduledoc """
  Full-stack test: cycle Timer Start schedules persist in Postgres and
  re-arm after a simulated Scheduler ETS loss (engine restart).
  """

  use EvilEngine.ExecutionCase, async: false

  alias EvilEngine.Persistence.TimerStartScheduleAdapter
  alias EvilEngine.Timers.Scheduler
  alias EvilEngine.Timers.StartEventManager

  @cycle_iso "R/PT1S"

  test "cycle Timer Start survives Scheduler ETS loss via Postgres reload" do
    process_model_id = "TimerStartPersist_#{System.unique_integer([:positive])}"
    xml = cycle_timer_start_xml(process_model_id)

    {201, _body} = http_deploy_xml(xml)

    {:ok, schedules} = StartEventManager.list_schedules()

    schedule =
      Enum.find(schedules, fn record ->
        record.process_model_id == process_model_id
      end)

    assert schedule
    assert schedule.enabled == true
    assert schedule.kind == "cycle"
    assert schedule.next_fire_at != nil

    {:ok, persisted} = TimerStartScheduleAdapter.get_schedule(schedule.id)
    assert persisted.enabled == true
    assert persisted.kind == "cycle"
    assert persisted.next_fire_at != nil

    if schedule.scheduler_ref do
      Scheduler.cancel(schedule.scheduler_ref)
    end

    {:ok, still_persisted} = TimerStartScheduleAdapter.get_schedule(schedule.id)
    assert still_persisted.id == schedule.id
    assert still_persisted.next_fire_at != nil

    instance_count_before = count_process_instances(schedule.process_version_id)

    assert :ok = StartEventManager.reload_start_schedules()

    assert wait_until(
             fn ->
               count_process_instances(schedule.process_version_id) > instance_count_before
             end,
             8_000
           ),
           "expected a process instance after reload for #{process_model_id}"

    {:ok, disabled} = StartEventManager.disable_schedule(schedule.id)
    assert disabled.enabled == false

    assert wait_until(fn -> not has_running_process_instances?(schedule.process_version_id) end)

    instance_count_after_quiesce = count_process_instances(schedule.process_version_id)

    {204, _} = http_delete_version(process_model_id, "1.0.0")

    {:ok, remaining} =
      TimerStartScheduleAdapter.list_all_schedules(
        process_version_id: schedule.process_version_id
      )

    assert remaining == []

    Process.sleep(1_500)

    assert count_process_instances(schedule.process_version_id) == instance_count_after_quiesce
  end

  defp count_process_instances(process_version_id) do
    require Ash.Query

    {:ok, records} =
      EvilEngine.Persistence.Resources.ProcessInstance
      |> Ash.Query.filter(process_version_id == ^process_version_id and deleted == false)
      |> Ash.read(authorize?: false)

    length(records)
  end

  defp has_running_process_instances?(process_version_id) do
    require Ash.Query

    {:ok, records} =
      EvilEngine.Persistence.Resources.ProcessInstance
      |> Ash.Query.filter(
        process_version_id == ^process_version_id and state == "running" and deleted == false
      )
      |> Ash.read(authorize?: false)

    records != []
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

  defp cycle_timer_start_xml(process_model_id) do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL"
                      xmlns:evil="https://evilengine.dev/schema/bpmn"
                      xmlns:bpmndi="http://www.omg.org/spec/BPMN/20100524/DI"
                      xmlns:dc="http://www.omg.org/spec/DD/20100524/DC"
                      xmlns:di="http://www.omg.org/spec/DD/20100524/DI"
                      id="Definitions_#{process_model_id}"
                      targetNamespace="https://evilengine.dev/schema/bpmn">
      <bpmn:process id="#{process_model_id}" name="Timer Start Persist" isExecutable="true">
        <bpmn:extensionElements>
          <evil:version>1.0.0</evil:version>
        </bpmn:extensionElements>
        <bpmn:startEvent id="TimerStart_1" name="Cycle Timer Start">
          <bpmn:outgoing>Flow_1</bpmn:outgoing>
          <bpmn:timerEventDefinition>
            <bpmn:timeCycle>#{@cycle_iso}</bpmn:timeCycle>
          </bpmn:timerEventDefinition>
        </bpmn:startEvent>
        <bpmn:endEvent id="End_1" name="Done">
          <bpmn:incoming>Flow_1</bpmn:incoming>
        </bpmn:endEvent>
        <bpmn:sequenceFlow id="Flow_1" sourceRef="TimerStart_1" targetRef="End_1" />
      </bpmn:process>
      <bpmndi:BPMNDiagram id="BPMNDiagram_1">
        <bpmndi:BPMNPlane id="BPMNPlane_1" bpmnElement="#{process_model_id}">
          <bpmndi:BPMNShape id="Shape_TimerStart_1" bpmnElement="TimerStart_1">
            <dc:Bounds x="162" y="182" width="36" height="36" />
          </bpmndi:BPMNShape>
          <bpmndi:BPMNShape id="Shape_End_1" bpmnElement="End_1">
            <dc:Bounds x="322" y="182" width="36" height="36" />
          </bpmndi:BPMNShape>
          <bpmndi:BPMNEdge id="Edge_Flow_1" bpmnElement="Flow_1">
            <di:waypoint x="198" y="200" />
            <di:waypoint x="322" y="200" />
          </bpmndi:BPMNEdge>
        </bpmndi:BPMNPlane>
      </bpmndi:BPMNDiagram>
    </bpmn:definitions>
    """
  end
end

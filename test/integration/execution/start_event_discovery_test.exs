defmodule BfwEngine.Integration.Execution.StartEventDiscoveryTest do
  @moduledoc """
  A message start, signal start, or cycle timer fire creates at most one
  instance per enabled process, on its latest live version, and only when
  that version has the matching start event.
  """
  use BfwEngine.ExecutionCase, async: false

  alias BfwEngine.Execution.TimerStartListener
  alias BfwEngine.Persistence.Application, as: PersistenceApplication
  alias BfwEngine.Test.ServiceReset
  alias BfwEngine.Timers.StartEventManager

  @fixtures_dir Path.expand("../../fixtures/bpmns", __DIR__)

  describe "message start" do
    test "two deployed versions start one instance, on the latest version" do
      {201, _} = http_deploy("message_start_event.bpmn")
      {201, _} = http_deploy_xml(fixture_with_version("message_start_event.bpmn", "2.0.0"))

      {200, result} = http_trigger_message("trigger-process", %{"data" => "start"})

      assert [process_instance_id] = result["startedProcessInstanceIds"]

      assert fetch_process_instance!(process_instance_id).process_version_id ==
               version_id("MessageStartEvent", "2.0.0")
    end

    test "a disabled process starts nothing and the message goes pending" do
      {201, _} = http_deploy("message_start_event.bpmn")
      {204, _} = http_disable("MessageStartEvent")

      {200, result} = http_trigger_message("trigger-process", %{"data" => "start"})

      assert result["startedProcessInstanceIds"] == []
      assert result["pending"] == true
    end

    test "deleting the latest version starts on the previous version even when it was not cached" do
      {201, _} = http_deploy("message_start_event.bpmn")
      ServiceReset.bpmn_model_cache()
      {201, _} = http_deploy_xml(fixture_with_version("message_start_event.bpmn", "2.0.0"))
      {204, _} = http_delete_version("MessageStartEvent", "2.0.0")

      {200, result} = http_trigger_message("trigger-process", %{"data" => "start"})

      assert [process_instance_id] = result["startedProcessInstanceIds"]

      assert fetch_process_instance!(process_instance_id).process_version_id ==
               version_id("MessageStartEvent", "1.0.0")
    end

    test "the boot warm indexes deployed start events after a restart" do
      {201, _} = http_deploy("message_start_event.bpmn")
      ServiceReset.bpmn_model_cache()

      :ok = PersistenceApplication.warm_start_event_index()

      {200, result} = http_trigger_message("trigger-process", %{"data" => "start"})
      assert [_process_instance_id] = result["startedProcessInstanceIds"]
    end
  end

  describe "signal start" do
    test "two deployed versions start one instance, on the latest version" do
      {201, _} = http_deploy("signal_start_event.bpmn")
      {201, _} = http_deploy_xml(fixture_with_version("signal_start_event.bpmn", "2.0.0"))

      {200, result} = http_trigger_signal("trigger-process")

      assert [process_instance_id] = result["startedProcessInstanceIds"]

      assert fetch_process_instance!(process_instance_id).process_version_id ==
               version_id("SignalStartEventProcess", "2.0.0")
    end
  end

  describe "cycle timer start" do
    test "a schedule of a superseded version skips its fire" do
      {201, _} = http_deploy_xml(hourly_cycle("1.0.0"))
      {201, _} = http_deploy_xml(hourly_cycle("2.0.0"))
      superseded_version_id = version_id("TimerStartCycle", "1.0.0")
      latest_version_id = version_id("TimerStartCycle", "2.0.0")

      superseded = fire_schedule_of(superseded_version_id)
      latest = fire_schedule_of(latest_version_id)

      assert superseded.last_triggered_at == nil
      assert latest.last_triggered_at != nil
    end

    test "a multi-process file schedules the cycle only for the process that owns it" do
      sibling_process = """
        <bpmn:process id="CycleSibling" name="Cycle Sibling" isExecutable="true">
          <bpmn:extensionElements>
            <bfw:version>1.0.0</bfw:version>
          </bpmn:extensionElements>
          <bpmn:startEvent id="SiblingStart" />
          <bpmn:endEvent id="SiblingEnd" />
          <bpmn:sequenceFlow id="SiblingFlow" sourceRef="SiblingStart" targetRef="SiblingEnd" />
        </bpmn:process>
        <bpmndi:BPMNDiagram
      """

      xml = String.replace(hourly_cycle("1.0.0"), "<bpmndi:BPMNDiagram", sibling_process, global: false)
      {201, _} = http_deploy_xml(xml)

      {:ok, owner_schedules} =
        StartEventManager.list_schedules(process_version_id: version_id("TimerStartCycle", "1.0.0"))

      {:ok, sibling_schedules} =
        StartEventManager.list_schedules(process_version_id: version_id("CycleSibling", "1.0.0"))

      assert [%{process_model_id: "TimerStartCycle"}] = owner_schedules
      assert sibling_schedules == []
    end
  end

  defp fire_schedule_of(process_version_id) do
    {:ok, [schedule]} = StartEventManager.list_schedules(process_version_id: process_version_id)

    send(
      TimerStartListener,
      {:timer_fired, "manual-#{schedule.id}",
       %{
         schedule_id: schedule.id,
         process_version_id: process_version_id,
         process_model_id: "TimerStartCycle",
         flow_node_id: schedule.flow_node_id
       }}
    )

    _state = :sys.get_state(TimerStartListener)
    {:ok, fired} = StartEventManager.get_schedule(schedule.id)
    fired
  end

  defp fixture_with_version(fixture_name, version) do
    @fixtures_dir
    |> Path.join(fixture_name)
    |> File.read!()
    |> String.replace("<bfw:version>1.0.0</bfw:version>", "<bfw:version>#{version}</bfw:version>")
  end

  defp hourly_cycle(version) do
    "timer_start_cycle.bpmn"
    |> fixture_with_version(version)
    |> String.replace("R3/PT0S", "R3/PT1H")
  end

  defp version_id(process_model_id, version) do
    {200, version_entries} = http_list_versions(process_model_id)
    Enum.find_value(version_entries, &(&1["version"] == version && &1["versionId"]))
  end
end

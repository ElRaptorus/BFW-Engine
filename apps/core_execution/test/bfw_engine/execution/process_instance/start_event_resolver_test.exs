defmodule BfwEngine.Execution.ProcessInstance.StartEventResolverTest do
  use ExUnit.Case, async: true

  alias BfwEngine.BPMN.Model.EventDefinition
  alias BfwEngine.BPMN.Model.FlowNode
  alias BfwEngine.BPMN.Model.FlowNodeData
  alias BfwEngine.BPMN.Model.Process, as: BpmnProcess
  alias BfwEngine.Execution.ProcessInstance.StartEventResolver

  defp make_start_event(id, event_definition \\ %EventDefinition.None{}) do
    %FlowNode{
      id: id,
      type: :start_event,
      type_data: %FlowNodeData.StartEvent{event_definition: event_definition}
    }
  end

  defp make_process(flow_nodes) do
    %BpmnProcess{id: "test-process", flow_nodes: flow_nodes, sequence_flows: []}
  end

  describe "resolve/2" do
    test "single untyped start event resolves without explicit ID" do
      start = make_start_event("Start_1")
      process = make_process([start])

      assert {:ok, ^start} = StartEventResolver.resolve(process, nil)
    end

    test "single untyped start event resolves with matching ID" do
      start = make_start_event("Start_1")
      process = make_process([start])

      assert {:ok, ^start} = StartEventResolver.resolve(process, "Start_1")
    end

    test "single untyped start event with non-matching ID returns error" do
      start = make_start_event("Start_1")
      process = make_process([start])

      assert {:error, :start_event_not_found, message} =
               StartEventResolver.resolve(process, "Start_X")

      assert message =~ "Start_X"
      assert message =~ "Start_1"
    end

    test "multiple untyped start events without ID returns ambiguous error" do
      start_a = make_start_event("Start_A")
      start_b = make_start_event("Start_B")
      process = make_process([start_a, start_b])

      assert {:error, :ambiguous_start_event, message} =
               StartEventResolver.resolve(process, nil)

      assert message =~ "2 start events"
    end

    test "multiple untyped start events with matching ID resolves" do
      start_a = make_start_event("Start_A")
      start_b = make_start_event("Start_B")
      process = make_process([start_a, start_b])

      assert {:ok, ^start_b} = StartEventResolver.resolve(process, "Start_B")
    end

    test "multiple untyped start events with non-matching ID returns error" do
      start_a = make_start_event("Start_A")
      start_b = make_start_event("Start_B")
      process = make_process([start_a, start_b])

      assert {:error, :start_event_not_found, message} =
               StartEventResolver.resolve(process, "Start_X")

      assert message =~ "Start_X"
    end

    test "no untyped start events returns no_start_event error" do
      task = %FlowNode{id: "Task_1", type: :task, type_data: %FlowNodeData.Task{}}
      process = make_process([task])

      assert {:error, :no_start_event, _message} = StartEventResolver.resolve(process, nil)
    end

    test "typed start event resolves when ID matches" do
      typed_start =
        make_start_event(
          "Timer_Start",
          %EventDefinition.Timer{time_duration: "PT1H"}
        )

      process = make_process([typed_start])

      assert {:ok, ^typed_start} = StartEventResolver.resolve(process, "Timer_Start")
    end

    test "typed start event is not resolved when no ID provided" do
      typed_start =
        make_start_event(
          "Timer_Start",
          %EventDefinition.Timer{time_duration: "PT1H"}
        )

      process = make_process([typed_start])

      assert {:error, :no_start_event, _message} = StartEventResolver.resolve(process, nil)
    end
  end
end

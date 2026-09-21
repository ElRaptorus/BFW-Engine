defmodule BfwEngine.Execution.ProcessInstance.ModeTest do
  use ExUnit.Case, async: true

  alias BfwEngine.BPMN.Model.EventDefinition
  alias BfwEngine.BPMN.Model.FlowNode
  alias BfwEngine.BPMN.Model.FlowNodeData
  alias BfwEngine.BPMN.Model.Process, as: BpmnProcess
  alias BfwEngine.Execution.ProcessInstance.AdHocMode
  alias BfwEngine.Execution.ProcessInstance.StandardMode
  alias BfwEngine.Execution.ProcessInstance.State

  describe "StandardMode.resolve_initial_state/3" do
    test "delegates to StartEventResolver and returns start event" do
      start = %FlowNode{
        id: "Start_1",
        type: :start_event,
        type_data: %FlowNodeData.StartEvent{event_definition: %EventDefinition.None{}}
      }

      process = %BpmnProcess{id: "proc-1", flow_nodes: [start], sequence_flows: []}

      assert {:ok, ^start} = StandardMode.resolve_initial_state(process, nil, "proc-1")
    end

    test "returns error when no start event exists" do
      process = %BpmnProcess{id: "proc-1", flow_nodes: [], sequence_flows: []}

      assert {:error, :no_start_event, _message} =
               StandardMode.resolve_initial_state(process, nil, "proc-1")
    end
  end

  describe "StandardMode.initial_dispatch/4" do
    test "returns data unchanged" do
      data = %State{
        process_instance_id: "pi-1",
        process_version_id: "pv-1"
      }

      assert ^data = StandardMode.initial_dispatch(data, nil, %{}, false)
    end
  end

  describe "StandardMode.should_complete?/1" do
    test "returns true when no active or waiting FNIs" do
      data = %State{
        process_instance_id: "pi-1",
        process_version_id: "pv-1",
        flow_node_instance_states: %{
          "fni-1" => %{state: :finished},
          "fni-2" => %{state: :fatal}
        }
      }

      assert StandardMode.should_complete?(data)
    end

    test "returns false when active FNIs exist" do
      data = %State{
        process_instance_id: "pi-1",
        process_version_id: "pv-1",
        flow_node_instance_states: %{
          "fni-1" => %{state: :active},
          "fni-2" => %{state: :finished}
        }
      }

      refute StandardMode.should_complete?(data)
    end

    test "returns false when waiting FNIs exist" do
      data = %State{
        process_instance_id: "pi-1",
        process_version_id: "pv-1",
        flow_node_instance_states: %{
          "fni-1" => %{state: :waiting}
        }
      }

      refute StandardMode.should_complete?(data)
    end
  end

  describe "AdHocMode.resolve_initial_state/3" do
    test "always returns {:ok, nil}" do
      process = %BpmnProcess{id: "proc-1", flow_nodes: [], sequence_flows: []}

      assert {:ok, nil} = AdHocMode.resolve_initial_state(process, nil, "proc-1")
    end

    test "ignores start_event_id parameter" do
      process = %BpmnProcess{id: "proc-1", flow_nodes: [], sequence_flows: []}

      assert {:ok, nil} = AdHocMode.resolve_initial_state(process, "Start_1", "proc-1")
    end
  end

  describe "AdHocMode.initial_dispatch/4" do
    test "returns data unchanged" do
      data = %State{
        process_instance_id: "pi-1",
        process_version_id: "pv-1"
      }

      assert ^data = AdHocMode.initial_dispatch(data, nil, %{}, false)
    end
  end

  describe "AdHocMode.should_complete?/1" do
    test "returns false when completion not signaled" do
      data = %State{
        process_instance_id: "pi-1",
        process_version_id: "pv-1",
        adhoc_completion_signaled: false,
        flow_node_instance_states: %{}
      }

      refute AdHocMode.should_complete?(data)
    end

    test "returns false when signaled but active FNIs exist" do
      data = %State{
        process_instance_id: "pi-1",
        process_version_id: "pv-1",
        adhoc_completion_signaled: true,
        flow_node_instance_states: %{
          "fni-1" => %{state: :active}
        }
      }

      refute AdHocMode.should_complete?(data)
    end

    test "returns false when signaled but waiting FNIs exist" do
      data = %State{
        process_instance_id: "pi-1",
        process_version_id: "pv-1",
        adhoc_completion_signaled: true,
        flow_node_instance_states: %{
          "fni-1" => %{state: :waiting}
        }
      }

      refute AdHocMode.should_complete?(data)
    end

    test "returns true when signaled and no active/waiting FNIs" do
      data = %State{
        process_instance_id: "pi-1",
        process_version_id: "pv-1",
        adhoc_completion_signaled: true,
        flow_node_instance_states: %{
          "fni-1" => %{state: :finished},
          "fni-2" => %{state: :fatal}
        }
      }

      assert AdHocMode.should_complete?(data)
    end

    test "returns true when signaled and FNI map is empty" do
      data = %State{
        process_instance_id: "pi-1",
        process_version_id: "pv-1",
        adhoc_completion_signaled: true,
        flow_node_instance_states: %{}
      }

      assert AdHocMode.should_complete?(data)
    end
  end
end

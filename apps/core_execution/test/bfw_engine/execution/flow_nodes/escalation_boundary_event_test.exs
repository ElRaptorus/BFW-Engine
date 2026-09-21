defmodule BfwEngine.Execution.FlowNodes.EscalationBoundaryEventTest do
  use ExUnit.Case, async: true

  alias BfwEngine.BPMN.Model.Definitions
  alias BfwEngine.BPMN.Model.EventDefinition
  alias BfwEngine.BPMN.Model.FlowNode
  alias BfwEngine.BPMN.Model.FlowNodeData
  alias BfwEngine.Execution.FlowNodes
  alias BfwEngine.Execution.HandlerContext
  alias BfwEngine.Types.Token

  defp make_token do
    %Token{
      id: "token-1",
      process_instance_id: "pi-1",
      payload: %{"key" => "value"},
      created_at: DateTime.utc_now()
    }
  end

  defp make_flow_node(opts \\ []) do
    cancel_activity = Keyword.get(opts, :cancel_activity, true)

    %FlowNode{
      id: "BE_Escalation",
      name: "Escalation Boundary",
      type: :boundary_event,
      type_data: %FlowNodeData.BoundaryEvent{
        attached_to_ref: "Task_1",
        cancel_activity: cancel_activity,
        event_definition: %EventDefinition.Escalation{escalation_ref: nil}
      },
      outgoing: ["Flow_out"]
    }
  end

  defp make_context(opts \\ []) do
    cancel_activity = Keyword.get(opts, :cancel_activity, true)

    %HandlerContext{
      flow_node_instance_id: "fni-boundary-1",
      process_instance_id: "pi-1",
      process_instance_pid: self(),
      host_flow_node_instance_id: "fni-host-1",
      definitions: %Definitions{
        definitions_id: "Definitions_1",
        escalations: [],
        raw_xml: ""
      },
      identity: %{},
      process: %{},
      process_instance: %{},
      data_objects: %{},
      process_model: %{
        id: "proc",
        flow_nodes: [make_flow_node(cancel_activity: cancel_activity)],
        sequence_flows: []
      }
    }
  end

  describe "handle_enter/3" do
    test "returns {:async, fni_id, continuation, type_properties}" do
      flow_node = make_flow_node()
      token = make_token()
      context = make_context()

      result = FlowNodes.EscalationBoundaryEvent.handle_enter(flow_node, token, context)

      assert {:async, fni_id, continuation, type_properties} = result
      assert fni_id == "fni-boundary-1"
      assert is_function(continuation, 0)
      assert type_properties.host_flow_node_instance_id == "fni-host-1"
      assert type_properties.cancel_activity == true
    end

    test "type_properties reflects non-interrupting boundary" do
      flow_node = make_flow_node(cancel_activity: false)
      token = make_token()
      context = make_context(cancel_activity: false)

      {:async, _fni_id, _continuation, type_properties} =
        FlowNodes.EscalationBoundaryEvent.handle_enter(flow_node, token, context)

      assert type_properties.cancel_activity == false
    end

    test "continuation receives {:escalation_boundary_triggered, ...} message without crashing" do
      flow_node = make_flow_node()
      token = make_token()
      context = make_context()

      {:async, _fni_id, continuation, _type_props} =
        FlowNodes.EscalationBoundaryEvent.handle_enter(flow_node, token, context)

      task =
        Task.async(fn ->
          send(self(), {:escalation_boundary_triggered, %{escalation_code: "ESC_A"}})
          continuation.()
        end)

      assert Task.await(task, 1000) == :ok
    end
  end
end

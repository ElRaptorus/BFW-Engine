defmodule EvilEngine.Execution.FlowNodes.ParallelGatewayTest do
  @moduledoc """
  Handler unit tests for `ParallelGateway.handle_enter/3`.

  Tests cover fork (diverging), join (converging), mixed gateway rejection,
  dead-end scenarios, and single-incoming pass-through.
  """
  use ExUnit.Case, async: true

  alias EvilEngine.BPMN.Model.FlowNode
  alias EvilEngine.BPMN.Model.FlowNodeData
  alias EvilEngine.BPMN.Model.Process, as: BpmnProcess
  alias EvilEngine.BPMN.Model.SequenceFlow
  alias EvilEngine.Execution.FlowNodeResult
  alias EvilEngine.Execution.FlowNodes.ParallelGateway
  alias EvilEngine.Execution.HandlerContext
  alias EvilEngine.Types.Token

  defp make_token(payload \\ %{"key" => "value"}) do
    %Token{
      id: "token-1",
      process_instance_id: "pi-1",
      payload: payload,
      created_at: DateTime.utc_now()
    }
  end

  defp build_fork_context(outgoing_target_ids) do
    gateway = %FlowNode{
      id: "Fork_1",
      name: "Fork",
      type: :parallel_gateway,
      type_data: %FlowNodeData.ParallelGateway{},
      incoming: ["Flow_In"],
      outgoing: Enum.map(outgoing_target_ids, &"Flow_to_#{&1}")
    }

    target_nodes =
      Enum.map(outgoing_target_ids, fn target_id ->
        %FlowNode{
          id: target_id,
          type: :task,
          type_data: %FlowNodeData.Task{},
          incoming: ["Flow_to_#{target_id}"]
        }
      end)

    sequence_flows =
      [%SequenceFlow{id: "Flow_In", source_ref: "Start_1", target_ref: "Fork_1"}] ++
        Enum.map(outgoing_target_ids, fn target_id ->
          %SequenceFlow{
            id: "Flow_to_#{target_id}",
            source_ref: "Fork_1",
            target_ref: target_id
          }
        end)

    process_model = %BpmnProcess{
      id: "proc-1",
      flow_nodes: [gateway | target_nodes],
      sequence_flows: sequence_flows
    }

    context = %HandlerContext{
      flow_node_instance_id: "fni-fork-1",
      process_instance_id: "pi-1",
      process_model: process_model
    }

    {gateway, context}
  end

  defp build_join_context(incoming_source_ids, outgoing_target_id) do
    gateway = %FlowNode{
      id: "Join_1",
      name: "Join",
      type: :parallel_gateway,
      type_data: %FlowNodeData.ParallelGateway{},
      incoming: Enum.map(incoming_source_ids, &"Flow_from_#{&1}"),
      outgoing: ["Flow_to_#{outgoing_target_id}"]
    }

    target_node = %FlowNode{
      id: outgoing_target_id,
      type: :task,
      type_data: %FlowNodeData.Task{},
      incoming: ["Flow_to_#{outgoing_target_id}"]
    }

    sequence_flows =
      Enum.map(incoming_source_ids, fn source_id ->
        %SequenceFlow{
          id: "Flow_from_#{source_id}",
          source_ref: source_id,
          target_ref: "Join_1"
        }
      end) ++
        [
          %SequenceFlow{
            id: "Flow_to_#{outgoing_target_id}",
            source_ref: "Join_1",
            target_ref: outgoing_target_id
          }
        ]

    process_model = %BpmnProcess{
      id: "proc-1",
      flow_nodes: [gateway, target_node],
      sequence_flows: sequence_flows
    }

    context = %HandlerContext{
      flow_node_instance_id: "fni-join-1",
      process_instance_id: "pi-1",
      process_model: process_model
    }

    {gateway, context}
  end

  defp build_mixed_context do
    gateway = %FlowNode{
      id: "Mixed_1",
      name: "Mixed",
      type: :parallel_gateway,
      type_data: %FlowNodeData.ParallelGateway{},
      incoming: ["Flow_In_A", "Flow_In_B"],
      outgoing: ["Flow_Out_A", "Flow_Out_B"]
    }

    target_a = %FlowNode{
      id: "Target_A",
      type: :task,
      type_data: %FlowNodeData.Task{},
      incoming: ["Flow_Out_A"]
    }

    target_b = %FlowNode{
      id: "Target_B",
      type: :task,
      type_data: %FlowNodeData.Task{},
      incoming: ["Flow_Out_B"]
    }

    sequence_flows = [
      %SequenceFlow{id: "Flow_In_A", source_ref: "Source_A", target_ref: "Mixed_1"},
      %SequenceFlow{id: "Flow_In_B", source_ref: "Source_B", target_ref: "Mixed_1"},
      %SequenceFlow{id: "Flow_Out_A", source_ref: "Mixed_1", target_ref: "Target_A"},
      %SequenceFlow{id: "Flow_Out_B", source_ref: "Mixed_1", target_ref: "Target_B"}
    ]

    process_model = %BpmnProcess{
      id: "proc-1",
      flow_nodes: [gateway, target_a, target_b],
      sequence_flows: sequence_flows
    }

    context = %HandlerContext{
      flow_node_instance_id: "fni-mixed-1",
      process_instance_id: "pi-1",
      process_model: process_model
    }

    {gateway, context}
  end

  describe "fork (diverging)" do
    test "dispatches all outgoing target node IDs with 2 branches" do
      {gateway, context} = build_fork_context(["Task_A", "Task_B"])
      token = make_token()

      assert {:ok, %FlowNodeResult{next_flow_node_ids: next_ids}} =
               ParallelGateway.handle_enter(gateway, token, context)

      assert Enum.sort(next_ids) == ["Task_A", "Task_B"]
    end

    test "dispatches all outgoing target node IDs with 3 branches" do
      {gateway, context} = build_fork_context(["Task_A", "Task_B", "Task_C"])
      token = make_token()

      assert {:ok, %FlowNodeResult{next_flow_node_ids: next_ids}} =
               ParallelGateway.handle_enter(gateway, token, context)

      assert Enum.sort(next_ids) == ["Task_A", "Task_B", "Task_C"]
    end

    test "preserves token payload in output" do
      {gateway, context} = build_fork_context(["Task_A", "Task_B"])
      token = make_token(%{"order_id" => "ORD-123"})

      assert {:ok, %FlowNodeResult{output_payload: payload}} =
               ParallelGateway.handle_enter(gateway, token, context)

      assert payload == %{"order_id" => "ORD-123"}
    end

    test "single-incoming pass-through (fork with 1 incoming, 1 outgoing)" do
      gateway = %FlowNode{
        id: "Pass_1",
        name: "PassThrough",
        type: :parallel_gateway,
        type_data: %FlowNodeData.ParallelGateway{},
        incoming: ["Flow_In"],
        outgoing: ["Flow_Out"]
      }

      target = %FlowNode{
        id: "Next_1",
        type: :task,
        type_data: %FlowNodeData.Task{},
        incoming: ["Flow_Out"]
      }

      process_model = %BpmnProcess{
        id: "proc-1",
        flow_nodes: [gateway, target],
        sequence_flows: [
          %SequenceFlow{id: "Flow_In", source_ref: "Start_1", target_ref: "Pass_1"},
          %SequenceFlow{id: "Flow_Out", source_ref: "Pass_1", target_ref: "Next_1"}
        ]
      }

      context = %HandlerContext{
        flow_node_instance_id: "fni-pass-1",
        process_instance_id: "pi-1",
        process_model: process_model
      }

      token = make_token()

      assert {:ok, %FlowNodeResult{next_flow_node_ids: ["Next_1"]}} =
               ParallelGateway.handle_enter(gateway, token, context)
    end
  end

  describe "join (converging)" do
    test "returns async tuple for join gateway" do
      {gateway, context} = build_join_context(["Task_A", "Task_B"], "Next_1")
      token = make_token()

      assert {:async, "fni-join-1", continuation, %{join_gateway: true}} =
               ParallelGateway.handle_enter(gateway, token, context)

      assert is_function(continuation, 0)
    end

    test "join with single incoming acts as pass-through (sync result)" do
      gateway = %FlowNode{
        id: "Join_1",
        name: "Join",
        type: :parallel_gateway,
        type_data: %FlowNodeData.ParallelGateway{},
        incoming: ["Flow_from_Task_A"],
        outgoing: ["Flow_to_Next_1"]
      }

      target_node = %FlowNode{
        id: "Next_1",
        type: :task,
        type_data: %FlowNodeData.Task{},
        incoming: ["Flow_to_Next_1"]
      }

      process_model = %BpmnProcess{
        id: "proc-1",
        flow_nodes: [gateway, target_node],
        sequence_flows: [
          %SequenceFlow{id: "Flow_from_Task_A", source_ref: "Task_A", target_ref: "Join_1"},
          %SequenceFlow{id: "Flow_to_Next_1", source_ref: "Join_1", target_ref: "Next_1"}
        ]
      }

      context = %HandlerContext{
        flow_node_instance_id: "fni-join-1",
        process_instance_id: "pi-1",
        process_model: process_model
      }

      token = make_token()

      assert {:ok, %FlowNodeResult{next_flow_node_ids: ["Next_1"]}} =
               ParallelGateway.handle_enter(gateway, token, context)
    end
  end

  describe "mixed gateway rejection" do
    test "returns error for gateway with multiple incoming AND outgoing" do
      {gateway, context} = build_mixed_context()
      token = make_token()

      assert {:error, %{reason: :mixed_gateway}} =
               ParallelGateway.handle_enter(gateway, token, context)
    end

    test "error includes flow counts" do
      {gateway, context} = build_mixed_context()
      token = make_token()

      assert {:error, error} = ParallelGateway.handle_enter(gateway, token, context)
      assert error.incoming_count == 2
      assert error.outgoing_count == 2
    end

    test "error includes flow node ID" do
      {gateway, context} = build_mixed_context()
      token = make_token()

      assert {:error, %{flow_node_id: "Mixed_1"}} =
               ParallelGateway.handle_enter(gateway, token, context)
    end
  end

  describe "dead-end (0 outgoing)" do
    test "returns error when fork has no outgoing flows" do
      gateway = %FlowNode{
        id: "Dead_1",
        name: "DeadEnd",
        type: :parallel_gateway,
        type_data: %FlowNodeData.ParallelGateway{},
        incoming: ["Flow_In"],
        outgoing: []
      }

      process_model = %BpmnProcess{
        id: "proc-1",
        flow_nodes: [gateway],
        sequence_flows: [
          %SequenceFlow{id: "Flow_In", source_ref: "Start_1", target_ref: "Dead_1"}
        ]
      }

      context = %HandlerContext{
        flow_node_instance_id: "fni-dead-1",
        process_instance_id: "pi-1",
        process_model: process_model
      }

      token = make_token()

      assert {:error, _reason} = ParallelGateway.handle_enter(gateway, token, context)
    end
  end
end

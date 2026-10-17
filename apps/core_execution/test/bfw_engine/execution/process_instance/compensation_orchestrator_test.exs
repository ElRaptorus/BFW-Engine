defmodule BfwEngine.Execution.ProcessInstance.CompensationOrchestratorTest do
  use ExUnit.Case, async: true

  alias BfwEngine.BPMN.Model.EventDefinition
  alias BfwEngine.BPMN.Model.FlowNode
  alias BfwEngine.BPMN.Model.FlowNodeData
  alias BfwEngine.Execution.ProcessInstance.CompensationOrchestrator

  defp build_target(id, completion_order) do
    %{
      completed_fni_id: "fni_#{id}",
      flow_node_id: "node_#{id}",
      handler_activity_id: "handler_#{id}",
      token_snapshot: %{"key" => "value_#{id}"},
      completion_order: completion_order
    }
  end

  defp build_run_with_targets(targets, opts \\ []) do
    throw_type = Keyword.get(opts, :throw_type, :throw)
    outgoing = Keyword.get(opts, :outgoing_flow_node_ids, ["Flow_out"])
    payload = Keyword.get(opts, :token_payload, %{"x" => 1})

    CompensationOrchestrator.build_run(targets, throw_type, outgoing, payload)
  end

  # ---------------------------------------------------------------------------
  # build_run/4
  # ---------------------------------------------------------------------------

  describe "build_run/4" do
    test "builds a broadcast run when targets has multiple entries" do
      targets = [build_target("a", 0), build_target("b", 1)]

      run = build_run_with_targets(targets)

      assert run.mode == :broadcast
    end

    test "builds a single run when targets has exactly one entry" do
      targets = [build_target("a", 0)]

      run = build_run_with_targets(targets)

      assert run.mode == :single
    end

    test "builds a broadcast run when targets is empty" do
      run = build_run_with_targets([])

      assert run.mode == :broadcast
    end

    test "preserves throw_type, outgoing_flow_node_ids, and token_payload" do
      targets = [build_target("a", 0)]
      outgoing = ["Flow_1", "Flow_2"]
      payload = %{"order" => "abc"}

      run =
        CompensationOrchestrator.build_run(targets, :end, outgoing, payload)

      assert run.throw_type == :end
      assert run.outgoing_flow_node_ids == ["Flow_1", "Flow_2"]
      assert run.token_payload == %{"order" => "abc"}
    end

    test "initializes cursor at 0" do
      run = build_run_with_targets([build_target("a", 0)])

      assert run.cursor == 0
    end
  end

  # ---------------------------------------------------------------------------
  # current_target/1
  # ---------------------------------------------------------------------------

  describe "current_target/1" do
    test "returns the first target when cursor is 0" do
      target_a = build_target("a", 0)
      target_b = build_target("b", 1)
      run = build_run_with_targets([target_a, target_b])

      assert CompensationOrchestrator.current_target(run) == target_a
    end

    test "returns the second target after one advance" do
      target_a = build_target("a", 0)
      target_b = build_target("b", 1)

      run =
        [target_a, target_b]
        |> build_run_with_targets()
        |> CompensationOrchestrator.advance_cursor()

      assert CompensationOrchestrator.current_target(run) == target_b
    end

    test "returns nil when cursor is past the end of the queue" do
      run =
        [build_target("a", 0)]
        |> build_run_with_targets()
        |> CompensationOrchestrator.advance_cursor()

      assert CompensationOrchestrator.current_target(run) == nil
    end

    test "returns nil for an empty queue" do
      run = build_run_with_targets([])

      assert CompensationOrchestrator.current_target(run) == nil
    end
  end

  # ---------------------------------------------------------------------------
  # advance_cursor/1
  # ---------------------------------------------------------------------------

  describe "advance_cursor/1" do
    test "increments cursor by one" do
      run = build_run_with_targets([build_target("a", 0), build_target("b", 1)])

      advanced = CompensationOrchestrator.advance_cursor(run)

      assert advanced.cursor == 1
    end

    test "can advance past the end of the queue" do
      run =
        [build_target("a", 0)]
        |> build_run_with_targets()
        |> CompensationOrchestrator.advance_cursor()
        |> CompensationOrchestrator.advance_cursor()

      assert run.cursor == 2
    end
  end

  # ---------------------------------------------------------------------------
  # run_complete?/1
  # ---------------------------------------------------------------------------

  describe "run_complete?/1" do
    test "returns false when cursor is before the end" do
      run = build_run_with_targets([build_target("a", 0), build_target("b", 1)])

      refute CompensationOrchestrator.run_complete?(run)
    end

    test "returns true when cursor equals the queue length" do
      run =
        [build_target("a", 0)]
        |> build_run_with_targets()
        |> CompensationOrchestrator.advance_cursor()

      assert CompensationOrchestrator.run_complete?(run)
    end

    test "returns true when cursor exceeds the queue length" do
      run =
        [build_target("a", 0)]
        |> build_run_with_targets()
        |> CompensationOrchestrator.advance_cursor()
        |> CompensationOrchestrator.advance_cursor()

      assert CompensationOrchestrator.run_complete?(run)
    end

    test "returns true for an empty queue with cursor 0" do
      run = build_run_with_targets([])

      assert CompensationOrchestrator.run_complete?(run)
    end
  end

  # ---------------------------------------------------------------------------
  # expand_targets/2
  # ---------------------------------------------------------------------------

  describe "expand_targets/2" do
    defp compensation_model_data(flow_node_instance_states) do
      flow_nodes = [
        %FlowNode{
          id: "Task_Book",
          type: :task,
          type_data: %FlowNodeData.Task{},
          boundary_event_refs: ["BE_Comp_Book"]
        },
        %FlowNode{
          id: "BE_Comp_Book",
          type: :boundary_event,
          type_data: %FlowNodeData.BoundaryEvent{
            attached_to_ref: "Task_Book",
            event_definition: %EventDefinition.Compensation{},
            compensation_handler_id: "Task_Undo_Book"
          }
        },
        %FlowNode{
          id: "SubProcess_Booking",
          type: :sub_process,
          type_data: %FlowNodeData.SubProcess{triggered_by_event: false}
        },
        %FlowNode{
          id: "Call_Fulfill",
          type: :call_activity,
          type_data: %FlowNodeData.CallActivity{called_element: "fulfill"}
        }
      ]

      %{
        process_instance_id: "parent",
        process_model: %{flow_nodes: flow_nodes},
        flow_node_instance_states: flow_node_instance_states
      }
    end

    defp registry_entry(flow_node_id, completed_fni_id, completion_order) do
      %{
        completed_fni_id: completed_fni_id,
        flow_node_id: flow_node_id,
        handler_activity_id: nil,
        token_snapshot: %{"from" => flow_node_id},
        completion_order: completion_order
      }
    end

    test "turns a handler-less embedded subprocess into a scope target naming its child instance" do
      data =
        compensation_model_data(%{
          "fni_sub" => %{type_properties: %{"child_process_instance_id" => "child-1"}}
        })

      assert [target] =
               CompensationOrchestrator.expand_targets(data, [
                 registry_entry("SubProcess_Booking", "fni_sub", 3)
               ])

      assert target == %{
               kind: :scope,
               completed_fni_id: "fni_sub",
               flow_node_id: "SubProcess_Booking",
               child_process_instance_id: "child-1",
               subprocess_node_id: "SubProcess_Booking",
               handler_activity_id: nil,
               token_snapshot: %{"from" => "SubProcess_Booking"},
               completion_order: 3
             }
    end

    test "keeps an activity with its own handler as a handler target, in the order given" do
      data =
        compensation_model_data(%{
          "fni_sub" => %{type_properties: %{child_process_instance_id: "child-1"}}
        })

      assert [scope_target, handler_target] =
               CompensationOrchestrator.expand_targets(data, [
                 registry_entry("SubProcess_Booking", "fni_sub", 2),
                 registry_entry("Task_Book", "fni_book", 1)
               ])

      assert scope_target.kind == :scope
      assert scope_target.child_process_instance_id == "child-1"
      refute Map.has_key?(handler_target, :kind)
      assert handler_target.completed_fni_id == "fni_book"
      assert handler_target.handler_activity_id == "Task_Undo_Book"
    end

    test "drops a subprocess without a child instance and a Call Activity without a handler" do
      data = compensation_model_data(%{})

      assert CompensationOrchestrator.expand_targets(data, [
               registry_entry("SubProcess_Booking", "fni_sub", 2),
               registry_entry("Call_Fulfill", "fni_call", 1)
             ]) == []
    end
  end
end

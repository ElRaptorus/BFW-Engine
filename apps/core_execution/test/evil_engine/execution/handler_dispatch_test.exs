defmodule EvilEngine.Execution.HandlerDispatchTest do
  use ExUnit.Case, async: true

  alias EvilEngine.BPMN.Model.EventDefinition
  alias EvilEngine.BPMN.Model.FlowNode
  alias EvilEngine.BPMN.Model.FlowNodeData
  alias EvilEngine.BPMN.Model.MultiInstance
  alias EvilEngine.BPMN.Model.StandardLoop
  alias EvilEngine.Execution.FlowNodes
  alias EvilEngine.Execution.HandlerDispatch

  describe "handler_for/1 with atom (legacy fallback)" do
    test "known types return their handler module" do
      assert {:ok, FlowNodes.StartEvent} == HandlerDispatch.handler_for(:start_event)
      assert {:ok, FlowNodes.EndEvent} == HandlerDispatch.handler_for(:end_event)
      assert {:ok, FlowNodes.Task} == HandlerDispatch.handler_for(:task)

      assert {:ok, FlowNodes.IntermediateEvent} ==
               HandlerDispatch.handler_for(:intermediate_catch_event)

      assert {:ok, FlowNodes.IntermediateEvent} ==
               HandlerDispatch.handler_for(:intermediate_throw_event)

      assert {:ok, FlowNodes.ManualTask} == HandlerDispatch.handler_for(:manual_task)
      assert {:ok, FlowNodes.UserTask} == HandlerDispatch.handler_for(:user_task)
      assert {:ok, FlowNodes.ServiceTask} == HandlerDispatch.handler_for(:service_task)
      assert {:ok, FlowNodes.ExclusiveGateway} == HandlerDispatch.handler_for(:exclusive_gateway)
      assert {:ok, FlowNodes.CallActivity} == HandlerDispatch.handler_for(:call_activity)
      assert {:ok, FlowNodes.BoundaryEvent} == HandlerDispatch.handler_for(:boundary_event)

      assert {:ok, FlowNodes.BusinessRuleTask} ==
               HandlerDispatch.handler_for(:business_rule_task)
    end

    test "unknown type returns {:error, :unsupported_element}" do
      assert {:error, :unsupported_element} == HandlerDispatch.handler_for(:nonexistent)
    end

    test "parallel_gateway type returns ParallelGateway handler" do
      assert {:ok, FlowNodes.ParallelGateway} ==
               HandlerDispatch.handler_for(:parallel_gateway)
    end
  end

  describe "handler_for/1 with %FlowNode{}" do
    test "Link Throw event routes to LinkThrowEvent handler" do
      flow_node = %FlowNode{
        id: "throw-1",
        type: :intermediate_throw_event,
        type_data: %FlowNodeData.IntermediateThrowEvent{
          event_definition: %EventDefinition.Link{link_name: "A"}
        }
      }

      assert {:ok, FlowNodes.LinkThrowEvent} == HandlerDispatch.handler_for(flow_node)
    end

    test "Link Catch event routes to LinkCatchEvent handler" do
      flow_node = %FlowNode{
        id: "catch-1",
        type: :intermediate_catch_event,
        type_data: %FlowNodeData.IntermediateCatchEvent{
          event_definition: %EventDefinition.Link{link_name: "A"}
        }
      }

      assert {:ok, FlowNodes.LinkCatchEvent} == HandlerDispatch.handler_for(flow_node)
    end

    test "untyped intermediate catch event falls through to IntermediateEvent" do
      flow_node = %FlowNode{
        id: "catch-untyped",
        type: :intermediate_catch_event,
        type_data: %FlowNodeData.IntermediateCatchEvent{
          event_definition: %EventDefinition.None{}
        }
      }

      assert {:ok, FlowNodes.IntermediateEvent} == HandlerDispatch.handler_for(flow_node)
    end

    test "untyped intermediate throw event falls through to IntermediateEvent" do
      flow_node = %FlowNode{
        id: "throw-untyped",
        type: :intermediate_throw_event,
        type_data: %FlowNodeData.IntermediateThrowEvent{
          event_definition: %EventDefinition.None{}
        }
      }

      assert {:ok, FlowNodes.IntermediateEvent} == HandlerDispatch.handler_for(flow_node)
    end

    test "non-intermediate FlowNode routes via static type map" do
      flow_node = %FlowNode{
        id: "start-1",
        type: :start_event,
        type_data: %FlowNodeData.StartEvent{}
      }

      assert {:ok, FlowNodes.StartEvent} == HandlerDispatch.handler_for(flow_node)
    end

    test "Timer catch event routes to TimerCatchEvent handler" do
      flow_node = %FlowNode{
        id: "timer-catch-1",
        type: :intermediate_catch_event,
        type_data: %FlowNodeData.IntermediateCatchEvent{
          event_definition: %EventDefinition.Timer{time_duration: "PT1H"}
        }
      }

      assert {:ok, FlowNodes.TimerCatchEvent} == HandlerDispatch.handler_for(flow_node)
    end

    test "Timer boundary event routes to TimerBoundaryEvent handler" do
      flow_node = %FlowNode{
        id: "timer-be-1",
        type: :boundary_event,
        type_data: %FlowNodeData.BoundaryEvent{
          attached_to_ref: "Task_1",
          cancel_activity: true,
          event_definition: %EventDefinition.Timer{time_duration: "PT1H"}
        }
      }

      assert {:ok, FlowNodes.TimerBoundaryEvent} == HandlerDispatch.handler_for(flow_node)
    end

    test "Error boundary event routes to ErrorBoundaryEvent handler" do
      flow_node = %FlowNode{
        id: "error-be-1",
        type: :boundary_event,
        type_data: %FlowNodeData.BoundaryEvent{
          attached_to_ref: "Task_1",
          cancel_activity: true,
          event_definition: %EventDefinition.Error{error_code: "ERR"}
        }
      }

      assert {:ok, FlowNodes.ErrorBoundaryEvent} == HandlerDispatch.handler_for(flow_node)
    end

    test "Timer start event routes to TimerStartEvent handler" do
      flow_node = %FlowNode{
        id: "timer-start-1",
        type: :start_event,
        type_data: %FlowNodeData.StartEvent{
          event_definition: %EventDefinition.Timer{time_duration: "PT1H"}
        }
      }

      assert {:ok, FlowNodes.TimerStartEvent} == HandlerDispatch.handler_for(flow_node)
    end

    test "Timer start event with cycle routes to TimerStartEvent handler" do
      flow_node = %FlowNode{
        id: "timer-start-cycle",
        type: :start_event,
        type_data: %FlowNodeData.StartEvent{
          event_definition: %EventDefinition.Timer{time_cycle: "R3/PT1H"}
        }
      }

      assert {:ok, FlowNodes.TimerStartEvent} == HandlerDispatch.handler_for(flow_node)
    end

    test "Terminate end event routes to TerminateEndEvent handler" do
      flow_node = %FlowNode{
        id: "terminate-end-1",
        type: :end_event,
        type_data: %FlowNodeData.EndEvent{
          event_definition: %EventDefinition.Terminate{}
        }
      }

      assert {:ok, FlowNodes.TerminateEndEvent} == HandlerDispatch.handler_for(flow_node)
    end

    test "Error end event routes to ErrorEndEvent handler" do
      flow_node = %FlowNode{
        id: "error-end-1",
        type: :end_event,
        type_data: %FlowNodeData.EndEvent{
          event_definition: %EventDefinition.Error{
            error_code: "VALIDATION_FAILED",
            error_message: "Input invalid"
          }
        }
      }

      assert {:ok, FlowNodes.ErrorEndEvent} == HandlerDispatch.handler_for(flow_node)
    end

    test "Error end event with error_ref routes to ErrorEndEvent handler" do
      flow_node = %FlowNode{
        id: "error-end-ref",
        type: :end_event,
        type_data: %FlowNodeData.EndEvent{
          event_definition: %EventDefinition.Error{
            error_ref: "Err_1"
          }
        }
      }

      assert {:ok, FlowNodes.ErrorEndEvent} == HandlerDispatch.handler_for(flow_node)
    end

    test "Error end event with no properties routes to ErrorEndEvent handler" do
      flow_node = %FlowNode{
        id: "error-end-catchall",
        type: :end_event,
        type_data: %FlowNodeData.EndEvent{
          event_definition: %EventDefinition.Error{}
        }
      }

      assert {:ok, FlowNodes.ErrorEndEvent} == HandlerDispatch.handler_for(flow_node)
    end

    test "Untyped end event falls through to EndEvent handler" do
      flow_node = %FlowNode{
        id: "end-1",
        type: :end_event,
        type_data: %FlowNodeData.EndEvent{
          event_definition: %EventDefinition.None{}
        }
      }

      assert {:ok, FlowNodes.EndEvent} == HandlerDispatch.handler_for(flow_node)
    end

    test "parallel_gateway FlowNode routes to ParallelGateway handler" do
      flow_node = %FlowNode{
        id: "pg-1",
        type: :parallel_gateway,
        type_data: %FlowNodeData.ParallelGateway{}
      }

      assert {:ok, FlowNodes.ParallelGateway} == HandlerDispatch.handler_for(flow_node)
    end

    test "complex_gateway FlowNode routes to ComplexGateway handler" do
      flow_node = %FlowNode{
        id: "cg-1",
        type: :complex_gateway,
        type_data: %FlowNodeData.ComplexGateway{}
      }

      assert {:ok, FlowNodes.ComplexGateway} == HandlerDispatch.handler_for(flow_node)
    end

    test "multi-instance FlowNode routes to MultiInstanceBody handler" do
      flow_node = %FlowNode{
        id: "task-mi-1",
        type: :task,
        type_data: %FlowNodeData.Task{},
        multi_instance: %MultiInstance{is_sequential: false}
      }

      assert {:ok, FlowNodes.MultiInstanceBody} == HandlerDispatch.handler_for(flow_node)
    end

    test "sequential multi-instance FlowNode routes to MultiInstanceBody handler" do
      flow_node = %FlowNode{
        id: "task-mi-seq",
        type: :service_task,
        type_data: %FlowNodeData.ServiceTask{implementation: "http"},
        multi_instance: %MultiInstance{is_sequential: true}
      }

      assert {:ok, FlowNodes.MultiInstanceBody} == HandlerDispatch.handler_for(flow_node)
    end

    test "standard loop FlowNode routes to StandardLoopBody handler" do
      flow_node = %FlowNode{
        id: "task-loop-1",
        type: :script_task,
        type_data: %FlowNodeData.ScriptTask{script: "1 + 1", script_format: "feel"},
        standard_loop: %StandardLoop{test_before: true, loop_condition: "token.x < 5"}
      }

      assert {:ok, FlowNodes.StandardLoopBody} == HandlerDispatch.handler_for(flow_node)
    end

    test "compensation throw event routes to CompensateThrowEvent handler" do
      flow_node = %FlowNode{
        id: "Throw_Compensation",
        type: :intermediate_throw_event,
        type_data: %FlowNodeData.IntermediateThrowEvent{
          event_definition: %EventDefinition.Compensation{}
        }
      }

      assert {:ok, FlowNodes.CompensateThrowEvent} =
               HandlerDispatch.handler_for(flow_node)
    end

    test "compensation end event routes to CompensateEndEvent handler" do
      flow_node = %FlowNode{
        id: "End_Compensation",
        type: :end_event,
        type_data: %FlowNodeData.EndEvent{
          event_definition: %EventDefinition.Compensation{}
        }
      }

      assert {:ok, FlowNodes.CompensateEndEvent} =
               HandlerDispatch.handler_for(flow_node)
    end

    test "compensation boundary event routes to CompensationBoundaryEvent handler" do
      flow_node = %FlowNode{
        id: "Boundary_Compensation",
        type: :boundary_event,
        type_data: %FlowNodeData.BoundaryEvent{
          attached_to_ref: "Task_1",
          event_definition: %EventDefinition.Compensation{}
        }
      }

      assert {:ok, FlowNodes.CompensationBoundaryEvent} =
               HandlerDispatch.handler_for(flow_node)
    end

    test "escalation throw event routes to EscalationIntermediateThrowEvent handler" do
      flow_node = %FlowNode{
        id: "Throw_Escalation",
        type: :intermediate_throw_event,
        type_data: %FlowNodeData.IntermediateThrowEvent{
          event_definition: %EventDefinition.Escalation{escalation_ref: "Escalation_1"}
        }
      }

      assert {:ok, FlowNodes.EscalationIntermediateThrowEvent} =
               HandlerDispatch.handler_for(flow_node)
    end

    test "escalation end event routes to EscalationEndEvent handler" do
      flow_node = %FlowNode{
        id: "End_Escalation",
        type: :end_event,
        type_data: %FlowNodeData.EndEvent{
          event_definition: %EventDefinition.Escalation{escalation_ref: "Escalation_1"}
        }
      }

      assert {:ok, FlowNodes.EscalationEndEvent} = HandlerDispatch.handler_for(flow_node)
    end

    test "escalation boundary event routes to EscalationBoundaryEvent handler" do
      flow_node = %FlowNode{
        id: "BE_Escalation",
        type: :boundary_event,
        type_data: %FlowNodeData.BoundaryEvent{
          attached_to_ref: "Task_1",
          cancel_activity: true,
          event_definition: %EventDefinition.Escalation{escalation_ref: nil}
        }
      }

      assert {:ok, FlowNodes.EscalationBoundaryEvent} = HandlerDispatch.handler_for(flow_node)
    end

    test "cancel end event routes to CancelEndEvent handler" do
      flow_node = %FlowNode{
        id: "End_Cancel",
        type: :end_event,
        type_data: %FlowNodeData.EndEvent{
          event_definition: %EventDefinition.Cancel{}
        }
      }

      assert {:ok, FlowNodes.CancelEndEvent} = HandlerDispatch.handler_for(flow_node)
    end

    test "cancel boundary event routes to CancelBoundaryEvent handler" do
      flow_node = %FlowNode{
        id: "Boundary_Cancel",
        type: :boundary_event,
        type_data: %FlowNodeData.BoundaryEvent{
          event_definition: %EventDefinition.Cancel{},
          attached_to_ref: "Transaction_1",
          cancel_activity: true
        }
      }

      assert {:ok, FlowNodes.CancelBoundaryEvent} = HandlerDispatch.handler_for(flow_node)
    end

    test "conditional catch event routes to ConditionalCatchEvent handler" do
      flow_node = %FlowNode{
        id: "Catch_Conditional",
        type: :intermediate_catch_event,
        type_data: %FlowNodeData.IntermediateCatchEvent{
          event_definition: %EventDefinition.Conditional{
            condition_expression: "token.ready = true"
          }
        }
      }

      assert {:ok, EvilEngine.Execution.FlowNodes.ConditionalCatchEvent} =
               HandlerDispatch.handler_for(flow_node)
    end
  end
end

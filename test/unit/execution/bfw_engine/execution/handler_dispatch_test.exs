defmodule BfwEngine.Execution.HandlerDispatchTest do
  use ExUnit.Case, async: true

  alias BfwEngine.BPMN.Model.EventDefinition
  alias BfwEngine.BPMN.Model.FlowNode
  alias BfwEngine.BPMN.Model.FlowNodeData
  alias BfwEngine.BPMN.Model.MultiInstance
  alias BfwEngine.BPMN.Model.StandardLoop
  alias BfwEngine.Execution.FlowNodes
  alias BfwEngine.Execution.HandlerDispatch

  describe "handler_for/1 with plain flow nodes" do
    test "known types return their handler module" do
      expectations = [
        start_event: FlowNodes.StartEvent,
        end_event: FlowNodes.EndEvent,
        task: FlowNodes.Task,
        intermediate_catch_event: FlowNodes.IntermediateEvent,
        intermediate_throw_event: FlowNodes.IntermediateEvent,
        manual_task: FlowNodes.ManualTask,
        user_task: FlowNodes.UserTask,
        service_task: FlowNodes.ServiceTask,
        exclusive_gateway: FlowNodes.ExclusiveGateway,
        call_activity: FlowNodes.CallActivity,
        boundary_event: FlowNodes.BoundaryEvent,
        business_rule_task: FlowNodes.BusinessRuleTask,
        parallel_gateway: FlowNodes.ParallelGateway
      ]

      for {type, handler} <- expectations do
        assert {:ok, handler} ==
                 HandlerDispatch.handler_for(%FlowNode{id: "node", type: type, type_data: nil})
      end
    end

    test "unknown type returns {:error, :unsupported_element}" do
      assert {:error, :unsupported_element} ==
               HandlerDispatch.handler_for(%FlowNode{
                 id: "node",
                 type: :nonexistent,
                 type_data: nil
               })
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

      assert {:ok, BfwEngine.Execution.FlowNodes.ConditionalCatchEvent} =
               HandlerDispatch.handler_for(flow_node)
    end

    test "ad-hoc subprocess routes to AdHocSubProcess handler" do
      flow_node = %FlowNode{
        id: "adhoc-sp-1",
        type: :sub_process,
        type_data: %FlowNodeData.SubProcess{
          triggered_by_event: false,
          is_ad_hoc: true
        }
      }

      assert {:ok, FlowNodes.AdHocSubProcess} == HandlerDispatch.handler_for(flow_node)
    end

    test "ad-hoc takes priority over event subprocess flag" do
      flow_node = %FlowNode{
        id: "adhoc-sp-2",
        type: :sub_process,
        type_data: %FlowNodeData.SubProcess{
          triggered_by_event: false,
          is_ad_hoc: true,
          is_transaction: false
        }
      }

      assert {:ok, FlowNodes.AdHocSubProcess} == HandlerDispatch.handler_for(flow_node)
    end

    test "transaction takes priority over ad-hoc flag" do
      flow_node = %FlowNode{
        id: "tx-adhoc",
        type: :sub_process,
        type_data: %FlowNodeData.SubProcess{
          is_transaction: true,
          is_ad_hoc: true
        }
      }

      assert {:ok, FlowNodes.TransactionSubProcess} == HandlerDispatch.handler_for(flow_node)
    end
  end
end

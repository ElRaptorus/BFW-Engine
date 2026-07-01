defmodule EvilEngine.Execution.BoundaryAwareHandlerTest do
  use ExUnit.Case, async: true

  alias EvilEngine.BPMN.Model.EventDefinition
  alias EvilEngine.BPMN.Model.FlowNode
  alias EvilEngine.BPMN.Model.FlowNodeData
  alias EvilEngine.BPMN.Model.Process, as: BpmnProcess
  alias EvilEngine.BPMN.Model.SequenceFlow
  alias EvilEngine.Execution.BoundaryAwareHandler
  alias EvilEngine.Execution.FlowNodeResult
  alias EvilEngine.Execution.HandlerContext
  alias EvilEngine.Types.Token

  # -- Test handler modules that return predetermined results --

  defmodule OkHandler do
    @behaviour EvilEngine.Execution.FlowNodeHandler
    @impl true
    def handle_enter(_flow_node, _token, _context) do
      {:ok, %FlowNodeResult{output_payload: %{done: true}, next_flow_node_ids: ["End_1"]}}
    end
  end

  defmodule WaitHandler do
    @behaviour EvilEngine.Execution.FlowNodeHandler
    @impl true
    def handle_enter(_flow_node, _token, _context) do
      {:wait, %FlowNodeResult{output_payload: %{}, next_flow_node_ids: ["End_1"]}}
    end
  end

  defmodule AsyncHandler do
    @behaviour EvilEngine.Execution.FlowNodeHandler
    @impl true
    def handle_enter(_flow_node, _token, context) do
      {:async, context.flow_node_instance_id}
    end
  end

  defmodule AsyncWithContinuationHandler do
    @behaviour EvilEngine.Execution.FlowNodeHandler
    @impl true
    def handle_enter(_flow_node, _token, context) do
      continuation = fn -> {:ok, %FlowNodeResult{output_payload: %{}, next_flow_node_ids: []}} end
      {:async, context.flow_node_instance_id, continuation}
    end
  end

  defmodule AsyncWithTypePropsHandler do
    @behaviour EvilEngine.Execution.FlowNodeHandler
    @impl true
    def handle_enter(_flow_node, _token, context) do
      continuation = fn -> {:ok, %FlowNodeResult{output_payload: %{}, next_flow_node_ids: []}} end
      {:async, context.flow_node_instance_id, continuation, %{child_id: "abc"}}
    end
  end

  defmodule ErrorStringHandler do
    @behaviour EvilEngine.Execution.FlowNodeHandler
    @impl true
    def handle_enter(_flow_node, _token, _context) do
      {:error, "something went wrong"}
    end
  end

  defmodule ErrorTupleHandler do
    @behaviour EvilEngine.Execution.FlowNodeHandler
    @impl true
    def handle_enter(_flow_node, _token, _context) do
      {:error, {:missing_implementation, nil}}
    end
  end

  defmodule ErrorStructuredHandler do
    @behaviour EvilEngine.Execution.FlowNodeHandler
    @impl true
    def handle_enter(_flow_node, _token, _context) do
      {:error, %{error_code: "CHILD_FATAL", error_message: "child process crashed"}}
    end
  end

  defmodule BoundaryHandler do
    @behaviour EvilEngine.Execution.FlowNodeHandler
    @impl true
    def handle_enter(_flow_node, _token, _context) do
      {:boundary, "BE_1", %{error_code: "ERR"}, true}
    end
  end

  # -- Helpers ----------------------------------------------------------------

  defp make_token(payload \\ %{}) do
    %Token{id: "token-1", process_instance_id: "pi-1", payload: payload}
  end

  defp make_context(process_model \\ nil) do
    %HandlerContext{
      flow_node_instance_id: "fni-1",
      process_instance_id: "pi-1",
      process_model: process_model
    }
  end

  defp service_task_node(opts \\ []) do
    boundary_refs = Keyword.get(opts, :boundary_refs, [])

    %FlowNode{
      id: "ServiceTask_1",
      type: :service_task,
      type_data: %FlowNodeData.ServiceTask{implementation: "echo"},
      incoming: ["Flow_1"],
      outgoing: ["Flow_2"],
      boundary_event_refs: boundary_refs
    }
  end

  defp user_task_node(opts) do
    boundary_refs = Keyword.get(opts, :boundary_refs, [])

    %FlowNode{
      id: "UserTask_1",
      type: :user_task,
      type_data: %FlowNodeData.UserTask{form_schema: %{"fields" => []}},
      incoming: ["Flow_1"],
      outgoing: ["Flow_2"],
      boundary_event_refs: boundary_refs
    }
  end

  defp script_task_node(opts) do
    boundary_refs = Keyword.get(opts, :boundary_refs, [])

    %FlowNode{
      id: "ScriptTask_1",
      type: :script_task,
      type_data: %FlowNodeData.ScriptTask{script: "1 + 1"},
      incoming: ["Flow_1"],
      outgoing: ["Flow_2"],
      boundary_event_refs: boundary_refs
    }
  end

  defp business_rule_task_node(opts) do
    boundary_refs = Keyword.get(opts, :boundary_refs, [])

    %FlowNode{
      id: "BRT_1",
      type: :business_rule_task,
      type_data: %FlowNodeData.BusinessRuleTask{implementation: "feel", script: "1 + 1"},
      incoming: ["Flow_1"],
      outgoing: ["Flow_2"],
      boundary_event_refs: boundary_refs
    }
  end

  defp call_activity_node(opts) do
    boundary_refs = Keyword.get(opts, :boundary_refs, [])

    %FlowNode{
      id: "CA_1",
      type: :call_activity,
      type_data: %FlowNodeData.CallActivity{called_element: "child-process"},
      incoming: ["Flow_1"],
      outgoing: ["Flow_2"],
      boundary_event_refs: boundary_refs
    }
  end

  defp gateway_node do
    %FlowNode{
      id: "XOR_1",
      type: :exclusive_gateway,
      type_data: %FlowNodeData.ExclusiveGateway{},
      incoming: ["Flow_1"],
      outgoing: ["Flow_2"]
    }
  end

  defp start_event_node do
    %FlowNode{
      id: "Start_1",
      type: :start_event,
      type_data: %FlowNodeData.StartEvent{event_definition: %EventDefinition.None{}},
      outgoing: ["Flow_1"]
    }
  end

  defp error_boundary_node(id, opts \\ []) do
    %FlowNode{
      id: id,
      type: :boundary_event,
      type_data: %FlowNodeData.BoundaryEvent{
        attached_to_ref: Keyword.get(opts, :attached_to, "ServiceTask_1"),
        cancel_activity: Keyword.get(opts, :cancel_activity, true),
        event_definition: %EventDefinition.Error{
          error_code: Keyword.get(opts, :error_code, nil),
          error_message: Keyword.get(opts, :error_message, nil)
        }
      },
      outgoing: ["Flow_BE"]
    }
  end

  defp timer_boundary_node(id, opts \\ []) do
    %FlowNode{
      id: id,
      type: :boundary_event,
      type_data: %FlowNodeData.BoundaryEvent{
        attached_to_ref: Keyword.get(opts, :attached_to, "ServiceTask_1"),
        cancel_activity: true,
        event_definition: %EventDefinition.Timer{time_duration: "PT1H"}
      },
      outgoing: ["Flow_BE"]
    }
  end

  defp build_model(nodes) do
    %BpmnProcess{
      id: "test-process",
      flow_nodes: nodes,
      sequence_flows: [
        %SequenceFlow{id: "Flow_1", source_ref: "Start_1", target_ref: "ServiceTask_1"},
        %SequenceFlow{id: "Flow_2", source_ref: "ServiceTask_1", target_ref: "End_1"},
        %SequenceFlow{id: "Flow_BE", source_ref: "BE_1", target_ref: "End_Error"}
      ]
    }
  end

  # -- Tests: pass-through shapes ---------------------------------------------

  describe "wrap_enter/4 pass-through" do
    test "{:ok, result} passes through unchanged" do
      flow_node = service_task_node()

      assert {:ok, %FlowNodeResult{output_payload: %{done: true}}} =
               BoundaryAwareHandler.wrap_enter(OkHandler, flow_node, make_token(), make_context())
    end

    test "{:wait, result} passes through unchanged" do
      flow_node = service_task_node()

      assert {:wait, %FlowNodeResult{}} =
               BoundaryAwareHandler.wrap_enter(
                 WaitHandler,
                 flow_node,
                 make_token(),
                 make_context()
               )
    end

    test "{:async, fni_id} passes through unchanged" do
      flow_node = service_task_node()

      assert {:async, "fni-1"} =
               BoundaryAwareHandler.wrap_enter(
                 AsyncHandler,
                 flow_node,
                 make_token(),
                 make_context()
               )
    end

    test "{:async, fni_id, continuation} passes through unchanged" do
      flow_node = service_task_node()

      assert {:async, "fni-1", continuation} =
               BoundaryAwareHandler.wrap_enter(
                 AsyncWithContinuationHandler,
                 flow_node,
                 make_token(),
                 make_context()
               )

      assert is_function(continuation, 0)
    end

    test "{:async, fni_id, continuation, type_properties} passes through unchanged" do
      flow_node = service_task_node()

      assert {:async, "fni-1", continuation, %{child_id: "abc"}} =
               BoundaryAwareHandler.wrap_enter(
                 AsyncWithTypePropsHandler,
                 flow_node,
                 make_token(),
                 make_context()
               )

      assert is_function(continuation, 0)
    end

    test "{:boundary, ...} passes through unchanged" do
      flow_node = service_task_node()

      assert {:boundary, "BE_1", %{error_code: "ERR"}, true} =
               BoundaryAwareHandler.wrap_enter(
                 BoundaryHandler,
                 flow_node,
                 make_token(),
                 make_context()
               )
    end
  end

  # -- Tests: error on non-activity types (skip boundary check) ---------------

  describe "wrap_enter/4 non-activity types" do
    test "{:error, ...} on a gateway passes through unchanged" do
      flow_node = gateway_node()

      assert {:error, "something went wrong"} =
               BoundaryAwareHandler.wrap_enter(
                 ErrorStringHandler,
                 flow_node,
                 make_token(),
                 make_context()
               )
    end

    test "{:error, ...} on a start event passes through unchanged" do
      flow_node = start_event_node()

      assert {:error, "something went wrong"} =
               BoundaryAwareHandler.wrap_enter(
                 ErrorStringHandler,
                 flow_node,
                 make_token(),
                 make_context()
               )
    end
  end

  # -- Tests: error on activity without boundary refs -------------------------

  describe "wrap_enter/4 activity without boundary refs" do
    test "{:error, ...} on activity with empty boundary_event_refs passes through" do
      flow_node = service_task_node(boundary_refs: [])

      assert {:error, "something went wrong"} =
               BoundaryAwareHandler.wrap_enter(
                 ErrorStringHandler,
                 flow_node,
                 make_token(),
                 make_context()
               )
    end

    test "{:error, ...} on activity with nil boundary_event_refs passes through" do
      flow_node = %{service_task_node() | boundary_event_refs: nil}

      assert {:error, "something went wrong"} =
               BoundaryAwareHandler.wrap_enter(
                 ErrorStringHandler,
                 flow_node,
                 make_token(),
                 make_context()
               )
    end
  end

  # -- Tests: error on activity with only non-error boundaries ----------------

  describe "wrap_enter/4 activity with only timer boundaries" do
    test "{:error, ...} passes through when only timer boundaries are attached" do
      timer_be = timer_boundary_node("TimerBE_1")
      flow_node = service_task_node(boundary_refs: ["TimerBE_1"])
      model = build_model([flow_node, timer_be])

      assert {:error, "something went wrong"} =
               BoundaryAwareHandler.wrap_enter(
                 ErrorStringHandler,
                 flow_node,
                 make_token(),
                 make_context(model)
               )
    end
  end

  # -- Tests: error on activity with matching error boundary ------------------

  describe "wrap_enter/4 activity with matching error boundary" do
    test "catch-all error boundary converts {:error, ...} to {:boundary, ...}" do
      catch_all_be = error_boundary_node("BE_1")
      flow_node = service_task_node(boundary_refs: ["BE_1"])
      model = build_model([flow_node, catch_all_be])

      assert {:boundary, "BE_1", error_info, true} =
               BoundaryAwareHandler.wrap_enter(
                 ErrorStringHandler,
                 flow_node,
                 make_token(),
                 make_context(model)
               )

      assert error_info.error_code == "HANDLER_ERROR"
      assert error_info.error_message == "something went wrong"
    end

    test "code-matching error boundary catches {:error, ...} with structured error" do
      specific_be = error_boundary_node("BE_1", error_code: "CHILD_FATAL")
      flow_node = service_task_node(boundary_refs: ["BE_1"])
      model = build_model([flow_node, specific_be])

      assert {:boundary, "BE_1", error_info, true} =
               BoundaryAwareHandler.wrap_enter(
                 ErrorStructuredHandler,
                 flow_node,
                 make_token(),
                 make_context(model)
               )

      assert error_info.error_code == "CHILD_FATAL"
      assert error_info.error_message == "child process crashed"
    end

    test "non-matching error boundary lets {:error, ...} pass through" do
      specific_be = error_boundary_node("BE_1", error_code: "WRONG_CODE")
      flow_node = service_task_node(boundary_refs: ["BE_1"])
      model = build_model([flow_node, specific_be])

      assert {:error, "something went wrong"} =
               BoundaryAwareHandler.wrap_enter(
                 ErrorStringHandler,
                 flow_node,
                 make_token(),
                 make_context(model)
               )
    end

    test "non-interrupting boundary sets cancel_activity to false" do
      non_interrupting_be = error_boundary_node("BE_1", cancel_activity: false)
      flow_node = service_task_node(boundary_refs: ["BE_1"])
      model = build_model([flow_node, non_interrupting_be])

      assert {:boundary, "BE_1", _error_info, false} =
               BoundaryAwareHandler.wrap_enter(
                 ErrorStringHandler,
                 flow_node,
                 make_token(),
                 make_context(model)
               )
    end

    test "interrupting boundary sets cancel_activity to true" do
      interrupting_be = error_boundary_node("BE_1", cancel_activity: true)
      flow_node = service_task_node(boundary_refs: ["BE_1"])
      model = build_model([flow_node, interrupting_be])

      assert {:boundary, "BE_1", _error_info, true} =
               BoundaryAwareHandler.wrap_enter(
                 ErrorStringHandler,
                 flow_node,
                 make_token(),
                 make_context(model)
               )
    end
  end

  # -- Tests: various activity types ------------------------------------------

  describe "wrap_enter/4 across activity types" do
    test "works on user_task" do
      catch_all_be = error_boundary_node("BE_1", attached_to: "UserTask_1")
      flow_node = user_task_node(boundary_refs: ["BE_1"])
      model = build_model([flow_node, catch_all_be])

      assert {:boundary, "BE_1", _error_info, true} =
               BoundaryAwareHandler.wrap_enter(
                 ErrorStringHandler,
                 flow_node,
                 make_token(),
                 make_context(model)
               )
    end

    test "works on script_task" do
      catch_all_be = error_boundary_node("BE_1", attached_to: "ScriptTask_1")
      flow_node = script_task_node(boundary_refs: ["BE_1"])
      model = build_model([flow_node, catch_all_be])

      assert {:boundary, "BE_1", _error_info, true} =
               BoundaryAwareHandler.wrap_enter(
                 ErrorStringHandler,
                 flow_node,
                 make_token(),
                 make_context(model)
               )
    end

    test "works on business_rule_task" do
      catch_all_be = error_boundary_node("BE_1", attached_to: "BRT_1")
      flow_node = business_rule_task_node(boundary_refs: ["BE_1"])
      model = build_model([flow_node, catch_all_be])

      assert {:boundary, "BE_1", _error_info, true} =
               BoundaryAwareHandler.wrap_enter(
                 ErrorStringHandler,
                 flow_node,
                 make_token(),
                 make_context(model)
               )
    end

    test "works on call_activity" do
      catch_all_be = error_boundary_node("BE_1", attached_to: "CA_1")
      flow_node = call_activity_node(boundary_refs: ["BE_1"])
      model = build_model([flow_node, catch_all_be])

      assert {:boundary, "BE_1", _error_info, true} =
               BoundaryAwareHandler.wrap_enter(
                 ErrorStringHandler,
                 flow_node,
                 make_token(),
                 make_context(model)
               )
    end

    test "structured error code matches specific boundary across activity types" do
      specific_be = error_boundary_node("BE_1", attached_to: "BRT_1", error_code: "CHILD_FATAL")
      flow_node = business_rule_task_node(boundary_refs: ["BE_1"])
      model = build_model([flow_node, specific_be])

      assert {:boundary, "BE_1", error_info, true} =
               BoundaryAwareHandler.wrap_enter(
                 ErrorStructuredHandler,
                 flow_node,
                 make_token(),
                 make_context(model)
               )

      assert error_info.error_code == "CHILD_FATAL"
    end
  end

  # -- Tests: normalize_to_error_info -----------------------------------------

  describe "normalize_to_error_info/1" do
    test "preserves already-structured error info" do
      structured = %{error_code: "MY_CODE", error_message: "my message"}
      assert ^structured = BoundaryAwareHandler.normalize_to_error_info(structured)
    end

    test "wraps binary reason" do
      result = BoundaryAwareHandler.normalize_to_error_info("timeout exceeded")
      assert result.error_code == "HANDLER_ERROR"
      assert result.error_message == "timeout exceeded"
    end

    test "wraps tuple reason via inspect" do
      result = BoundaryAwareHandler.normalize_to_error_info({:missing_implementation, nil})
      assert result.error_code == "HANDLER_ERROR"
      assert result.error_message == "{:missing_implementation, nil}"
    end

    test "wraps atom reason via inspect" do
      result = BoundaryAwareHandler.normalize_to_error_info(:not_found)
      assert result.error_code == "HANDLER_ERROR"
      assert result.error_message == ":not_found"
    end

    test "wraps map without error_code via inspect" do
      result = BoundaryAwareHandler.normalize_to_error_info(%{reason: :boom})
      assert result.error_code == "HANDLER_ERROR"
      assert is_binary(result.error_message)
    end
  end

  # -- Tests: mixed boundary types (error + timer) ----------------------------

  describe "wrap_enter/4 mixed boundary types" do
    test "finds error boundary among timer boundaries" do
      timer_be = timer_boundary_node("TimerBE_1")
      error_be = error_boundary_node("ErrorBE_1")
      flow_node = service_task_node(boundary_refs: ["TimerBE_1", "ErrorBE_1"])
      model = build_model([flow_node, timer_be, error_be])

      assert {:boundary, "ErrorBE_1", _error_info, true} =
               BoundaryAwareHandler.wrap_enter(
                 ErrorStringHandler,
                 flow_node,
                 make_token(),
                 make_context(model)
               )
    end
  end
end

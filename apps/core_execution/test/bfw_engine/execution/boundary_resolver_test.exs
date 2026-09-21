defmodule BfwEngine.Execution.BoundaryResolverTest do
  use ExUnit.Case, async: true

  alias BfwEngine.BPMN.Model.Definitions
  alias BfwEngine.BPMN.Model.ErrorDefinition
  alias BfwEngine.BPMN.Model.EventDefinition
  alias BfwEngine.BPMN.Model.FlowNode
  alias BfwEngine.BPMN.Model.FlowNodeData
  alias BfwEngine.BPMN.Model.Process, as: BpmnProcess
  alias BfwEngine.Execution.BoundaryResolver

  defp build_host_and_model(boundary_nodes) do
    host = %FlowNode{
      id: "CA_1",
      type: :call_activity,
      type_data: %FlowNodeData.CallActivity{called_element: "child"},
      incoming: ["Flow_1"],
      outgoing: ["Flow_2"],
      boundary_event_refs: Enum.map(boundary_nodes, & &1.id)
    }

    model = %BpmnProcess{
      id: "proc",
      flow_nodes: [host | boundary_nodes]
    }

    {host, model}
  end

  defp error_boundary(id, opts \\ []) do
    %FlowNode{
      id: id,
      type: :boundary_event,
      type_data: %FlowNodeData.BoundaryEvent{
        attached_to_ref: "CA_1",
        cancel_activity: Keyword.get(opts, :cancel_activity, true),
        event_definition: %EventDefinition.Error{
          error_ref: Keyword.get(opts, :error_ref),
          error_code: Keyword.get(opts, :error_code),
          error_message: Keyword.get(opts, :error_message)
        }
      }
    }
  end

  describe "find_matching_error_boundary" do
    test "returns :none when host has no boundary events" do
      {host, model} = build_host_and_model([])

      assert :none ==
               BoundaryResolver.find_matching_error_boundary(host, model, %{error_code: "ERR"})
    end

    test "matches by error_code only" do
      boundary = error_boundary("BE_1", error_code: "ORDER_FAILED")
      {host, model} = build_host_and_model([boundary])

      assert {:ok, matched} =
               BoundaryResolver.find_matching_error_boundary(host, model, %{
                 error_code: "ORDER_FAILED"
               })

      assert matched.id == "BE_1"
    end

    test "does not match when error_code differs" do
      boundary = error_boundary("BE_1", error_code: "ORDER_FAILED")
      {host, model} = build_host_and_model([boundary])

      assert :none ==
               BoundaryResolver.find_matching_error_boundary(host, model, %{
                 error_code: "OTHER_ERROR"
               })
    end

    test "matches by error_message only" do
      boundary = error_boundary("BE_1", error_message: "timeout")
      {host, model} = build_host_and_model([boundary])

      assert {:ok, matched} =
               BoundaryResolver.find_matching_error_boundary(host, model, %{
                 error_message: "timeout"
               })

      assert matched.id == "BE_1"
    end

    test "matches with AND semantics (both code and message)" do
      boundary = error_boundary("BE_1", error_code: "ERR_01", error_message: "bad input")
      {host, model} = build_host_and_model([boundary])

      assert {:ok, _} =
               BoundaryResolver.find_matching_error_boundary(
                 host,
                 model,
                 %{error_code: "ERR_01", error_message: "bad input"}
               )

      assert :none ==
               BoundaryResolver.find_matching_error_boundary(
                 host,
                 model,
                 %{error_code: "ERR_01", error_message: "wrong message"}
               )

      assert :none ==
               BoundaryResolver.find_matching_error_boundary(
                 host,
                 model,
                 %{error_code: "WRONG", error_message: "bad input"}
               )
    end

    test "catch-all boundary (no code, no message) matches any error" do
      boundary = error_boundary("BE_1")
      {host, model} = build_host_and_model([boundary])

      assert {:ok, matched} =
               BoundaryResolver.find_matching_error_boundary(host, model, %{
                 error_code: "ANYTHING"
               })

      assert matched.id == "BE_1"
    end

    test "returns first matching boundary when multiple exist" do
      b1 = error_boundary("BE_1", error_code: "SPECIFIC")
      b2 = error_boundary("BE_2")
      {host, model} = build_host_and_model([b1, b2])

      assert {:ok, matched} =
               BoundaryResolver.find_matching_error_boundary(host, model, %{
                 error_code: "SPECIFIC"
               })

      assert matched.id == "BE_1"
    end

    test "falls through to catch-all when specific boundary doesn't match" do
      b1 = error_boundary("BE_1", error_code: "SPECIFIC")
      b2 = error_boundary("BE_2")
      {host, model} = build_host_and_model([b1, b2])

      assert {:ok, matched} =
               BoundaryResolver.find_matching_error_boundary(host, model, %{error_code: "OTHER"})

      assert matched.id == "BE_2"
    end

    test "catch-all listed before a specific still yields the specific" do
      catch_all = error_boundary("BE_catch_all")
      specific = error_boundary("BE_specific", error_code: "CHARGE_FAILED")
      {host, model} = build_host_and_model([catch_all, specific])

      assert {:ok, matched} =
               BoundaryResolver.find_matching_error_boundary(host, model, %{
                 error_code: "CHARGE_FAILED"
               })

      assert matched.id == "BE_specific"
    end

    test "matches a boundary that only has errorRef against the global errorCode" do
      boundary = error_boundary("BE_ref", error_ref: "Error_PaymentFailed")
      {host, model} = build_host_and_model([boundary])

      definitions = %Definitions{
        raw_xml: "",
        errors: [
          %ErrorDefinition{id: "Error_PaymentFailed", error_code: "PAYMENT_DECLINED"}
        ]
      }

      assert {:ok, matched} =
               BoundaryResolver.find_matching_error_boundary(
                 host,
                 model,
                 definitions,
                 %{error_code: "PAYMENT_DECLINED"}
               )

      assert matched.id == "BE_ref"

      assert :none ==
               BoundaryResolver.find_matching_error_boundary(
                 host,
                 model,
                 definitions,
                 %{error_code: "OTHER"}
               )
    end

    test "raised unmatched code still matches a catch-all" do
      specific = error_boundary("BE_specific", error_code: "CHARGE_FAILED")
      catch_all = error_boundary("BE_catch_all")
      {host, model} = build_host_and_model([specific, catch_all])

      assert {:ok, matched} =
               BoundaryResolver.find_matching_error_boundary(host, model, %{
                 error_code: "UNKNOWN"
               })

      assert matched.id == "BE_catch_all"
    end

    test "ignores non-error boundary events" do
      timer_boundary = %FlowNode{
        id: "BE_timer",
        type: :boundary_event,
        type_data: %FlowNodeData.BoundaryEvent{
          attached_to_ref: "CA_1",
          event_definition: %EventDefinition.Timer{}
        }
      }

      {host, model} = build_host_and_model([timer_boundary])

      assert :none ==
               BoundaryResolver.find_matching_error_boundary(host, model, %{error_code: "ERR"})
    end
  end
end

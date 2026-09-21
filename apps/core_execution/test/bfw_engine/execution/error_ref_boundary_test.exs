defmodule BfwEngine.Execution.ErrorRefBoundaryTest do
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
      id: "Task_1",
      type: :service_task,
      type_data: %FlowNodeData.ServiceTask{implementation: "http"},
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

  defp error_boundary(id, opts) do
    %FlowNode{
      id: id,
      type: :boundary_event,
      type_data: %FlowNodeData.BoundaryEvent{
        attached_to_ref: "Task_1",
        cancel_activity: true,
        event_definition: %EventDefinition.Error{
          error_ref: Keyword.get(opts, :error_ref),
          error_code: Keyword.get(opts, :error_code),
          error_message: Keyword.get(opts, :error_message)
        }
      }
    }
  end

  defp payment_definitions do
    %Definitions{
      raw_xml: "",
      errors: [
        %ErrorDefinition{id: "Error_ChargeFailed", error_code: "CHARGE_FAILED"}
      ]
    }
  end

  test "catches via errorRef only when the global errorCode matches" do
    specific = error_boundary("BE_ref", error_ref: "Error_ChargeFailed")
    {host, model} = build_host_and_model([specific])

    assert {:ok, matched} =
             BoundaryResolver.find_matching_error_boundary(
               host,
               model,
               payment_definitions(),
               %{error_code: "CHARGE_FAILED"}
             )

    assert matched.id == "BE_ref"
  end

  test "errorRef-only boundary does not act as a catch-all" do
    specific = error_boundary("BE_ref", error_ref: "Error_ChargeFailed")
    {host, model} = build_host_and_model([specific])

    assert :none ==
             BoundaryResolver.find_matching_error_boundary(
               host,
               model,
               payment_definitions(),
               %{error_code: "OTHER"}
             )
  end

  test "specific errorRef beats a catch-all listed first in boundary_event_refs" do
    catch_all = error_boundary("BE_catch_all", [])
    specific = error_boundary("BE_ref", error_ref: "Error_ChargeFailed")
    {host, model} = build_host_and_model([catch_all, specific])

    assert {:ok, matched} =
             BoundaryResolver.find_matching_error_boundary(
               host,
               model,
               payment_definitions(),
               %{error_code: "CHARGE_FAILED"}
             )

    assert matched.id == "BE_ref"
  end

  test "catch-all still matches when no specific errorRef matches" do
    specific = error_boundary("BE_ref", error_ref: "Error_ChargeFailed")
    catch_all = error_boundary("BE_catch_all", [])
    {host, model} = build_host_and_model([specific, catch_all])

    assert {:ok, matched} =
             BoundaryResolver.find_matching_error_boundary(
               host,
               model,
               payment_definitions(),
               %{error_code: "UNKNOWN"}
             )

    assert matched.id == "BE_catch_all"
  end
end

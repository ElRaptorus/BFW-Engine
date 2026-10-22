defmodule BfwEngine.Execution.FlowNodes.CompensateEndEvent do
  @moduledoc """
  Handler for `<bpmn:endEvent>` with a Compensation event definition.

  Returns `{:compensate, run_spec, FlowNodeResult}`. The PI reacts by
  resolving compensation targets, dispatching handler activities in LIFO
  order, consuming this token (like a None End), and flagging
  `compensation_end_reached`.

  ## Distinction from Compensate Intermediate Throw

  The Compensation End Event ends **only its own path** — it does NOT
  interrupt parallel branches (unlike Terminate End). After its handlers
  finish, this token is consumed. When the PI naturally quiesces
  (`active_count == 0`) and `compensation_end_reached` is set,
  the PI terminal state is `:compensated` instead of `:finished`.

  This matches BPMN 2.0 §10.6 and Camunda/Flowable behavior: "a
  compensation end event triggers compensation and the current path
  of execution is ended."
  """

  @behaviour BfwEngine.Execution.FlowNodeHandler

  alias BfwEngine.BPMN.Model.FlowNode
  alias BfwEngine.Execution.FlowNodeResult
  alias BfwEngine.Execution.HandlerContext
  alias BfwEngine.Types.Token

  @spec handle_enter(FlowNode.t(), Token.t(), HandlerContext.t()) ::
          {:compensate, map(), FlowNodeResult.t()}
  @impl true
  def handle_enter(flow_node, token, _context) do
    event_definition = flow_node.type_data.event_definition

    run_spec = %{
      throw_type: :end,
      event_definition: event_definition,
      outgoing_flow_node_ids: []
    }

    type_properties = %{
      end_event_id: flow_node.id,
      end_event_name: flow_node.name
    }

    {:compensate, run_spec,
     %FlowNodeResult{
       output_payload: token.payload,
       next_flow_node_ids: [],
       type_properties: type_properties,
       metadata: %{}
     }}
  end
end

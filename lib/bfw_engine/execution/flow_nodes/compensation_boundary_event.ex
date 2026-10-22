defmodule BfwEngine.Execution.FlowNodes.CompensationBoundaryEvent do
  @moduledoc """
  Handler for a Compensation Boundary Event.

  Unlike timer/message/signal boundaries, a Compensation Boundary is a
  passive registration carrier. It is NOT pre-spawned alongside its host
  activity and never waits for an external trigger. Its only purpose is
  to link a host activity to its compensation handler activity via a
  `<bpmn:association>`.

  If this handler is invoked (which should not happen in normal flow
  since `BoundaryOrchestrator.resolve_subscription_boundaries` filters
  compensation boundaries out), it returns an immediate no-op error to
  prevent accidental execution.
  """

  @behaviour BfwEngine.Execution.FlowNodeHandler

  alias BfwEngine.BPMN.Model.FlowNode
  alias BfwEngine.Execution.HandlerContext
  alias BfwEngine.Types.Token

  @impl true
  @spec handle_enter(FlowNode.t(), Token.t(), HandlerContext.t()) :: {:error, term()}
  def handle_enter(_flow_node, _token, _context) do
    {:error, :compensation_boundary_not_dispatched}
  end
end

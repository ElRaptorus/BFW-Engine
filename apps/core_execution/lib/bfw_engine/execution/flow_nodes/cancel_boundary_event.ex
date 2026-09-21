defmodule BfwEngine.Execution.FlowNodes.CancelBoundaryEvent do
  @moduledoc """
  Handler for `<bpmn:boundaryEvent>` with a Cancel event definition.

  Cancel Boundary Events are **reactive** — they are never dispatched
  directly via `HandlerDispatch`. The `TransactionSubProcess` handler
  resolves them when the child PI reports `{:child_pi_cancelled, ...}`.

  This module exists as a routing target in `HandlerDispatch` and as a
  safety guard: if somehow directly dispatched (a bug), `handle_enter/3`
  returns an error immediately.
  """

  @behaviour BfwEngine.Execution.FlowNodeHandler

  alias BfwEngine.BPMN.Model.FlowNode
  alias BfwEngine.Execution.HandlerContext
  alias BfwEngine.Types.Token

  @impl true
  @spec handle_enter(FlowNode.t(), Token.t(), HandlerContext.t()) ::
          {:error, :cancel_boundary_not_dispatched}
  def handle_enter(_flow_node, _token, _context) do
    {:error, :cancel_boundary_not_dispatched}
  end

  @impl true
  def handle_fatal(_entry), do: :ok

  @impl true
  def handle_aborted(_entry), do: :ok
end

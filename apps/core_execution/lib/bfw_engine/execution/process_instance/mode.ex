defmodule BfwEngine.Execution.ProcessInstance.Mode do
  @moduledoc """
  Behaviour for PI execution mode strategy.

  The ProcessInstance `:gen_statem` delegates three policy decisions to the
  injected Mode module: how to resolve the initial state (start event),
  what to dispatch on boot, and when the PI should consider itself complete.

  `StandardMode` implements the default BPMN semantics. `AdHocMode` (Phase 4B)
  overrides for ad-hoc subprocess child PIs.
  """

  alias BfwEngine.BPMN.Model.FlowNode
  alias BfwEngine.BPMN.Model.Process, as: BpmnProcess
  alias BfwEngine.Execution.ProcessInstance.State

  @doc """
  Resolve which flow node (typically a Start Event) the PI should begin at.

  Returns `{:ok, flow_node}` on success, or `{:error, reason_atom, message}`
  when resolution fails (no start event, ambiguous, not found).

  StandardMode delegates to `StartEventResolver` which replicates the original
  `resolve_start_event/2` logic. AdHocMode (Phase 4B) returns `{:ok, nil}`
  because ad-hoc subprocesses have no start event.
  """
  @callback resolve_initial_state(
              process_model :: BpmnProcess.t(),
              start_event_id :: String.t() | nil,
              process_id :: String.t()
            ) ::
              {:ok, FlowNode.t() | nil} | {:error, atom(), String.t()}

  @doc """
  Prepare the initial dispatch after PI creation.

  For StandardMode, `init/1` dispatches the resolved start event directly
  via `dispatch_flow_node_instance` (which is private to ProcessInstance).
  This callback exists as the extension point for AdHocMode (Phase 4B)
  which skips start-event dispatch entirely.

  Returns the (possibly modified) data struct.
  """
  @callback initial_dispatch(
              data :: State.t(),
              start_node :: FlowNode.t() | nil,
              token :: map(),
              esp_start_passthrough :: boolean()
            ) :: State.t()

  @doc """
  Determine whether the PI should consider itself complete and transition
  to a terminal state.

  StandardMode returns `true` when no FNI is `:active` or `:waiting`.
  AdHocMode (Phase 4B) adds additional completion conditions.
  """
  @callback should_complete?(data :: State.t()) :: boolean()
end

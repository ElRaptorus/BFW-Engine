defmodule EvilEngine.Execution.FlowNodeHandler do
  @moduledoc """
  Callback contract for every BPMN element handler.

  Each flow node type (Start Event, User Task, Service Task, …)
  implements this behaviour. The PI dispatches to the appropriate
  handler via `handler_for/1`.

  ## Return shapes (handle_enter)

  - `{:ok, result}` — synchronous completion, token advances.
  - `{:wait, result}` — FNI enters `waiting` (User Task, Manual Task
    with confirmation, catch events). Token does NOT advance until an
    external call completes the FNI.
  - `{:error, reason}` — FNI transitions to `fatal`.
  - `{:terminate, result}` — synchronous completion that signals the PI
    to finish this FNI normally, then interrupt all remaining
    active/waiting FNIs and complete the process instance. Used
    exclusively by Terminate End Events.
  - `{:bpmn_error, error_info, result}` — the flow node threw a modeled
    BPMN error. The FNI is persisted with terminal state `:error` (not
    `:finished`). The PI interrupts all remaining sibling FNIs, transitions
    to `:error` state, and notifies the parent with structured error_info.
    The parent handler (Call Activity / SubProcess) can match the error
    against attached Boundary Error Events. Used exclusively by Error End
    Events.
  - `{:async, flow_node_instance_id}` — FNI enters `waiting` with async marker
    (Service Task plugin, async-only). An external call completes it
    later via `finish_async_service_task`.
  - `{:async, flow_node_instance_id, continuation_fn}` — FNI enters `waiting`; the
    handler Task stays alive and runs `continuation_fn.()` which
    returns the final result. Used by Call Activity to monitor a
    child PI without blocking the PI's message loop.
  - `{:async, flow_node_instance_id, continuation_fn, type_properties}` — Same as
    above, but `type_properties` (a map) is merged into the FNI's
    `type_properties` alongside the `async: true` marker in a single
    persistence write. Used by Call Activity to pre-persist the
    `child_process_instance_id` before the child is started.
  - `{:boundary, boundary_node_id, payload, cancel_activity}` — returned
    by activity handlers (e.g. Call Activity) when a child error is
    caught by an attached boundary event, or by subscription-model
    boundary handlers (e.g. TimerBoundaryEvent) when their trigger
    fires. `cancel_activity` is a boolean: `true` = interrupting
    (host FNI gets interrupted), `false` = non-interrupting (host
    continues). The PI uses the flag directly without re-deriving it
    from the model.

  ## Completion callbacks (optional)

  Handlers that accept external completion (User Task, Manual Task,
  async Service Task) implement `handle_complete/4`. The PI's
  `finish_user_task` / `finish_async_service_task` call handlers
  validate the FNI is `:waiting`, then delegate to the handler.

  The handler owns: payload validation, domain event emission,
  and outgoing flow resolution. Returns the same `{:ok, FlowNodeResult}`
  shape as `handle_enter` — the PI processes it via the generic
  `handle_fni_ok` path.

  `handle_cancel/4` is for handlers that support cancellation
  (User Task, Manual Task). Called before the PI aborts.
  """

  alias EvilEngine.BPMN.Model.FlowNode
  alias EvilEngine.Execution.FlowNodeResult
  alias EvilEngine.Execution.HandlerContext
  alias EvilEngine.Types.Token

  @callback handle_enter(
              flow_node :: FlowNode.t(),
              token :: Token.t(),
              context :: HandlerContext.t()
            ) ::
              {:ok, FlowNodeResult.t()}
              | {:wait, FlowNodeResult.t()}
              | {:terminate, FlowNodeResult.t()}
              | {:bpmn_error, map(), FlowNodeResult.t()}
              | {:error, reason :: term()}
              | {:async, String.t()}
              | {:async, String.t(), (-> term())}
              | {:async, String.t(), (-> term()), map()}
              | {:boundary, String.t(), term(), boolean()}

  @callback handle_complete(
              flow_node :: FlowNode.t(),
              flow_node_instance_entry :: map(),
              payload :: map(),
              context :: HandlerContext.t()
            ) ::
              {:ok, FlowNodeResult.t()}
              | {:error, reason :: term()}

  @callback handle_cancel(
              flow_node :: FlowNode.t(),
              flow_node_instance_entry :: map(),
              reason :: term(),
              context :: HandlerContext.t()
            ) :: :ok

  @doc """
  Called when the FNI is being fataled (parent PI went fatal).
  Handlers that own external resources (e.g. Call Activity's child PI)
  cascade the fatal to those resources.

  Must be resilient: if the external resource is already stopped or
  unreachable, return `:ok` silently.
  """
  @callback handle_fatal(flow_node_instance_entry :: map()) :: :ok

  @doc """
  Called when the FNI is being aborted (parent PI aborted, or FNI
  interrupted by a boundary event). Handlers that own external
  resources cascade the abort to those resources.

  Must be resilient: if the external resource is already stopped or
  unreachable, return `:ok` silently.
  """
  @callback handle_aborted(flow_node_instance_entry :: map()) :: :ok

  @optional_callbacks [handle_complete: 4, handle_cancel: 4, handle_fatal: 1, handle_aborted: 1]
end

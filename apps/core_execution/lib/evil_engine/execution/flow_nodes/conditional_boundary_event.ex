defmodule EvilEngine.Execution.FlowNodes.ConditionalBoundaryEvent do
  @moduledoc """
  Handler for `<bpmn:boundaryEvent>` with a Conditional event definition.

  ## Lifecycle

  1. `handle_enter/3` evaluates the condition expression against the
     current PI state (via the handler context). If the condition is
     already true, fires immediately with `{:boundary, ...}`. If false,
     parks as waiting and returns `{:wait, %FlowNodeResult{}}` — the
     handler Task exits immediately.
  2. The PI registers a conditional waiter. When
     `evaluate_conditional_waiters` determines the condition is met,
     it constructs a `{:boundary, ...}` result directly (no handler
     Task involvement).
  3. The PI processes the boundary result generically: interrupts the
     host (if `cancel_activity`), cancels siblings, and dispatches the
     boundary event's outgoing path.

  ## Interrupting vs non-interrupting

  - **Interrupting** (`cancel_activity: true`): the boundary fires once,
    the host is interrupted, sibling boundaries are cancelled.
  - **Non-interrupting** (`cancel_activity: false`): fires **at most once**.
    A parallel branch is spawned, the host continues. The waiter is removed
    from `conditional_waiters` after the single fire.

  ## `evaluate_condition/3`

  Pure function exported for the PI's re-evaluation loop. Same contract
  as `ConditionalCatchEvent.evaluate_condition/3`.

  ## Cleanup

  `handle_fatal/1` and `handle_aborted/1` are no-ops — no external resources
  (no timer, no subscription).
  """

  @behaviour EvilEngine.Execution.FlowNodeHandler

  require Logger

  alias EvilEngine.BPMN.Model.FlowNode
  alias EvilEngine.Execution.FlowNodeResult
  alias EvilEngine.Execution.HandlerContext
  alias EvilEngine.Expressions
  alias EvilEngine.Expressions.Context, as: FeelContext
  alias EvilEngine.Expressions.Result, as: FeelResult
  alias EvilEngine.Types.Token

  # -------------------------------------------------------------------
  # FlowNodeHandler callbacks
  # -------------------------------------------------------------------

  @spec handle_enter(FlowNode.t(), Token.t(), HandlerContext.t()) ::
          {:boundary, String.t(), map(), boolean()}
          | {:wait, FlowNodeResult.t()}
  @impl true
  def handle_enter(flow_node, token, context) do
    condition_expression = flow_node.type_data.event_definition.condition_expression
    cancel_activity = flow_node.type_data.cancel_activity

    case do_evaluate_condition(condition_expression, flow_node, token.payload, context) do
      {:fire, true} ->
        {:boundary, flow_node.id, %{}, cancel_activity}

      {:fire, false} ->
        park_and_wait(flow_node, context, condition_expression, cancel_activity)
    end
  end

  @impl true
  def handle_fatal(_context), do: :ok

  @impl true
  def handle_aborted(_context), do: :ok

  @doc """
  Resume a conditional boundary event from persisted state.

  Re-evaluates the condition. If true, fires immediately.
  If false, returns `{:wait, ...}` so the PI re-registers the waiter.
  """
  @spec handle_resume(FlowNode.t(), map(), HandlerContext.t()) ::
          {:boundary, String.t(), map(), boolean()}
          | {:wait, FlowNodeResult.t()}
  def handle_resume(flow_node, _persisted_type_properties, context) do
    condition_expression = flow_node.type_data.event_definition.condition_expression
    cancel_activity = flow_node.type_data.cancel_activity

    case do_evaluate_condition(condition_expression, flow_node, %{}, context) do
      {:fire, true} ->
        {:boundary, flow_node.id, %{}, cancel_activity}

      {:fire, false} ->
        park_and_wait(flow_node, context, condition_expression, cancel_activity)
    end
  end

  # -------------------------------------------------------------------
  # Public: PI re-evaluation interface
  # -------------------------------------------------------------------

  @doc """
  Pure function called by the PI's re-evaluation loop.

  Builds a FEEL context from the flow node, token snapshot, and current
  PI state, evaluates the condition expression, and returns
  `{:fire, true}` or `{:fire, false}`.
  """
  @spec evaluate_condition(FlowNode.t(), map(), struct()) :: {:fire, boolean()}
  def evaluate_condition(flow_node, token_payload, pi_state) do
    condition_expression = flow_node.type_data.event_definition.condition_expression
    feel_context = build_feel_context_from_pi_state(flow_node, token_payload, pi_state)

    case Expressions.eval(condition_expression, feel_context) do
      result ->
        case FeelResult.to_boolean(result) do
          {:ok, value} ->
            {:fire, value}

          {:error, reason} ->
            Logger.warning(
              "Conditional boundary event '#{flow_node.id}' on PI '#{pi_state.process_instance_id}': " <>
                "FEEL evaluation returned non-boolean: #{reason}"
            )

            {:fire, false}
        end
    end
  rescue
    exception ->
      Logger.warning(
        "Conditional boundary event '#{flow_node.id}' on PI '#{pi_state.process_instance_id}': " <>
          "FEEL evaluation failed: #{Exception.message(exception)}"
      )

      {:fire, false}
  end

  # -------------------------------------------------------------------
  # Private: park and wait
  # -------------------------------------------------------------------

  defp park_and_wait(_flow_node, context, _condition_expression, _cancel_activity) do
    type_properties = %{
      awaiting_condition: true,
      host_flow_node_instance_id: context.host_flow_node_instance_id
    }

    {:wait,
     %FlowNodeResult{
       output_payload: nil,
       next_flow_node_ids: [],
       type_properties: type_properties,
       metadata: %{awaiting_condition: true}
     }}
  end

  # -------------------------------------------------------------------
  # Private: FEEL evaluation helpers
  # -------------------------------------------------------------------

  defp do_evaluate_condition(condition_expression, flow_node, token_payload, handler_context) do
    feel_context = FeelContext.from_handler_context(handler_context, token_payload)

    case Expressions.eval(condition_expression, feel_context) do
      result ->
        case FeelResult.to_boolean(result) do
          {:ok, value} ->
            {:fire, value}

          {:error, reason} ->
            Logger.warning(
              "Conditional boundary event '#{flow_node.id}': " <>
                "FEEL evaluation returned non-boolean: #{reason}"
            )

            {:fire, false}
        end
    end
  rescue
    exception ->
      Logger.warning(
        "Conditional boundary event '#{flow_node.id}': " <>
          "FEEL evaluation failed: #{Exception.message(exception)}"
      )

      {:fire, false}
  end

  defp build_feel_context_from_pi_state(flow_node, token_payload, pi_state) do
    identity_map =
      case pi_state.identity do
        nil -> %{}
        %{__struct__: _} = identity -> Map.from_struct(identity)
        identity when is_map(identity) -> identity
      end

    process_map =
      case pi_state.process_model do
        nil -> %{}
        model -> %{id: model.id, name: model.name, version: model.version}
      end

    pseudo_handler_context = %{
      flow_node_this: FeelContext.flow_node_this(flow_node),
      context: pi_state.started_with_context || %{},
      data_objects: pi_state.data_object_cache,
      process: process_map,
      process_instance: %{
        id: pi_state.process_instance_id,
        started_at: pi_state.started_at,
        started_by: identity_map[:id]
      },
      identity: identity_map
    }

    FeelContext.from_handler_context(pseudo_handler_context, token_payload)
  end
end

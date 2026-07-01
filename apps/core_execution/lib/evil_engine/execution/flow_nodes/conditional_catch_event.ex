defmodule EvilEngine.Execution.FlowNodes.ConditionalCatchEvent do
  @moduledoc """
  Handler for `<bpmn:intermediateCatchEvent>` with a Conditional event definition.

  On enter, the handler always parks the FNI as waiting and returns
  `{:wait, %FlowNodeResult{}}`. The handler Task exits immediately
  after parking — it never performs persistence beyond the initial
  `transition_to_waiting` call. This design avoids Ecto sandbox
  contention in tests (the handler Task never calls `Repo.transaction`
  via `FniLifecycle.finish`).

  The PI's `register_conditional_waiter` performs immediate evaluation
  right after registration. If the condition is already true, the PI
  calls `complete_condition/3` from its own GenServer process to persist
  the FNI finish and route successors. If false, the waiter stays
  registered for re-evaluation on state changes.

  ## `evaluate_condition/3`

  Pure function exported for the PI's re-evaluation loop. Builds the
  FEEL context from the flow node, token snapshot, and current PI state,
  evaluates the condition expression, coerces to boolean, and returns
  `{:fire, true}` or `{:fire, false}`. The PI never touches FEEL.

  ## `complete_condition/3`

  Called by the PI (from its GenServer process) when the condition
  evaluates to true. Resolves outgoing sequence flows, persists the
  FNI as finished via `FniLifecycle.finish`, and returns a
  `FlowNodeResult` for the PI to dispatch successors.

  ## Lifecycle callbacks

  - `handle_fatal/1` / `handle_aborted/1`: no external resources to
    clean up.
  - `handle_resume/3`: returns `{:wait, ...}` so the PI re-registers
    the waiter and performs immediate evaluation.
  """

  @behaviour EvilEngine.Execution.FlowNodeHandler

  require Logger

  alias EvilEngine.BPMN.Model.FlowNode
  alias EvilEngine.Execution.FlowNodeResult
  alias EvilEngine.Execution.FniLifecycle
  alias EvilEngine.Execution.HandlerContext
  alias EvilEngine.Execution.SequenceFlowResolver
  alias EvilEngine.Expressions
  alias EvilEngine.Expressions.Context, as: FeelContext
  alias EvilEngine.Expressions.Result, as: FeelResult
  alias EvilEngine.Types.Token

  # -------------------------------------------------------------------
  # FlowNodeHandler callbacks
  # -------------------------------------------------------------------

  @spec handle_enter(FlowNode.t(), Token.t(), HandlerContext.t()) ::
          {:wait, FlowNodeResult.t()}
  @impl true
  def handle_enter(flow_node, token, context) do
    condition_expression = flow_node.type_data.event_definition.condition_expression
    park_and_wait(flow_node, token.payload, context, condition_expression)
  end

  @impl true
  def handle_fatal(_context), do: :ok

  @impl true
  def handle_aborted(_context), do: :ok

  @doc """
  Resume a conditional catch event from persisted state.

  Returns `{:wait, ...}` so the PI re-registers the waiter and does
  immediate evaluation. If the condition is true, the PI completes the
  FNI via `complete_condition/3` from its own process.
  """
  @spec handle_resume(FlowNode.t(), Token.t(), HandlerContext.t()) ::
          {:wait, FlowNodeResult.t()}
  def handle_resume(flow_node, token, context) do
    condition_expression = flow_node.type_data.event_definition.condition_expression
    park_and_wait(flow_node, token.payload, context, condition_expression)
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
              "Conditional event '#{flow_node.id}' on PI '#{pi_state.process_instance_id}': " <>
                "FEEL evaluation returned non-boolean: #{reason}"
            )

            {:fire, false}
        end
    end
  rescue
    exception ->
      Logger.warning(
        "Conditional event '#{flow_node.id}' on PI '#{pi_state.process_instance_id}': " <>
          "FEEL evaluation failed: #{Exception.message(exception)}"
      )

      {:fire, false}
  end

  # -------------------------------------------------------------------
  # Public: PI-driven completion
  # -------------------------------------------------------------------

  @doc """
  Called by the PI (from its GenServer process) when the condition fires.

  Resolves outgoing sequence flows, persists the FNI as finished via
  `FniLifecycle.finish`, and returns a `FlowNodeResult`.
  """
  @spec complete_condition(FlowNode.t(), map(), HandlerContext.t()) ::
          {:ok, FlowNodeResult.t()} | {:error, term()}
  def complete_condition(flow_node, payload, context) do
    with {:ok, next_ids} <- resolve_outgoing(flow_node, context),
         {:ok, lifecycle_result} <- FniLifecycle.finish(context, flow_node, payload, %{}) do
      {:ok,
       %FlowNodeResult{
         output_payload: payload,
         next_flow_node_ids: next_ids,
         metadata: %{persisted: true, lifecycle: lifecycle_result}
       }}
    end
  end

  # -------------------------------------------------------------------
  # Private: park and wait for condition
  # -------------------------------------------------------------------

  defp park_and_wait(flow_node, _payload, context, _condition_expression) do
    next_ids =
      case resolve_outgoing(flow_node, context) do
        {:ok, ids} -> ids
        _ -> []
      end

    {:wait,
     %FlowNodeResult{
       output_payload: nil,
       next_flow_node_ids: next_ids,
       metadata: %{awaiting_condition: true}
     }}
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

  # -------------------------------------------------------------------
  # Private: helpers
  # -------------------------------------------------------------------

  defp resolve_outgoing(flow_node, context) do
    case SequenceFlowResolver.resolve(flow_node, context.process_model) do
      {:ok, targets} -> {:ok, Enum.map(targets, & &1.id)}
      {:error, reason, meta} -> {:error, Map.put(meta, :reason, reason)}
    end
  end
end

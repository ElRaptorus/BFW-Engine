defmodule EvilEngine.Execution.FlowNodes.ExclusiveGateway do
  @moduledoc """
  Handler for `<bpmn:exclusiveGateway>`.

  ## Split semantics (diverging — 1 incoming, N outgoing)

  Evaluates ALL outgoing conditional sequence flows using FEEL and
  enforces strict exactly-one-truthy semantics:

  - Exactly one condition evaluates to `true` → that path is taken.
  - Zero truthy conditions + a default flow exists → default is taken.
  - Zero truthy conditions + no default → fatal `:no_matching_condition`.
  - Multiple truthy conditions → fatal `:ambiguous_condition`.
  - Any expression evaluation error → fatal `:expression_evaluation_failed`.
  - Split with more than one outgoing: an unmarked (blank `conditionExpression`)
    non-default flow is fatal `:exclusive_gateway_unconditional_flow` **before**
    FEEL evaluation. A single outgoing unmarked flow is pass-through. A single
    outgoing that carries a condition is still evaluated (false + no default →
    `:no_matching_condition`).

  This is a deliberate divergence from the BPMN 2.0 specification's
  "first truthy wins" rule. Strict enforcement prevents ambiguous,
  non-deterministic routing.

  ## Join semantics (converging — N incoming, 1 outgoing)

  Pure pass-through. The first arriving token is immediately forwarded
  to the single outgoing flow. Delegates to `SequenceFlowResolver` for
  standard target resolution (inheriting implicit-split and dead-end
  safety checks).

  ## Mixed gateway rejection

  Gateways with both >1 incoming AND >1 outgoing flows are rejected
  at runtime with a fatal `:mixed_gateway` error. This is a deliberate
  divergence from the BPMN 2.0 spec. Use separate gateway nodes for
  splitting and joining.
  """

  @behaviour EvilEngine.Execution.FlowNodeHandler

  alias EvilEngine.BPMN.Model.FlowNode
  alias EvilEngine.Execution.FlowNodeResult
  alias EvilEngine.Execution.FniLifecycle
  alias EvilEngine.Execution.HandlerContext
  alias EvilEngine.Execution.SequenceFlowResolver
  alias EvilEngine.Expressions
  alias EvilEngine.Expressions.Context, as: FeelContext
  alias EvilEngine.Expressions.Result, as: FeelResult
  alias EvilEngine.Types.Token

  @spec handle_enter(FlowNode.t(), Token.t(), HandlerContext.t()) ::
          {:ok, FlowNodeResult.t()} | {:error, term()}
  @impl true
  def handle_enter(flow_node, token, context) do
    {incoming, outgoing} = resolve_flow_counts(flow_node, context.process_model)
    incoming_count = length(incoming)
    outgoing_count = length(outgoing)

    routing_result =
      cond do
        incoming_count > 1 and outgoing_count > 1 ->
          {:error,
           %{
             reason: :mixed_gateway,
             flow_node_id: flow_node.id,
             incoming_count: incoming_count,
             outgoing_count: outgoing_count,
             message:
               "Mixed gateway (both split and join) is not allowed. " <>
                 "Use separate gateway nodes for splitting and joining."
           }}

        incoming_count > 1 ->
          handle_join(flow_node, token, context)

        true ->
          handle_split(flow_node, token, context, outgoing)
      end

    case routing_result do
      {:selected, output_payload, next_ids} ->
        case FniLifecycle.finish(context, flow_node, output_payload, %{}) do
          {:ok, lifecycle_result} ->
            {:ok,
             %FlowNodeResult{
               output_payload: output_payload,
               next_flow_node_ids: next_ids,
               metadata: %{persisted: true, lifecycle: lifecycle_result}
             }}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp handle_split(flow_node, token, context, outgoing_flows) do
    case outgoing_flows do
      [single_flow] ->
        pass_through_or_evaluate_single_outgoing(flow_node, token, context, single_flow)

      many_flows ->
        reject_or_evaluate_exclusive_split(flow_node, token, context, many_flows)
    end
  end

  defp pass_through_or_evaluate_single_outgoing(flow_node, token, context, single_flow) do
    if blank_condition?(single_flow) do
      {:selected, token.payload, [single_flow.target_ref]}
    else
      evaluate_exclusive_split(flow_node, token, context, [single_flow])
    end
  end

  defp reject_or_evaluate_exclusive_split(flow_node, token, context, outgoing_flows) do
    case first_unconditional_non_default(outgoing_flows) do
      %{} = unmarked_flow ->
        {:error,
         %{
           reason: :exclusive_gateway_unconditional_flow,
           flow_node_id: flow_node.id,
           sequence_flow_id: unmarked_flow.id,
           message:
             "ExclusiveGateway '#{flow_node.id}' has unconditional non-default outgoing " <>
               "sequence flow '#{unmarked_flow.id}'. Add a conditionExpression or mark the flow as default."
         }}

      nil ->
        evaluate_exclusive_split(flow_node, token, context, outgoing_flows)
    end
  end

  defp evaluate_exclusive_split(flow_node, token, context, outgoing_flows) do
    feel_context = build_feel_context(flow_node, token, context)

    {conditional, rest} =
      Enum.split_with(outgoing_flows, fn sequence_flow ->
        sequence_flow.condition_expression != nil and not sequence_flow.is_default
      end)

    {defaults, _unconditional} =
      Enum.split_with(rest, fn sequence_flow -> sequence_flow.is_default end)

    case evaluate_conditions(conditional, feel_context) do
      {:error, failed_sequence_flow, reason} ->
        {:error,
         %{
           reason: :expression_evaluation_failed,
           flow_node_id: flow_node.id,
           sequence_flow_id: failed_sequence_flow.id,
           expression: failed_sequence_flow.condition_expression,
           error: reason,
           message:
             "Failed to evaluate condition on sequence flow '#{failed_sequence_flow.id}': #{reason}"
         }}

      {:ok, evaluated} ->
        truthy_flows =
          evaluated
          |> Enum.filter(fn {_sequence_flow, value} -> value == true end)
          |> Enum.map(fn {sequence_flow, _} -> sequence_flow end)

        select_outgoing(flow_node, token, truthy_flows, defaults, conditional)
    end
  end

  defp evaluate_conditions(conditional_flows, feel_context) do
    Enum.reduce_while(conditional_flows, {:ok, []}, fn sequence_flow, {:ok, acc} ->
      case evaluate_single_condition(sequence_flow, feel_context) do
        {:ok, boolean_value} -> {:cont, {:ok, [{sequence_flow, boolean_value} | acc]}}
        {:error, reason} -> {:halt, {:error, sequence_flow, reason}}
      end
    end)
  end

  defp evaluate_single_condition(sequence_flow, feel_context) do
    case Expressions.eval(sequence_flow.condition_expression, feel_context) do
      {:ok, _value} = eval_result -> FeelResult.to_boolean(eval_result)
      {:error, reason} -> {:error, reason}
    end
  end

  defp select_outgoing(flow_node, token, truthy_flows, defaults, conditional) do
    case length(truthy_flows) do
      1 ->
        [winner] = truthy_flows
        {:selected, token.payload, [winner.target_ref]}

      0 when defaults != [] ->
        [default_flow | _] = defaults
        {:selected, token.payload, [default_flow.target_ref]}

      0 ->
        {:error,
         %{
           reason: :no_matching_condition,
           flow_node_id: flow_node.id,
           evaluated_count: length(conditional),
           message: "No outgoing sequence flow with a fulfilled condition"
         }}

      _n ->
        {:error,
         %{
           reason: :ambiguous_condition,
           flow_node_id: flow_node.id,
           truthy_flow_ids: Enum.map(truthy_flows, & &1.id),
           message: "Multiple outgoing sequence flows with fulfilled condition"
         }}
    end
  end

  defp handle_join(flow_node, token, context) do
    case SequenceFlowResolver.resolve(flow_node, context.process_model) do
      {:ok, targets} ->
        {:selected, token.payload, Enum.map(targets, & &1.id)}

      {:error, reason, meta} ->
        {:error, {reason, meta}}
    end
  end

  defp build_feel_context(_flow_node, token, handler_context) do
    FeelContext.from_handler_context(handler_context, token.payload || %{})
  end

  defp resolve_flow_counts(flow_node, process_model) do
    all_flows = process_model.sequence_flows || []

    incoming =
      case flow_node.incoming do
        ids when is_list(ids) and ids != [] -> ids
        _ -> Enum.filter(all_flows, &(&1.target_ref == flow_node.id))
      end

    outgoing =
      case flow_node.outgoing do
        ids when is_list(ids) and ids != [] ->
          flow_index = Map.new(all_flows, &{&1.id, &1})
          ids |> Enum.map(&Map.get(flow_index, &1)) |> Enum.reject(&is_nil/1)

        _ ->
          Enum.filter(all_flows, &(&1.source_ref == flow_node.id))
      end

    {incoming, outgoing}
  end

  defp first_unconditional_non_default(outgoing_flows) do
    Enum.find(outgoing_flows, fn sequence_flow ->
      not sequence_flow.is_default and blank_condition?(sequence_flow)
    end)
  end

  defp blank_condition?(sequence_flow) do
    case sequence_flow.condition_expression do
      nil -> true
      expression when is_binary(expression) -> String.trim(expression) == ""
      _other -> false
    end
  end
end

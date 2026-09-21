defmodule BfwEngine.Execution.FlowNodes.ComplexGateway do
  @moduledoc """
  Handler for `<bpmn:complexGateway>`.

  Bifrost Forge World Engine implements the Complex Gateway as an opinionated,
  deterministic construct — NOT the oscillation-prone reset semantics of the
  BPMN 2.0 specification. See `docs/guides/handbook/complex-gateways.md`.

  ## Split semantics (diverging — 1 incoming, N outgoing)

  Like the Inclusive Split, every outgoing **conditional** flow is evaluated
  via FEEL and every truthy flow is activated (fork). The distinction:

  - Every outgoing flow MUST carry a `conditionExpression` OR be the gateway's
    `default`. Unconditional non-default flows are a **runtime** fatal
    `:complex_gateway_unconditional_flow` (WIP diagrams may still deploy).
  - 1+ truthy conditions → all truthy paths are activated (fork tokens).
  - Zero truthy + default flow → default path only.
  - Zero truthy + no default → fatal `:complex_split_no_matching_condition`.
  - Any FEEL error → fatal `:complex_split_condition_failed`.

  ## Join semantics (converging — N incoming, 1 outgoing)

  A **single-fire threshold join** driven by a FEEL `activationCondition`. The
  handler owns the same async receive-loop mechanics as the Inclusive Join
  (persist a GPA on first arrival, accumulate tokens, merge on fire), but the
  fire/error/wait DECISION lives in the PI via
  `BfwEngine.Execution.ComplexJoinEvaluator`:

  - On `{:fire}` from the PI → merge payloads, delete GPAs, finish the FNI.
  - On `{:complex_join_error, info}` from the PI → the FNI fatals with the
    structured error (Twist 1: all branches resolved, condition never met).

  ## Mixed gateway rejection

  Gateways with both >1 incoming AND >1 outgoing flows are rejected at
  runtime with a fatal `:mixed_gateway` error (also rejected at deploy).
  """

  @behaviour BfwEngine.Execution.FlowNodeHandler

  require Logger

  alias BfwEngine.BPMN.Model.FlowNode
  alias BfwEngine.Execution.FlowNodeResult
  alias BfwEngine.Execution.FniLifecycle
  alias BfwEngine.Execution.HandlerContext
  alias BfwEngine.Execution.Persistence, as: PersistenceAdapter
  alias BfwEngine.Execution.PersistenceRetry
  alias BfwEngine.Execution.SequenceFlowResolver
  alias BfwEngine.Expressions
  alias BfwEngine.Expressions.Context, as: FeelContext
  alias BfwEngine.Expressions.Result, as: FeelResult
  alias BfwEngine.Types.Token

  @spec handle_enter(FlowNode.t(), Token.t(), HandlerContext.t()) ::
          {:ok, FlowNodeResult.t()}
          | {:async, String.t(), (-> term()), map()}
          | {:error, term()}
  @impl true
  def handle_enter(flow_node, token, context) do
    {incoming, outgoing} = resolve_flow_counts(flow_node, context.process_model)
    incoming_count = length(incoming)
    outgoing_count = length(outgoing)

    cond do
      incoming_count > 1 and outgoing_count > 1 ->
        {:error,
         {:mixed_gateway,
          %{
            flow_node_id: flow_node.id,
            incoming_count: incoming_count,
            outgoing_count: outgoing_count
          }}}

      incoming_count > 1 ->
        handle_join(flow_node, token, context)

      true ->
        handle_split_and_finish(flow_node, token, context, outgoing)
    end
  end

  @doc """
  Resumes a parked Complex Join gateway from persisted GPA rows.

  Reconstructs the accumulated branch payloads and re-enters the receive
  loop; the PI re-evaluates the activation condition on resume.
  """
  @spec handle_resume(FlowNode.t(), map(), HandlerContext.t(), [map()]) ::
          {:ok, FlowNodeResult.t()} | {:async, String.t(), (-> term()), map()} | {:error, term()}
  def handle_resume(flow_node, _entry, context, persisted_arrivals) do
    sorted_arrivals = Enum.sort_by(persisted_arrivals, & &1.arrived_at, DateTime)

    branch_payloads = Enum.map(sorted_arrivals, & &1.arrived_payload)
    previous_fni_ids = Enum.map(sorted_arrivals, & &1.source_flow_node_instance_id)

    continuation = fn ->
      complex_join_receive_loop(flow_node, context, branch_payloads, previous_fni_ids)
    end

    {:async, context.flow_node_instance_id, continuation, %{join_gateway: true}}
  end

  @impl true
  def handle_fatal(_flow_node_instance_entry), do: :ok

  @impl true
  def handle_aborted(_flow_node_instance_entry), do: :ok

  # -------------------------------------------------------------------
  # Join path
  # -------------------------------------------------------------------

  defp handle_join(flow_node, token, context) do
    join_metadata = context.join_metadata || %{}
    incoming_flow_id = Map.get(join_metadata, :incoming_flow_id, "unknown")
    source_flow_node_instance_id = Map.get(join_metadata, :source_flow_node_instance_id)

    persist_gateway_pending_arrival(
      context.process_instance_id,
      context.flow_node_instance_id,
      incoming_flow_id,
      source_flow_node_instance_id,
      token.payload
    )

    previous_fni_ids =
      if source_flow_node_instance_id, do: [source_flow_node_instance_id], else: []

    continuation = fn ->
      complex_join_receive_loop(flow_node, context, [token.payload], previous_fni_ids)
    end

    {:async, context.flow_node_instance_id, continuation, %{join_gateway: true}}
  end

  defp complex_join_receive_loop(flow_node, context, branch_payloads, previous_fni_ids) do
    receive do
      {:join_token_arrived, new_token, new_previous_fni_ids, incoming_flow_id} ->
        persist_gateway_pending_arrival(
          context.process_instance_id,
          context.flow_node_instance_id,
          incoming_flow_id,
          List.first(new_previous_fni_ids),
          new_token.payload
        )

        updated_payloads = branch_payloads ++ [new_token.payload]
        updated_previous = previous_fni_ids ++ new_previous_fni_ids
        complex_join_receive_loop(flow_node, context, updated_payloads, updated_previous)

      {:fire} ->
        fire_join(flow_node, context, branch_payloads, previous_fni_ids)

      {:complex_join_error, error_info} ->
        delete_gateway_pending_arrivals(context.flow_node_instance_id)
        {:error, error_info}
    end
  end

  defp fire_join(flow_node, context, branch_payloads, previous_fni_ids) do
    delete_gateway_pending_arrivals(context.flow_node_instance_id)
    merged_payload = Enum.reduce(branch_payloads, %{}, &Map.merge(&2, &1))

    case SequenceFlowResolver.resolve(flow_node, context.process_model) do
      {:ok, targets} ->
        next_ids = Enum.map(targets, & &1.id)

        case FniLifecycle.finish(context, flow_node, merged_payload, %{},
               previous_flow_node_instance_ids: previous_fni_ids
             ) do
          {:ok, lifecycle_result} ->
            {:ok,
             %FlowNodeResult{
               output_payload: merged_payload,
               next_flow_node_ids: next_ids,
               metadata: %{persisted: true, lifecycle: lifecycle_result}
             }}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason, meta} ->
        {:error, {reason, meta}}
    end
  end

  # -------------------------------------------------------------------
  # Split path
  # -------------------------------------------------------------------

  defp handle_split_and_finish(flow_node, token, context, outgoing_flows) do
    case handle_split(flow_node, token, context, outgoing_flows) do
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
    case first_unconditional_non_default(outgoing_flows) do
      %{} = unmarked_flow ->
        {:error,
         {:complex_gateway_unconditional_flow,
          %{
            flow_node_id: flow_node.id,
            sequence_flow_id: unmarked_flow.id,
            message:
              "ComplexGateway '#{flow_node.id}' has unconditional non-default outgoing " <>
                "sequence flow '#{unmarked_flow.id}'. Add a conditionExpression or mark the flow as default."
          }}}

      nil ->
        evaluate_complex_split(flow_node, token, context, outgoing_flows)
    end
  end

  defp evaluate_complex_split(flow_node, token, context, outgoing_flows) do
    feel_context = build_feel_context(token, context)

    {conditional, rest} =
      Enum.split_with(outgoing_flows, fn sequence_flow ->
        sequence_flow.condition_expression != nil and not sequence_flow.is_default
      end)

    defaults = Enum.filter(rest, fn sequence_flow -> sequence_flow.is_default end)

    case evaluate_conditions(conditional, feel_context) do
      {:error, failed_sequence_flow, reason} ->
        {:error,
         {:complex_split_condition_failed,
          %{
            flow_node_id: flow_node.id,
            sequence_flow_id: failed_sequence_flow.id,
            expression: failed_sequence_flow.condition_expression,
            reason: to_string(reason)
          }}}

      {:ok, evaluated} ->
        truthy_flows =
          evaluated
          |> Enum.filter(fn {_sequence_flow, value} -> value == true end)
          |> Enum.map(fn {sequence_flow, _} -> sequence_flow end)

        select_outgoing(flow_node, token, truthy_flows, defaults)
    end
  end

  defp evaluate_conditions(conditional_flows, feel_context) do
    Enum.reduce_while(conditional_flows, {:ok, []}, fn sequence_flow, {:ok, accumulator} ->
      case evaluate_single_condition(sequence_flow, feel_context) do
        {:ok, boolean_value} -> {:cont, {:ok, [{sequence_flow, boolean_value} | accumulator]}}
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

  # Complex Split — unlike Inclusive, unconditional non-default flows never
  # ride along (runtime fatal `:complex_gateway_unconditional_flow` before
  # this function), so only truthy flows and the default fallback remain.
  defp select_outgoing(flow_node, token, truthy_flows, defaults) do
    case {truthy_flows, defaults} do
      {[], []} ->
        {:error, {:complex_split_no_matching_condition, %{flow_node_id: flow_node.id}}}

      {[], [default_flow | _]} ->
        {:selected, token.payload, [default_flow.target_ref]}

      {truthy, _defaults} ->
        target_ids = truthy |> Enum.map(& &1.target_ref) |> Enum.uniq()
        {:selected, token.payload, target_ids}
    end
  end

  # -------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------

  defp build_feel_context(token, handler_context) do
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

  defp persist_gateway_pending_arrival(
         process_instance_id,
         gateway_fni_id,
         incoming_flow_id,
         source_fni_id,
         payload
       ) do
    params = %{
      process_instance_id: process_instance_id,
      gateway_flow_node_instance_id: gateway_fni_id,
      source_branch_sequence_flow_id: incoming_flow_id || "unknown",
      source_flow_node_instance_id: source_fni_id || "00000000-0000-0000-0000-000000000000",
      arrived_payload: payload || %{},
      arrived_at: DateTime.utc_now()
    }

    adapter = PersistenceAdapter.adapter()

    case PersistenceRetry.with_retry(
           fn -> adapter.create_gateway_pending_arrival(params) end,
           "GPA create for complex join #{gateway_fni_id}"
         ) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to persist gateway pending arrival: #{inspect(reason)}")
        :ok
    end
  end

  defp delete_gateway_pending_arrivals(gateway_fni_id) do
    adapter = PersistenceAdapter.adapter()

    case PersistenceRetry.with_retry(
           fn -> adapter.delete_gateway_pending_arrivals_for_gateway(gateway_fni_id) end,
           "GPA delete for complex join #{gateway_fni_id}"
         ) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to delete gateway pending arrivals: #{inspect(reason)}")
        :ok
    end
  end
end

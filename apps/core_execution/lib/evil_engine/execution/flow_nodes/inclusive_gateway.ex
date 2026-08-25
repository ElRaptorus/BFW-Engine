defmodule EvilEngine.Execution.FlowNodes.InclusiveGateway do
  @moduledoc """
  Handler for `<bpmn:inclusiveGateway>`.

  ## Split semantics (diverging — 1 incoming, N outgoing)

  Evaluates ALL outgoing conditional sequence flows using FEEL and
  activates every flow whose condition evaluates to `true`:

  - 1+ truthy conditions → all truthy paths are activated (fork tokens),
    along with any unconditional non-default flows.
  - Zero truthy + default flow → default path only.
  - Zero truthy + no default → fatal `:no_matching_condition`.
  - Any FEEL error → fatal `:expression_evaluation_failed`.

  This is the key distinction from ExclusiveGateway (which rejects
  multi-truthy as `:ambiguous_condition`) and from ParallelGateway
  (which unconditionally activates all outgoing flows).

  ## Join semantics (converging — N incoming, 1 outgoing)

  The handler owns dead-path-elimination synchronisation as a stateful
  async Task. On the first token arrival, `handle_enter/3` persists a GPA
  row and returns `{:async, fni_id, continuation}`. The continuation
  blocks on `receive`, accumulating tokens via `{:join_token_arrived, ...}`
  messages from the PI. After each arrival and on `{:fire}` signals from
  the PI (triggered by dead-path elimination on FNI state changes), the
  handler checks via `InclusiveJoinEvaluator.should_fire?/4` whether all
  live paths are resolved. When ready, it merges payloads, deletes GPAs,
  calls `FniLifecycle.finish/4`, and returns `{:ok, %FlowNodeResult{}}`.

  ## Mixed gateway rejection

  Gateways with both >1 incoming AND >1 outgoing flows are rejected
  at runtime with a fatal `:mixed_gateway` error.
  """

  @behaviour EvilEngine.Execution.FlowNodeHandler

  require Logger

  alias EvilEngine.BPMN.Model.FlowNode
  alias EvilEngine.Execution.FlowNodeResult
  alias EvilEngine.Execution.FniLifecycle
  alias EvilEngine.Execution.HandlerContext
  alias EvilEngine.Execution.InclusiveJoinEvaluator
  alias EvilEngine.Execution.Persistence, as: PersistenceAdapter
  alias EvilEngine.Execution.PersistenceRetry
  alias EvilEngine.Execution.SequenceFlowResolver
  alias EvilEngine.Expressions
  alias EvilEngine.Expressions.Context, as: FeelContext
  alias EvilEngine.Expressions.Result, as: FeelResult
  alias EvilEngine.Types.Token

  @doc """
  Pure function called by the PI from `evaluate_parked_inclusive_joins`
  after every FNI state change. Delegates to `InclusiveJoinEvaluator`.

  Returns `true` when all incoming flows are either arrived or dead
  (no active upstream FNI can deliver a token), and at least one has arrived.
  """
  @spec should_fire?(String.t(), MapSet.t(String.t()), map(), struct()) :: boolean()
  def should_fire?(flow_node_id, arrived_via_flow_ids, flow_node_instance_states, process_model) do
    InclusiveJoinEvaluator.should_fire?(
      flow_node_id,
      arrived_via_flow_ids,
      flow_node_instance_states,
      process_model
    )
  end

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
        handle_join(flow_node, token, context, incoming_count)

      true ->
        handle_split_and_finish(flow_node, token, context, outgoing)
    end
  end

  @doc """
  Resumes a parked inclusive join gateway from persisted GPA rows.

  Called by `Resumption` when reactivating a join FNI after engine restart.
  Reconstructs the handler's internal state from `persisted_arrivals` and
  either fires immediately (if every incoming already arrived) or enters
  the async receive loop. Structural dead-path elimination is re-evaluated
  by the Process Instance (`evaluate_parked_inclusive_joins/1`), which
  signals the parked join to fire when the remaining incomings are dead.
  """
  @spec handle_resume(FlowNode.t(), map(), HandlerContext.t(), [map()]) ::
          {:ok, FlowNodeResult.t()} | {:async, String.t(), (-> term()), map()} | {:error, term()}
  def handle_resume(flow_node, _entry, context, persisted_arrivals) do
    sorted_arrivals = Enum.sort_by(persisted_arrivals, & &1.arrived_at, DateTime)

    branch_payloads = Enum.map(sorted_arrivals, & &1.arrived_payload)
    previous_fni_ids = Enum.map(sorted_arrivals, & &1.source_flow_node_instance_id)

    {incoming, _outgoing} = resolve_flow_counts(flow_node, context.process_model)
    required = length(incoming)
    arrived = length(persisted_arrivals)

    if arrived >= required and required > 0 do
      fire_join(flow_node, context, branch_payloads, previous_fni_ids)
    else
      continuation = fn ->
        inclusive_join_receive_loop(flow_node, context, branch_payloads, previous_fni_ids)
      end

      {:async, context.flow_node_instance_id, continuation, %{join_gateway: true}}
    end
  end

  @impl true
  def handle_fatal(_flow_node_instance_entry) do
    :ok
  end

  @impl true
  def handle_aborted(_flow_node_instance_entry) do
    :ok
  end

  defp handle_join(flow_node, token, context, required) do
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

    previous_fni_ids = if source_flow_node_instance_id, do: [source_flow_node_instance_id], else: []

    if required == 1 do
      fire_join(flow_node, context, [token.payload], previous_fni_ids)
    else
      continuation = fn ->
        inclusive_join_receive_loop(flow_node, context, [token.payload], previous_fni_ids)
      end

      {:async, context.flow_node_instance_id, continuation, %{join_gateway: true}}
    end
  end

  defp inclusive_join_receive_loop(flow_node, context, branch_payloads, previous_fni_ids) do
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
        inclusive_join_receive_loop(flow_node, context, updated_payloads, updated_previous)

      {:fire} ->
        fire_join(flow_node, context, branch_payloads, previous_fni_ids)
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
    feel_context = build_feel_context(flow_node, token, context)

    {conditional, rest} =
      Enum.split_with(outgoing_flows, fn sequence_flow ->
        sequence_flow.condition_expression != nil and not sequence_flow.is_default
      end)

    {defaults, unconditional} =
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

        select_outgoing(flow_node, token, truthy_flows, defaults, unconditional)
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

  defp select_outgoing(flow_node, token, truthy_flows, defaults, unconditional) do
    case {truthy_flows, defaults} do
      {[], []} ->
        {:error,
         %{
           reason: :no_matching_condition,
           flow_node_id: flow_node.id,
           message: "No outgoing sequence flow with a fulfilled condition"
         }}

      {[], [default_flow | _]} ->
        {:selected, token.payload, [default_flow.target_ref]}

      {truthy, _defaults} ->
        all_activated = truthy ++ unconditional
        target_ids = all_activated |> Enum.map(& &1.target_ref) |> Enum.uniq()
        {:selected, token.payload, target_ids}
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

  defp persist_gateway_pending_arrival(process_instance_id, gateway_fni_id, incoming_flow_id, source_fni_id, payload) do
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
           "GPA create for inclusive join #{gateway_fni_id}"
         ) do
      {:ok, _} -> :ok

      {:error, reason} ->
        Logger.warning("Failed to persist gateway pending arrival: #{inspect(reason)}")
        :ok
    end
  end

  defp delete_gateway_pending_arrivals(gateway_fni_id) do
    adapter = PersistenceAdapter.adapter()

    case PersistenceRetry.with_retry(
           fn -> adapter.delete_gateway_pending_arrivals_for_gateway(gateway_fni_id) end,
           "GPA delete for inclusive join #{gateway_fni_id}"
         ) do
      :ok -> :ok

      {:error, reason} ->
        Logger.warning("Failed to delete gateway pending arrivals: #{inspect(reason)}")
        :ok
    end
  end
end

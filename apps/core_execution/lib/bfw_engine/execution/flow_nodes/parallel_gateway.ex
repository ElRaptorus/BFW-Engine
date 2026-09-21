defmodule BfwEngine.Execution.FlowNodes.ParallelGateway do
  @moduledoc """
  Handler for `<bpmn:parallelGateway>`.

  ## Fork semantics (diverging — 1 incoming, N outgoing)

  Dispatches ALL outgoing sequence flows simultaneously by returning
  every outgoing target as a `next_flow_node_id`. The PI creates one FNI
  per target, running them concurrently.

  ## Join semantics (converging — N incoming, 1 outgoing)

  The handler owns wait-for-all synchronisation as a stateful async Task.
  On the first token arrival, `handle_enter/3` persists a gateway pending
  arrival (GPA) row and returns `{:async, fni_id, continuation}`. The
  continuation blocks on `receive`, accumulating subsequent tokens sent by
  the PI via `{:join_token_arrived, ...}` messages. When all incoming
  branches have reported (`arrived >= required`), the handler merges
  payloads, deletes GPA rows, calls `FniLifecycle.finish/4`, and returns
  `{:ok, %FlowNodeResult{}}`.

  For the degenerate single-incoming case (`required == 1`), the handler
  completes synchronously without entering the async receive loop.

  ## Mixed gateway rejection

  Gateways with both >1 incoming AND >1 outgoing flows are rejected
  at runtime with a fatal `:mixed_gateway` error — the same constraint
  as the Exclusive Gateway.
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
  alias BfwEngine.Types.Token

  @spec handle_enter(FlowNode.t(), Token.t(), HandlerContext.t()) ::
          {:ok, FlowNodeResult.t()}
          | {:async, String.t(), (-> term()), map()}
          | {:error, term()}
  @impl true
  def handle_enter(flow_node, token, context) do
    {incoming_count, outgoing_count} =
      resolve_flow_counts(flow_node, context.process_model)

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
        handle_fork(flow_node, token, context)
    end
  end

  @doc """
  Resumes a parked join gateway from persisted GPA rows.

  Called by `Resumption` when reactivating a join FNI after engine restart.
  Reconstructs the handler's internal state from `persisted_arrivals` and
  either fires immediately (if all branches arrived before restart) or
  enters the async receive loop to wait for remaining branches.
  """
  @spec handle_resume(FlowNode.t(), map(), HandlerContext.t(), [map()]) ::
          {:ok, FlowNodeResult.t()} | {:async, String.t(), (-> term()), map()} | {:error, term()}
  def handle_resume(flow_node, _entry, context, persisted_arrivals) do
    required = resolve_incoming_count(flow_node, context.process_model)
    arrived = length(persisted_arrivals)
    sorted_arrivals = Enum.sort_by(persisted_arrivals, & &1.arrived_at, DateTime)

    branch_payloads = Enum.map(sorted_arrivals, & &1.arrived_payload)
    previous_fni_ids = Enum.map(sorted_arrivals, & &1.source_flow_node_instance_id)

    if arrived >= required do
      fire_join(flow_node, context, branch_payloads, previous_fni_ids)
    else
      arrived_flow_ids =
        persisted_arrivals
        |> Enum.map(& &1.source_branch_sequence_flow_id)
        |> MapSet.new()

      continuation = fn ->
        join_receive_loop(%{
          flow_node: flow_node,
          context: context,
          branch_payloads: branch_payloads,
          previous_fni_ids: previous_fni_ids,
          arrived: arrived,
          required: required,
          arrived_flow_ids: arrived_flow_ids
        })
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

    previous_fni_ids =
      if source_flow_node_instance_id, do: [source_flow_node_instance_id], else: []

    if required == 1 do
      fire_join(flow_node, context, [token.payload], previous_fni_ids)
    else
      continuation = fn ->
        join_receive_loop(%{
          flow_node: flow_node,
          context: context,
          branch_payloads: [token.payload],
          previous_fni_ids: previous_fni_ids,
          arrived: 1,
          required: required,
          arrived_flow_ids: MapSet.new([incoming_flow_id])
        })
      end

      {:async, context.flow_node_instance_id, continuation, %{join_gateway: true}}
    end
  end

  defp join_receive_loop(state) do
    receive do
      {:join_token_arrived, new_token, new_previous_fni_ids, incoming_flow_id} ->
        handle_parallel_join_arrival(state, new_token, new_previous_fni_ids, incoming_flow_id)
    end
  end

  defp handle_parallel_join_arrival(state, new_token, new_previous_fni_ids, incoming_flow_id) do
    duplicate? =
      MapSet.member?(state.arrived_flow_ids, incoming_flow_id) and incoming_flow_id != "unknown"

    if duplicate? do
      Logger.warning(
        "ParallelGateway: ignoring duplicate arrival at '#{state.flow_node.id}' " <>
          "via sequence flow '#{incoming_flow_id}'"
      )

      join_receive_loop(state)
    else
      apply_parallel_join_arrival(state, new_token, new_previous_fni_ids, incoming_flow_id)
    end
  end

  defp apply_parallel_join_arrival(state, new_token, new_previous_fni_ids, incoming_flow_id) do
    persist_gateway_pending_arrival(
      state.context.process_instance_id,
      state.context.flow_node_instance_id,
      incoming_flow_id,
      List.first(new_previous_fni_ids),
      new_token.payload
    )

    updated_payloads = state.branch_payloads ++ [new_token.payload]
    updated_previous = state.previous_fni_ids ++ new_previous_fni_ids
    new_arrived = state.arrived + 1

    if new_arrived >= state.required do
      fire_join(state.flow_node, state.context, updated_payloads, updated_previous)
    else
      join_receive_loop(%{
        state
        | branch_payloads: updated_payloads,
          previous_fni_ids: updated_previous,
          arrived: new_arrived,
          arrived_flow_ids: MapSet.put(state.arrived_flow_ids, incoming_flow_id)
      })
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

  defp handle_fork(flow_node, token, context) do
    case SequenceFlowResolver.resolve(flow_node, context.process_model) do
      {:ok, targets} ->
        output_payload = token.payload
        next_ids = Enum.map(targets, & &1.id)

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

      {:error, reason, meta} ->
        {:error, {reason, meta}}
    end
  end

  defp resolve_incoming_count(flow_node, process_model) do
    all_flows = process_model.sequence_flows || []

    case flow_node.incoming do
      ids when is_list(ids) and ids != [] -> length(ids)
      _ -> Enum.count(all_flows, &(&1.target_ref == flow_node.id))
    end
  end

  defp resolve_flow_counts(flow_node, process_model) do
    all_flows = process_model.sequence_flows || []

    incoming_count =
      case flow_node.incoming do
        ids when is_list(ids) and ids != [] ->
          length(ids)

        _ ->
          Enum.count(all_flows, &(&1.target_ref == flow_node.id))
      end

    outgoing_count =
      case flow_node.outgoing do
        ids when is_list(ids) and ids != [] ->
          length(ids)

        _ ->
          Enum.count(all_flows, &(&1.source_ref == flow_node.id))
      end

    {incoming_count, outgoing_count}
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
           "GPA create for parallel join #{gateway_fni_id}"
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
           "GPA delete for parallel join #{gateway_fni_id}"
         ) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to delete gateway pending arrivals: #{inspect(reason)}")
        :ok
    end
  end
end

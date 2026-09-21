defmodule BfwEngine.Execution.ComplexJoinEvaluator do
  @moduledoc """
  Runtime fire/error/wait decision for Complex Gateway joins.

  A Complex Join is a **single-fire threshold join** driven by a FEEL
  `activationCondition`. Unlike the Inclusive Join (which fires purely on
  dead-path exhaustion), the Complex Join fires the moment its condition
  becomes true, and errors if every incoming branch resolves without the
  condition ever being met (Twist 1).

  The decision, evaluated on every token arrival and on every FNI state
  change in the PI (mirroring `evaluate_parked_inclusive_joins`), is:

  1. Evaluate `activationCondition` with the standard FEEL bindings plus
     the top-level `activatedCount` (distinct arrived branches) and
     `incomingCount` (total incoming branches) bindings.
       - **true** → `:fire`
       - **false** → step 2
  2. If every incoming branch is *arrived* or *dead* (no live upstream FNI,
     via `InclusiveJoinEvaluator.all_incoming_resolved?/4`) → `{:error, info}`
     (Twist 1: `complex_join_condition_unmet`).
  3. Otherwise → `:wait`.

  A FEEL evaluation error yields `{:error, info}` with
  `complex_join_condition_failed`.

  The `token` binding is the merged accumulation of the branch payloads that
  have arrived so far (tracked on the PI's `join_routing` entry as
  `merged_payload`). The evaluator itself is pure with respect to PI state —
  it never mutates or sends messages.
  """

  alias BfwEngine.BPMN.Model.FlowNode
  alias BfwEngine.Execution.InclusiveJoinEvaluator
  alias BfwEngine.Expressions
  alias BfwEngine.Expressions.Context, as: FeelContext
  alias BfwEngine.Expressions.Result, as: FeelResult

  @type decision :: :fire | {:error, {atom(), map()}} | :wait

  @doc """
  Decide whether a parked Complex Join should fire, error, or keep waiting.

  `routing` is the PI's `join_routing_entry` for this join (carrying
  `arrived_via_flow_ids` and `merged_payload`). `pi_state` is the PI's
  `%State{}` struct, used to build the FEEL context and to run dead-path
  resolution.
  """
  @spec evaluate(FlowNode.t(), map(), struct()) :: decision()
  def evaluate(%FlowNode{} = flow_node, routing, pi_state) do
    activation_condition = activation_condition(flow_node, routing)
    arrived_via_flow_ids = routing.arrived_via_flow_ids
    activated_count = MapSet.size(arrived_via_flow_ids)
    incoming_count = incoming_count(flow_node, pi_state.process_model)

    case evaluate_condition(flow_node, routing, pi_state, activated_count, incoming_count) do
      {:ok, true} ->
        :fire

      {:ok, false} ->
        resolve_or_wait(
          flow_node,
          arrived_via_flow_ids,
          pi_state,
          activation_condition,
          activated_count,
          incoming_count
        )

      {:error, reason} ->
        {:error,
         {:complex_join_condition_failed,
          %{
            flow_node_id: flow_node.id,
            activation_condition: activation_condition,
            reason: to_string(reason)
          }}}
    end
  end

  # -------------------------------------------------------------------
  # Condition evaluation
  # -------------------------------------------------------------------

  defp evaluate_condition(flow_node, routing, pi_state, activated_count, incoming_count) do
    activation_condition = activation_condition(flow_node, routing)

    if blank?(activation_condition) do
      {:error, "activationCondition is blank"}
    else
      feel_context =
        flow_node
        |> build_feel_context(routing_payload(routing), pi_state)
        |> FeelContext.put_gateway_bindings(activated_count, incoming_count)

      activation_condition
      |> Expressions.eval(feel_context)
      |> FeelResult.to_boolean()
    end
  rescue
    exception ->
      {:error, Exception.message(exception)}
  end

  defp resolve_or_wait(
         flow_node,
         arrived_via_flow_ids,
         pi_state,
         activation_condition,
         activated_count,
         incoming_count
       ) do
    all_resolved =
      InclusiveJoinEvaluator.all_incoming_resolved?(
        flow_node.id,
        arrived_via_flow_ids,
        pi_state.flow_node_instance_states,
        pi_state.process_model
      )

    if all_resolved do
      {:error,
       {:complex_join_condition_unmet,
        %{
          flow_node_id: flow_node.id,
          activation_condition: activation_condition,
          activated_count: activated_count,
          incoming_count: incoming_count
        }}}
    else
      :wait
    end
  end

  # -------------------------------------------------------------------
  # FEEL context (built from PI state, mirroring ConditionalCatchEvent)
  # -------------------------------------------------------------------

  defp build_feel_context(flow_node, token_payload, pi_state) do
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
  # Helpers
  # -------------------------------------------------------------------

  defp activation_condition(%FlowNode{type_data: %{activation_condition: condition}}, _routing)
       when is_binary(condition),
       do: condition

  defp activation_condition(_flow_node, routing), do: Map.get(routing, :activation_condition)

  defp routing_payload(routing), do: Map.get(routing, :merged_payload) || %{}

  defp incoming_count(%FlowNode{incoming: ids}, _process_model) when is_list(ids) and ids != [] do
    length(ids)
  end

  defp incoming_count(%FlowNode{id: node_id}, process_model) do
    Enum.count(process_model.sequence_flows || [], &(&1.target_ref == node_id))
  end

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_), do: false
end

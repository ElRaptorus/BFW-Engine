defmodule BfwEngine.Execution.CompensationResolver do
  @moduledoc """
  Pure resolver for compensation targets.

  Given a compensation registry (list of completed-activity entries), an
  event definition (which may carry an `activity_ref`), and the process
  model, resolves the ordered list of compensation targets.

  ## Resolution modes

  - **`activityRef` present:** select the single registry entry whose
    `flow_node_id` matches; return it in a one-element list. If no
    matching entry exists, return `[]` (no-op — the activity either
    never completed or has no compensation handler).
  - **Broadcast (no `activityRef`):** select all entries in the scope,
    reverse completion order (LIFO).

  This module is pure — it does not mutate state, spawn processes, or
  interact with persistence. Sibling of `EscalationResolver`.
  """

  alias BfwEngine.BPMN.Model.EventDefinition

  @type registry_entry :: %{
          completed_fni_id: String.t(),
          flow_node_id: String.t(),
          handler_activity_id: String.t(),
          token_snapshot: map(),
          completion_order: non_neg_integer()
        }

  @doc """
  Resolve compensation targets from the registry.

  Returns a list of registry entries ordered for execution (LIFO for
  broadcast, single entry for activityRef).
  """
  @spec resolve([registry_entry()], EventDefinition.Compensation.t()) ::
          [registry_entry()]
  def resolve(compensation_registry, %EventDefinition.Compensation{
        activity_ref: activity_ref
      }) do
    if activity_ref != nil and activity_ref != "" do
      resolve_single(compensation_registry, activity_ref)
    else
      resolve_broadcast(compensation_registry)
    end
  end

  defp resolve_single(registry, activity_ref) do
    case Enum.find(registry, fn entry -> entry.flow_node_id == activity_ref end) do
      nil -> []
      entry -> [entry]
    end
  end

  defp resolve_broadcast(registry) do
    registry
    |> Enum.sort_by(& &1.completion_order, :desc)
  end
end

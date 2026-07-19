defmodule EvilEngine.Execution.ProcessInstance.StartEventResolver do
  @moduledoc """
  Resolves the initial Start Event for a process model.

  Extracted from `ProcessInstance.resolve_start_event/2` so that both
  `StandardMode` and any future mode can reuse the resolution logic
  without depending on private functions inside the PI `:gen_statem`.

  ## Isolation invariant

  Resolution is strictly scoped to `process_model.flow_nodes`. When
  the model was built from a subprocess scope (`subprocess_node_id`),
  `flow_nodes` contains only that subprocess's inner nodes. A Start
  Event nested inside a subprocess can never be resolved from a
  top-level start, and vice versa. Any refactor that broadens this
  lookup (e.g. recursing into `type_data.flow_nodes`) would break
  subprocess start-event isolation and must be rejected.
  """

  alias EvilEngine.BPMN.Model.EventDefinition
  alias EvilEngine.BPMN.Model.FlowNode
  alias EvilEngine.BPMN.Model.Process, as: BpmnProcess

  @doc """
  Resolve the Start Event for the given process model.

  When `start_event_id` is non-nil and matches a typed (non-None) Start
  Event, that event is returned directly. Otherwise, untyped (None) Start
  Events are filtered and resolved by `start_event_id` or by uniqueness.

  Returns `{:ok, %FlowNode{}}` on success, or `{:error, atom, message}`
  on failure.
  """
  @spec resolve(BpmnProcess.t(), String.t() | nil) ::
          {:ok, FlowNode.t()} | {:error, atom(), String.t()}
  def resolve(process_model, start_event_id) do
    case resolve_typed_start_event(process_model, start_event_id) do
      {:ok, _node} = result ->
        result

      :not_typed ->
        untyped_starts =
          Enum.filter(process_model.flow_nodes, fn node ->
            node.type == :start_event and
              match?(%EventDefinition.None{}, node.type_data.event_definition)
          end)

        do_resolve(untyped_starts, start_event_id, process_model.id)
    end
  end

  defp resolve_typed_start_event(_process_model, nil), do: :not_typed

  defp resolve_typed_start_event(process_model, start_event_id) do
    case Enum.find(process_model.flow_nodes, fn node ->
           node.type == :start_event and node.id == start_event_id and
             not match?(%EventDefinition.None{}, node.type_data.event_definition)
         end) do
      nil -> :not_typed
      typed_start -> {:ok, typed_start}
    end
  end

  defp do_resolve([], _start_event_id, process_id) do
    {:error, :no_start_event, "Process '#{process_id}' has no untyped Start Event."}
  end

  defp do_resolve([single], nil, _process_id) do
    {:ok, single}
  end

  defp do_resolve([single], id, _process_id) when id == single.id do
    {:ok, single}
  end

  defp do_resolve([single], id, process_id) do
    {:error, :start_event_not_found,
     "Start Event '#{id}' not found in process '#{process_id}'. Available: #{single.id}"}
  end

  defp do_resolve(starts, nil, process_id) when length(starts) > 1 do
    ids = Enum.map_join(starts, ", ", & &1.id)

    {:error, :ambiguous_start_event,
     "Process '#{process_id}' has #{length(starts)} start events, " <>
       "but no startEventId was provided. Available: #{ids}"}
  end

  defp do_resolve(starts, id, process_id) do
    case Enum.find(starts, &(&1.id == id)) do
      nil ->
        ids = Enum.map_join(starts, ", ", & &1.id)

        {:error, :start_event_not_found,
         "Start Event '#{id}' not found in process '#{process_id}'. Available: #{ids}"}

      found ->
        {:ok, found}
    end
  end
end

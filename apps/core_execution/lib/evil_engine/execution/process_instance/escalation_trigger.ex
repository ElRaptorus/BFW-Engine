defmodule EvilEngine.Execution.ProcessInstance.EscalationTrigger do
  @moduledoc """
  Resolves waiting Escalation Boundary catchers for an API/debugger inject.

  A modeled BPMN throw still walks the parent chain. This helper only
  lists **currently waiting** catchers in one Process Instance so
  `POST /escalations/{code}/trigger` can fire them through the existing
  `BoundaryOrchestrator.handle_boundary_catch/5` path.

  Matching reuses `EscalationResolver` specificity: a specific code beats
  a catch-all on the same host; non-interrupting matches all fire.
  """

  alias EvilEngine.BPMN.Model.EventDefinition
  alias EvilEngine.BPMN.Model.FlowNode
  alias EvilEngine.Execution.EscalationResolver
  alias EvilEngine.Execution.ProcessInstance.Helpers

  @type boundary_fire :: %{
          host_flow_node_instance_id: String.t(),
          boundary_node_id: String.t(),
          boundary_flow_node_instance_id: String.t(),
          cancel_activity: boolean()
        }

  @doc """
  Returns boundary fires for waiters in `data` that match `escalation_info`.

  Hosts whose FNI is no longer `:active` or `:waiting` are skipped.
  """
  @spec matching_waiting_boundaries(struct(), map()) :: [boundary_fire()]
  def matching_waiting_boundaries(data, escalation_info) do
    process_model = data.process_model
    definitions = data.definitions

    if is_nil(process_model) or is_nil(definitions) do
      []
    else
      waiting_by_host = waiting_escalation_boundaries_by_host(data)

      waiting_by_host
      |> Map.keys()
      |> Enum.flat_map(fn host_fni_id ->
        fires_for_host(
          data,
          process_model,
          definitions,
          escalation_info,
          host_fni_id,
          waiting_by_host
        )
      end)
    end
  end

  defp waiting_escalation_boundaries_by_host(data) do
    Enum.reduce(data.flow_node_instance_states, %{}, fn {fni_id, entry}, accumulator ->
      collect_waiting_escalation_boundary(data, fni_id, entry, accumulator)
    end)
  end

  defp collect_waiting_escalation_boundary(data, fni_id, entry, accumulator)
       when entry.state in [:waiting, :active] do
    case Helpers.find_flow_node(data, entry.flow_node_id) do
      %FlowNode{type: :boundary_event, type_data: type_data} ->
        if match?(%EventDefinition.Escalation{}, type_data.event_definition) do
          host_id = Helpers.resolve_host_fni_id(data, fni_id)
          host_waiters = Map.get(accumulator, host_id, [])
          waiter = %{flow_node_instance_id: fni_id, flow_node_id: entry.flow_node_id}
          Map.put(accumulator, host_id, [waiter | host_waiters])
        else
          accumulator
        end

      _other ->
        accumulator
    end
  end

  defp collect_waiting_escalation_boundary(_data, _fni_id, _entry, accumulator), do: accumulator

  defp fires_for_host(
         data,
         process_model,
         definitions,
         escalation_info,
         host_fni_id,
         waiting_by_host
       ) do
    case Map.get(data.flow_node_instance_states, host_fni_id) do
      %{state: state, flow_node_id: host_node_id} when state in [:active, :waiting] ->
        host_node = Helpers.find_flow_node(data, host_node_id)
        waiters = Map.get(waiting_by_host, host_fni_id, [])

        build_host_fires(
          host_node,
          process_model,
          definitions,
          escalation_info,
          host_fni_id,
          waiters
        )

      _other ->
        []
    end
  end

  defp build_host_fires(nil, _process_model, _definitions, _info, _host_fni_id, _waiters), do: []

  defp build_host_fires(
         host_node,
         process_model,
         definitions,
         escalation_info,
         host_fni_id,
         waiters
       ) do
    interrupting_fire =
      interrupting_fire_for_host(
        host_node,
        process_model,
        definitions,
        escalation_info,
        host_fni_id,
        waiters
      )

    non_interrupting_fires =
      EscalationResolver.find_non_interrupting_escalation_boundaries(
        host_node,
        process_model,
        definitions,
        escalation_info
      )
      |> Enum.flat_map(&non_interrupting_fire(&1, host_fni_id, waiters))

    interrupting_fire ++ non_interrupting_fires
  end

  defp interrupting_fire_for_host(
         host_node,
         process_model,
         definitions,
         escalation_info,
         host_fni_id,
         waiters
       ) do
    case EscalationResolver.find_first_interrupting_escalation_boundary(
           host_node,
           process_model,
           definitions,
           escalation_info
         ) do
      {:ok, boundary_node} ->
        case waiter_for_node(waiters, boundary_node.id) do
          nil ->
            []

          waiter ->
            [
              %{
                host_flow_node_instance_id: host_fni_id,
                boundary_node_id: boundary_node.id,
                boundary_flow_node_instance_id: waiter.flow_node_instance_id,
                cancel_activity: true
              }
            ]
        end

      :none ->
        []
    end
  end

  defp non_interrupting_fire(boundary_node, host_fni_id, waiters) do
    case waiter_for_node(waiters, boundary_node.id) do
      nil ->
        []

      waiter ->
        [
          %{
            host_flow_node_instance_id: host_fni_id,
            boundary_node_id: boundary_node.id,
            boundary_flow_node_instance_id: waiter.flow_node_instance_id,
            cancel_activity: false
          }
        ]
    end
  end

  defp waiter_for_node(waiters, boundary_node_id) do
    Enum.find(waiters, &(&1.flow_node_id == boundary_node_id))
  end
end

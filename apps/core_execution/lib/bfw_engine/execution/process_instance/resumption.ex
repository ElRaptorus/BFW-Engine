defmodule BfwEngine.Execution.ProcessInstance.Resumption do
  @moduledoc """
  Handles PI resume-after-restart: identity rebuild, FNI state reconstruction,
  and handler reactivation.
  """

  require Logger

  import BfwEngine.Execution.ProcessInstance.Helpers

  alias BfwEngine.BPMN.Model.EventDefinition
  alias BfwEngine.BPMN.Model.FlowNode
  alias BfwEngine.BPMN.Model.FlowNodeData
  alias BfwEngine.Events.EngineEventBus
  alias BfwEngine.Execution.BoundaryAwareHandler
  alias BfwEngine.Execution.FlowNodes
  alias BfwEngine.Execution.FniLifecycle
  alias BfwEngine.Execution.HandlerDispatch
  alias BfwEngine.Execution.Persistence, as: PersistenceAdapter
  alias BfwEngine.Execution.PersistenceRetry
  alias BfwEngine.Execution.ProcessInstance.BoundaryOrchestrator
  alias BfwEngine.Types.Event
  alias BfwEngine.Types.Identity
  alias BfwEngine.Types.Token

  @doc """
  Rebuilds persisted FNI rows into in-memory state, reconstructs join routing
  from `gateway_pending_arrivals`, and reactivates waiting/active FNIs.
  """
  @spec resume(struct(), [map()], [map()], pid()) :: struct()
  def resume(data, persisted_flow_node_instances, pending_arrivals, process_instance_pid) do
    grouped_arrivals = Enum.group_by(pending_arrivals, & &1.gateway_flow_node_instance_id)

    data
    |> rebuild_flow_node_instance_states(persisted_flow_node_instances)
    |> rebuild_compensation_registry()
    |> rebuild_join_routing(pending_arrivals)
    |> reactivate_fnis(process_instance_pid, grouped_arrivals)
  end

  @doc "Reconstructs identity from persisted `started_by` data."
  @spec rebuild_identity(map() | nil) :: Identity.t() | nil
  def rebuild_identity(nil), do: nil

  def rebuild_identity(%{"id" => id} = map) do
    %Identity{
      id: id,
      roles: Map.get(map, "roles", []),
      groups: Map.get(map, "groups", [])
    }
  end

  def rebuild_identity(_other), do: nil

  @doc "Rebuilds the in-memory FNI state map from persistence data."
  @spec rebuild_flow_node_instance_states(struct(), [map()]) :: struct()
  def rebuild_flow_node_instance_states(data, flow_node_instance_data) do
    flow_node_instance_states =
      Map.new(flow_node_instance_data, fn flow_node_instance ->
        token = %Token{
          id: generate_id(),
          process_instance_id: data.process_instance_id,
          payload: flow_node_instance.input_token,
          originating_flow_node_instance_id: nil,
          created_at: flow_node_instance.started_at || DateTime.utc_now()
        }

        entry = %{
          pid: nil,
          flow_node_id: flow_node_instance.flow_node_id,
          flow_node_type: parse_flow_node_type(flow_node_instance.flow_node_type),
          event_type: Map.get(flow_node_instance, :event_type),
          state: parse_fni_state(flow_node_instance.state),
          token: token,
          previous_flow_node_instance_ids:
            flow_node_instance.previous_flow_node_instance_ids || [],
          type_properties: flow_node_instance.type_properties || %{},
          next_flow_node_ids: [],
          multi_instance_id: Map.get(flow_node_instance, :multi_instance_id),
          iteration_index: Map.get(flow_node_instance, :iteration_index)
        }

        {flow_node_instance.id, entry}
      end)

    %{data | flow_node_instance_states: flow_node_instance_states}
  end

  @doc """
  Re-derives the compensation registry from persisted FNI state.

  Scans all `:finished` FNIs, checks whether their BPMN flow node has a
  Compensation Boundary Event with a resolved handler, and rebuilds the
  LIFO-ordered registry. The ordering is derived from `started_at` or
  fallback index, since persistence does not store the original counter.
  """
  @spec rebuild_compensation_registry(struct()) :: struct()
  def rebuild_compensation_registry(data) do
    node_index = Map.new(data.process_model.flow_nodes, &{&1.id, &1})

    {entries, counter} =
      data.flow_node_instance_states
      |> Enum.filter(fn {_fni_id, entry} -> entry.state == :finished end)
      |> Enum.sort_by(fn {_fni_id, entry} ->
        entry.token.created_at
      end)
      |> Enum.reduce({[], 0}, fn {fni_id, entry}, {accumulator, order} ->
        flow_node = Map.get(node_index, entry.flow_node_id)
        handler_id = find_compensation_handler_id(flow_node, node_index)

        if handler_id do
          new_entry = %{
            completed_fni_id: fni_id,
            flow_node_id: entry.flow_node_id,
            handler_activity_id: handler_id,
            token_snapshot: entry.token.payload,
            completion_order: order
          }

          {[new_entry | accumulator], order + 1}
        else
          {accumulator, order}
        end
      end)

    %{data | compensation_registry: entries, compensation_completion_counter: counter}
  end

  defp find_compensation_handler_id(nil, _node_index), do: nil

  defp find_compensation_handler_id(%FlowNode{} = flow_node, node_index) do
    Enum.find_value(flow_node.boundary_event_refs, fn boundary_ref ->
      case Map.get(node_index, boundary_ref) do
        %FlowNode{
          type: :boundary_event,
          type_data: %FlowNodeData.BoundaryEvent{
            event_definition: %EventDefinition.Compensation{},
            compensation_handler_id: handler_id
          }
        }
        when handler_id != nil ->
          handler_id

        _ ->
          nil
      end
    end)
  end

  @doc """
  Rebuilds `join_routing` from persisted `gateway_pending_arrivals` rows.

  Groups arrival rows by `gateway_flow_node_instance_id`, looks up each
  gateway FNI in `flow_node_instance_states` to find the BPMN `flow_node_id`,
  then counts incoming sequence flows from the process model to determine
  `required`. The result is stored in `data.join_routing` keyed by BPMN
  `flow_node_id`. The handler Task will receive the full GPA rows on resume
  to reconstruct its internal branch_payloads state.
  """
  @spec rebuild_join_routing(struct(), [map()]) :: struct()
  def rebuild_join_routing(data, pending_arrivals) do
    grouped = Enum.group_by(pending_arrivals, & &1.gateway_flow_node_instance_id)

    join_routing =
      Enum.reduce(grouped, %{}, fn {gateway_fni_id, rows}, accumulator ->
        rebuild_single_join_routing(data, accumulator, gateway_fni_id, rows)
      end)

    join_routing = ensure_active_join_gateways_routed(data, join_routing)

    %{data | join_routing: join_routing}
  end

  defp rebuild_single_join_routing(data, accumulator, gateway_fni_id, rows) do
    case Map.get(data.flow_node_instance_states, gateway_fni_id) do
      nil ->
        accumulator

      entry ->
        flow_node_id = entry.flow_node_id
        required = count_incoming_flows(data.process_model, flow_node_id)
        gateway_type = resume_gateway_type(entry.flow_node_type)

        arrived_via_flow_ids =
          rows
          |> Enum.map(& &1.source_branch_sequence_flow_id)
          |> Enum.reject(&(&1 == "unknown"))
          |> MapSet.new()

        routing =
          %{
            fni_id: gateway_fni_id,
            gateway_type: gateway_type,
            required: required,
            arrived_via_flow_ids: arrived_via_flow_ids
          }
          |> put_complex_join_fields(gateway_type, data, flow_node_id, rows)

        Map.put(accumulator, flow_node_id, routing)
    end
  end

  defp resume_gateway_type(:inclusive_gateway), do: :inclusive_gateway
  defp resume_gateway_type(:complex_gateway), do: :complex_gateway
  defp resume_gateway_type(_flow_node_type), do: :parallel_gateway

  # Complex joins carry additional routing state so the PI can re-evaluate the
  # activation condition on resume: the FEEL `activationCondition`, the merged
  # branch payload (reconstructed from persisted GPA rows), and the `fired`
  # flag reset to false so a not-yet-fired join is re-evaluated.
  # `arrived_via_flow_ids` is a MapSet (opaque); passing routing maps that embed
  # it across these helpers is safe but trips Dialyzer's opacity check.
  @dialyzer {:no_opaque,
             [
               rebuild_single_join_routing: 4,
               ensure_active_join_gateways_routed: 2,
               put_complex_join_fields: 5
             ]}
  defp put_complex_join_fields(routing, :complex_gateway, data, flow_node_id, rows) do
    flow_node = find_flow_node(data, flow_node_id)

    merged_payload =
      rows
      |> Enum.sort_by(& &1.arrived_at, DateTime)
      |> Enum.reduce(%{}, fn row, accumulator ->
        Map.merge(accumulator, row.arrived_payload || %{})
      end)

    Map.merge(routing, %{
      activation_condition: complex_activation_condition(flow_node),
      merged_payload: merged_payload,
      fired: false
    })
  end

  defp put_complex_join_fields(routing, _gateway_type, _data, _flow_node_id, _rows), do: routing

  defp complex_activation_condition(%{type_data: %{activation_condition: condition}}),
    do: condition

  defp complex_activation_condition(_flow_node), do: nil

  defp ensure_active_join_gateways_routed(data, join_routing) do
    already_routed_flow_node_ids = Map.keys(join_routing) |> MapSet.new()

    data.flow_node_instance_states
    |> Enum.filter(fn {_fni_id, entry} ->
      entry.state in [:active, :waiting] and
        entry.flow_node_type in [:parallel_gateway, :inclusive_gateway, :complex_gateway] and
        not MapSet.member?(already_routed_flow_node_ids, entry.flow_node_id)
    end)
    |> Enum.reduce(join_routing, fn {fni_id, entry}, accumulator ->
      required = count_incoming_flows(data.process_model, entry.flow_node_id)
      gateway_type = resume_gateway_type(entry.flow_node_type)

      routing =
        %{
          fni_id: fni_id,
          gateway_type: gateway_type,
          required: required,
          arrived_via_flow_ids: MapSet.new()
        }
        |> put_complex_join_fields(gateway_type, data, entry.flow_node_id, [])

      Map.put(accumulator, entry.flow_node_id, routing)
    end)
  end

  defp count_incoming_flows(process_model, flow_node_id) do
    flow_node = Enum.find(process_model.flow_nodes, &(&1.id == flow_node_id))

    case flow_node do
      %{incoming: ids} when is_list(ids) and ids != [] ->
        length(ids)

      _ ->
        Enum.count(process_model.sequence_flows || [], &(&1.target_ref == flow_node_id))
    end
  end

  @doc "Iterates FNI states and reactivates waiting/active FNIs."
  @spec reactivate_fnis(struct(), pid(), map()) :: struct()
  def reactivate_fnis(data, process_instance_pid, grouped_arrivals \\ %{}) do
    join_fni_ids = join_fni_ids(data)

    {iteration_entries, other_entries} =
      Enum.split_with(data.flow_node_instance_states, fn {_id, entry} ->
        is_binary(Map.get(entry, :multi_instance_id))
      end)

    data =
      Enum.reduce(iteration_entries, data, fn {flow_node_instance_id, entry}, acc ->
        reactivate_iteration_fni(acc, flow_node_instance_id, entry, process_instance_pid)
      end)

    Enum.reduce(other_entries, data, fn {flow_node_instance_id, entry}, acc ->
      reactivate_single_fni(
        acc,
        flow_node_instance_id,
        entry,
        process_instance_pid,
        join_fni_ids,
        grouped_arrivals
      )
    end)
  end

  defp reactivate_single_fni(
         data,
         flow_node_instance_id,
         %{state: :active} = entry,
         process_instance_pid,
         join_fni_ids,
         grouped_arrivals
       ) do
    cond do
      mi_shell_fni?(data, flow_node_instance_id) ->
        reactivate_mi_shell_fni(data, flow_node_instance_id, entry, process_instance_pid)

      MapSet.member?(join_fni_ids, flow_node_instance_id) ->
        persisted_arrivals = Map.get(grouped_arrivals, flow_node_instance_id, [])

        reactivate_join_gateway_fni(
          data,
          flow_node_instance_id,
          entry,
          process_instance_pid,
          persisted_arrivals
        )

      has_existing_child?(entry) ->
        reactivate_child_spawner_fni(data, flow_node_instance_id, entry, process_instance_pid)

      true ->
        reactivate_active_fni(data, flow_node_instance_id, entry, process_instance_pid)
    end
  end

  defp reactivate_single_fni(
         data,
         flow_node_instance_id,
         %{state: :waiting} = entry,
         process_instance_pid,
         join_fni_ids,
         grouped_arrivals
       ) do
    cond do
      mi_shell_fni?(data, flow_node_instance_id) ->
        reactivate_mi_shell_fni(data, flow_node_instance_id, entry, process_instance_pid)

      MapSet.member?(join_fni_ids, flow_node_instance_id) ->
        persisted_arrivals = Map.get(grouped_arrivals, flow_node_instance_id, [])

        reactivate_join_gateway_fni(
          data,
          flow_node_instance_id,
          entry,
          process_instance_pid,
          persisted_arrivals
        )

      true ->
        reactivate_waiting_fni(data, flow_node_instance_id, entry, process_instance_pid)
    end
  end

  defp reactivate_single_fni(
         data,
         _flow_node_instance_id,
         _entry,
         _process_instance_pid,
         _join_fni_ids,
         _grouped_arrivals
       ) do
    data
  end

  defp join_fni_ids(data) do
    data.join_routing
    |> Map.values()
    |> Enum.map(& &1.fni_id)
    |> MapSet.new()
  end

  defp mi_shell_fni?(data, flow_node_instance_id) do
    Enum.any?(data.flow_node_instance_states, fn {_id, entry} ->
      Map.get(entry, :multi_instance_id) == flow_node_instance_id
    end)
  end

  defp reactivate_mi_shell_fni(data, flow_node_instance_id, entry, process_instance_pid) do
    flow_node = find_flow_node(data, entry.flow_node_id)

    if flow_node == nil do
      Logger.error(
        "Resume: flow node #{entry.flow_node_id} not found for MI shell FNI #{flow_node_instance_id}"
      )

      data
    else
      handler_context =
        build_handler_context(data, flow_node_instance_id, flow_node, process_instance_pid)

      handler_module =
        case HandlerDispatch.handler_for(flow_node) do
          {:ok, module} -> module
          _other -> FlowNodes.MultiInstanceBody
        end

      spawn_resume_task(
        data,
        flow_node_instance_id,
        entry,
        process_instance_pid,
        fn -> handler_module.handle_resume(flow_node, entry.token, handler_context) end,
        "MI/loop shell"
      )
    end
  end

  defp reactivate_iteration_fni(
         data,
         flow_node_instance_id,
         %{state: :waiting} = entry,
         process_instance_pid
       ) do
    reactivate_waiting_fni(data, flow_node_instance_id, entry, process_instance_pid)
  end

  defp reactivate_iteration_fni(
         data,
         flow_node_instance_id,
         %{state: :active} = entry,
         process_instance_pid
       ) do
    reactivate_active_iteration_fni(data, flow_node_instance_id, entry, process_instance_pid)
  end

  defp reactivate_iteration_fni(data, _flow_node_instance_id, _entry, _process_instance_pid),
    do: data

  defp reactivate_active_iteration_fni(data, flow_node_instance_id, entry, process_instance_pid) do
    flow_node = find_flow_node(data, entry.flow_node_id)

    with flow_node when not is_nil(flow_node) <- flow_node,
         {:ok, handler_module} <- HandlerDispatch.inner_handler_for(flow_node) do
      handler_context =
        build_handler_context(data, flow_node_instance_id, flow_node, process_instance_pid)

      handler_context = %{
        handler_context
        | loop: Map.get(entry, :loop_overlay),
          multi_instance_id: Map.get(entry, :multi_instance_id),
          iteration_index: Map.get(entry, :iteration_index)
      }

      spawn_resume_task(
        data,
        flow_node_instance_id,
        entry,
        process_instance_pid,
        fn ->
          BoundaryAwareHandler.wrap_enter(
            handler_module,
            flow_node,
            entry.token,
            handler_context
          )
        end,
        "MI iteration"
      )
    else
      _other ->
        Logger.error(
          "Resume: could not reattach active MI iteration FNI #{flow_node_instance_id}"
        )

        data
    end
  end

  defp reactivate_join_gateway_fni(
         data,
         flow_node_instance_id,
         entry,
         process_instance_pid,
         persisted_arrivals
       ) do
    flow_node = find_flow_node(data, entry.flow_node_id)

    if flow_node == nil do
      Logger.error(
        "Resume: flow node #{entry.flow_node_id} not found for join FNI #{flow_node_instance_id}"
      )

      data
    else
      handler_module =
        case entry.flow_node_type do
          :inclusive_gateway -> FlowNodes.InclusiveGateway
          :complex_gateway -> FlowNodes.ComplexGateway
          _ -> FlowNodes.ParallelGateway
        end

      handler_context =
        build_handler_context(data, flow_node_instance_id, flow_node, process_instance_pid)

      spawn_resume_task(
        data,
        flow_node_instance_id,
        entry,
        process_instance_pid,
        fn ->
          handler_module.handle_resume(flow_node, entry, handler_context, persisted_arrivals)
        end,
        "join gateway"
      )
    end
  end

  defp has_existing_child?(entry) do
    entry.flow_node_type in [:call_activity, :sub_process] and
      existing_child_id(entry) != nil
  end

  defp existing_child_id(entry) do
    type_properties = entry.type_properties || %{}

    Map.get(type_properties, "child_process_instance_id") ||
      Map.get(type_properties, :child_process_instance_id)
  end

  defp reactivate_child_spawner_fni(data, flow_node_instance_id, entry, process_instance_pid) do
    persist_waiting_state(flow_node_instance_id, entry)
    waiting_entry = %{entry | state: :waiting}

    case entry.flow_node_type do
      :call_activity ->
        reactivate_call_activity_fni(
          data,
          flow_node_instance_id,
          waiting_entry,
          process_instance_pid
        )

      :sub_process ->
        reactivate_sub_process_fni(
          data,
          flow_node_instance_id,
          waiting_entry,
          process_instance_pid
        )
    end
  end

  defp persist_waiting_state(flow_node_instance_id, entry) do
    type_properties = entry.type_properties || %{}

    child_process_instance_id =
      Map.get(type_properties, "child_process_instance_id") ||
        Map.get(type_properties, :child_process_instance_id)

    waiting_properties = %{
      async: true,
      child_process_instance_id: child_process_instance_id
    }

    case FniLifecycle.transition_to_waiting_by_id(flow_node_instance_id, waiting_properties) do
      :ok -> :ok
      {:error, :persistence_failed} -> :ok
    end
  end

  defp reactivate_active_fni(data, flow_node_instance_id, entry, process_instance_pid) do
    with flow_node when not is_nil(flow_node) <- find_flow_node(data, entry.flow_node_id),
         {:ok, handler_module} <- HandlerDispatch.handler_for(flow_node) do
      data =
        respawn_fni_task(
          data,
          flow_node_instance_id,
          entry,
          flow_node,
          handler_module,
          process_instance_pid
        )

      spawn_missing_boundary_fnis(
        data,
        flow_node,
        flow_node_instance_id,
        entry.token,
        process_instance_pid
      )
    else
      nil ->
        Logger.error(
          "Resume: flow node #{entry.flow_node_id} not found for FNI #{flow_node_instance_id}"
        )

        data

      {:error, {:unsupported_event_definition, unsupported_flow_node}} ->
        Logger.error(
          "Resume: unsupported event definition for FNI #{flow_node_instance_id}: #{unsupported_flow_node.id}"
        )

        data

      {:error, :unsupported_element} ->
        Logger.error(
          "Resume: unsupported element for FNI #{flow_node_instance_id}: #{entry.flow_node_type}"
        )

        data
    end
  end

  defp respawn_fni_task(
         data,
         flow_node_instance_id,
         entry,
         flow_node,
         handler_module,
         process_instance_pid
       ) do
    handler_context =
      build_handler_context(data, flow_node_instance_id, flow_node, process_instance_pid)
      |> maybe_inject_boundary_host(entry)

    case Task.Supervisor.start_child(data.task_supervisor, fn ->
           result =
             BoundaryAwareHandler.wrap_enter(
               handler_module,
               flow_node,
               entry.token,
               handler_context
             )

           dispatch_handler_result(process_instance_pid, flow_node_instance_id, result)
         end) do
      {:ok, task_pid} ->
        Process.monitor(task_pid)
        put_in(data.flow_node_instance_states[flow_node_instance_id], %{entry | pid: task_pid})

      {:error, reason} ->
        Logger.error(
          "Resume: failed to re-dispatch FNI #{flow_node_instance_id}: #{inspect(reason)}"
        )

        data
    end
  end

  defp reactivate_waiting_fni(data, flow_node_instance_id, entry, process_instance_pid) do
    case entry.flow_node_type do
      :call_activity ->
        reactivate_call_activity_fni(data, flow_node_instance_id, entry, process_instance_pid)

      :sub_process ->
        reactivate_sub_process_fni(data, flow_node_instance_id, entry, process_instance_pid)

      :intermediate_catch_event ->
        reactivate_waiting_catch_fni(data, flow_node_instance_id, entry, process_instance_pid)

      :boundary_event ->
        reactivate_waiting_boundary_fni(data, flow_node_instance_id, entry, process_instance_pid)

      :start_event ->
        reactivate_timer_start_fni(data, flow_node_instance_id, entry, process_instance_pid)

      :receive_task ->
        reactivate_receive_task_fni(data, flow_node_instance_id, entry, process_instance_pid)

      _ ->
        reactivate_async_fni(data, flow_node_instance_id, entry)
    end
  end

  defp reactivate_waiting_catch_fni(data, flow_node_instance_id, entry, process_instance_pid) do
    case entry.event_type do
      "timer" ->
        reactivate_timer_catch_fni(data, flow_node_instance_id, entry, process_instance_pid)

      "message" ->
        reactivate_message_catch_fni(data, flow_node_instance_id, entry, process_instance_pid)

      "signal" ->
        reactivate_signal_catch_fni(data, flow_node_instance_id, entry, process_instance_pid)

      "conditional" ->
        reactivate_conditional_catch_fni(data, flow_node_instance_id, entry, process_instance_pid)

      _ ->
        reactivate_async_fni(data, flow_node_instance_id, entry)
    end
  end

  defp reactivate_waiting_boundary_fni(data, flow_node_instance_id, entry, process_instance_pid) do
    case entry.event_type do
      "timer" ->
        reactivate_timer_boundary_fni(data, flow_node_instance_id, entry, process_instance_pid)

      "message" ->
        reactivate_message_boundary_fni(data, flow_node_instance_id, entry, process_instance_pid)

      "signal" ->
        reactivate_signal_boundary_fni(data, flow_node_instance_id, entry, process_instance_pid)

      "conditional" ->
        reactivate_conditional_boundary_fni(
          data,
          flow_node_instance_id,
          entry,
          process_instance_pid
        )

      _ ->
        reactivate_async_fni(data, flow_node_instance_id, entry)
    end
  end

  defp reactivate_timer_catch_fni(data, flow_node_instance_id, entry, process_instance_pid) do
    flow_node = find_flow_node(data, entry.flow_node_id)

    handler_context =
      build_handler_context(data, flow_node_instance_id, flow_node, process_instance_pid)

    spawn_resume_task(
      data,
      flow_node_instance_id,
      entry,
      process_instance_pid,
      fn -> FlowNodes.TimerCatchEvent.handle_resume(flow_node, entry, handler_context) end,
      "timer catch"
    )
  end

  defp reactivate_timer_start_fni(data, flow_node_instance_id, entry, process_instance_pid) do
    flow_node = find_flow_node(data, entry.flow_node_id)

    handler_context =
      build_handler_context(data, flow_node_instance_id, flow_node, process_instance_pid)

    spawn_resume_task(
      data,
      flow_node_instance_id,
      entry,
      process_instance_pid,
      fn -> FlowNodes.TimerStartEvent.handle_resume(flow_node, entry, handler_context) end,
      "timer start"
    )
  end

  defp reactivate_timer_boundary_fni(data, flow_node_instance_id, entry, process_instance_pid) do
    flow_node = find_flow_node(data, entry.flow_node_id)

    handler_context =
      build_handler_context(data, flow_node_instance_id, flow_node, process_instance_pid)
      |> Map.put(
        :host_flow_node_instance_id,
        Map.get(entry.type_properties, :host_flow_node_instance_id) ||
          Map.get(entry.type_properties, "host_flow_node_instance_id")
      )

    spawn_resume_task(
      data,
      flow_node_instance_id,
      entry,
      process_instance_pid,
      fn -> FlowNodes.TimerBoundaryEvent.handle_resume(flow_node, entry, handler_context) end,
      "timer boundary"
    )
  end

  defp reactivate_message_catch_fni(data, flow_node_instance_id, entry, process_instance_pid) do
    flow_node = find_flow_node(data, entry.flow_node_id)

    handler_context =
      build_handler_context(data, flow_node_instance_id, flow_node, process_instance_pid)

    spawn_resume_task(
      data,
      flow_node_instance_id,
      entry,
      process_instance_pid,
      fn -> FlowNodes.MessageCatchEvent.handle_resume(flow_node, entry, handler_context) end,
      "message catch"
    )
  end

  defp reactivate_message_boundary_fni(data, flow_node_instance_id, entry, process_instance_pid) do
    flow_node = find_flow_node(data, entry.flow_node_id)

    handler_context =
      build_handler_context(data, flow_node_instance_id, flow_node, process_instance_pid)
      |> Map.put(
        :host_flow_node_instance_id,
        Map.get(entry.type_properties, :host_flow_node_instance_id) ||
          Map.get(entry.type_properties, "host_flow_node_instance_id")
      )

    spawn_resume_task(
      data,
      flow_node_instance_id,
      entry,
      process_instance_pid,
      fn -> FlowNodes.MessageBoundaryEvent.handle_resume(flow_node, entry, handler_context) end,
      "message boundary"
    )
  end

  defp reactivate_signal_catch_fni(data, flow_node_instance_id, entry, process_instance_pid) do
    flow_node = find_flow_node(data, entry.flow_node_id)

    handler_context =
      build_handler_context(data, flow_node_instance_id, flow_node, process_instance_pid)

    spawn_resume_task(
      data,
      flow_node_instance_id,
      entry,
      process_instance_pid,
      fn -> FlowNodes.SignalCatchEvent.handle_resume(flow_node, entry, handler_context) end,
      "signal catch"
    )
  end

  defp reactivate_signal_boundary_fni(data, flow_node_instance_id, entry, process_instance_pid) do
    flow_node = find_flow_node(data, entry.flow_node_id)

    handler_context =
      build_handler_context(data, flow_node_instance_id, flow_node, process_instance_pid)
      |> Map.put(
        :host_flow_node_instance_id,
        Map.get(entry.type_properties, :host_flow_node_instance_id) ||
          Map.get(entry.type_properties, "host_flow_node_instance_id")
      )

    spawn_resume_task(
      data,
      flow_node_instance_id,
      entry,
      process_instance_pid,
      fn -> FlowNodes.SignalBoundaryEvent.handle_resume(flow_node, entry, handler_context) end,
      "signal boundary"
    )
  end

  defp reactivate_conditional_catch_fni(data, flow_node_instance_id, entry, process_instance_pid) do
    flow_node = find_flow_node(data, entry.flow_node_id)

    handler_context =
      build_handler_context(data, flow_node_instance_id, flow_node, process_instance_pid)

    spawn_resume_task(
      data,
      flow_node_instance_id,
      entry,
      process_instance_pid,
      fn ->
        FlowNodes.ConditionalCatchEvent.handle_resume(flow_node, entry.token, handler_context)
      end,
      "conditional catch"
    )
  end

  defp reactivate_conditional_boundary_fni(
         data,
         flow_node_instance_id,
         entry,
         process_instance_pid
       ) do
    flow_node = find_flow_node(data, entry.flow_node_id)

    handler_context =
      build_handler_context(data, flow_node_instance_id, flow_node, process_instance_pid)
      |> Map.put(
        :host_flow_node_instance_id,
        Map.get(entry.type_properties, :host_flow_node_instance_id) ||
          Map.get(entry.type_properties, "host_flow_node_instance_id")
      )

    spawn_resume_task(
      data,
      flow_node_instance_id,
      entry,
      process_instance_pid,
      fn ->
        FlowNodes.ConditionalBoundaryEvent.handle_resume(
          flow_node,
          entry.type_properties,
          handler_context
        )
      end,
      "conditional boundary"
    )
  end

  defp reactivate_receive_task_fni(data, flow_node_instance_id, entry, process_instance_pid) do
    flow_node = find_flow_node(data, entry.flow_node_id)

    handler_context =
      build_handler_context(data, flow_node_instance_id, flow_node, process_instance_pid)

    spawn_resume_task(
      data,
      flow_node_instance_id,
      entry,
      process_instance_pid,
      fn -> FlowNodes.ReceiveTask.handle_resume(flow_node, entry, handler_context) end,
      "receive task"
    )
  end

  defp reactivate_async_fni(data, flow_node_instance_id, entry) do
    type_properties = entry.type_properties || %{}
    is_async = Map.get(type_properties, :async, false) || Map.get(type_properties, "async", false)

    if is_async do
      {:ok, _} =
        Registry.register(BfwEngine.Execution.Registry, {:fni, flow_node_instance_id}, :async)

      EngineEventBus.publish(%Event.PluginAsyncFlowNodeRehydrated{
        flow_node_instance_id: flow_node_instance_id,
        process_instance_id: data.process_instance_id,
        lane_name:
          resolve_lane_name(data.process_model, find_flow_node(data, entry.flow_node_id)),
        occurred_at: DateTime.utc_now()
      })
    end

    data
  end

  defp reactivate_call_activity_fni(data, flow_node_instance_id, entry, process_instance_pid) do
    flow_node = find_flow_node(data, entry.flow_node_id)

    handler_context =
      build_handler_context(data, flow_node_instance_id, flow_node, process_instance_pid)

    type_properties = entry.type_properties || %{}

    child_process_instance_id =
      Map.get(type_properties, "child_process_instance_id") ||
        Map.get(type_properties, :child_process_instance_id)

    spawn_resume_task(
      data,
      flow_node_instance_id,
      entry,
      process_instance_pid,
      fn ->
        FlowNodes.CallActivity.handle_resume(
          flow_node,
          entry,
          handler_context,
          child_process_instance_id
        )
      end,
      "CA"
    )
  end

  defp reactivate_sub_process_fni(data, flow_node_instance_id, entry, process_instance_pid) do
    flow_node = find_flow_node(data, entry.flow_node_id)

    handler_context =
      build_handler_context(data, flow_node_instance_id, flow_node, process_instance_pid)

    type_properties = entry.type_properties || %{}

    child_process_instance_id =
      Map.get(type_properties, "child_process_instance_id") ||
        Map.get(type_properties, :child_process_instance_id)

    # An Event Subprocess shell FNI (`triggered_by_event: true`) uses the ESP
    # handler for reattach (ESP-D10); an embedded subprocess uses SubProcess.
    resume_module = subprocess_resume_module(flow_node)

    spawn_resume_task(
      data,
      flow_node_instance_id,
      entry,
      process_instance_pid,
      fn ->
        resume_module.handle_resume(
          flow_node,
          entry,
          handler_context,
          child_process_instance_id
        )
      end,
      "SP"
    )
  end

  defp subprocess_resume_module(%FlowNode{
         type: :sub_process,
         type_data: %FlowNodeData.SubProcess{triggered_by_event: true}
       }),
       do: FlowNodes.EventSubprocess

  defp subprocess_resume_module(%FlowNode{
         type: :sub_process,
         type_data: %FlowNodeData.SubProcess{is_transaction: true}
       }),
       do: FlowNodes.TransactionSubProcess

  defp subprocess_resume_module(%FlowNode{
         type: :sub_process,
         type_data: %FlowNodeData.SubProcess{is_ad_hoc: true}
       }),
       do: FlowNodes.AdHocSubProcess

  defp subprocess_resume_module(_flow_node), do: FlowNodes.SubProcess

  defp spawn_resume_task(
         data,
         flow_node_instance_id,
         entry,
         process_instance_pid,
         resume_function,
         label
       ) do
    case Task.Supervisor.start_child(data.task_supervisor, fn ->
           result = resume_function.()
           dispatch_handler_result(process_instance_pid, flow_node_instance_id, result)
         end) do
      {:ok, task_pid} ->
        Process.monitor(task_pid)
        put_in(data.flow_node_instance_states[flow_node_instance_id], %{entry | pid: task_pid})

      {:error, reason} ->
        Logger.error(
          "Resume: failed to re-dispatch #{label} FNI #{flow_node_instance_id}: #{inspect(reason)}"
        )

        data
    end
  end

  defp maybe_inject_boundary_host(context, %{
         flow_node_type: :boundary_event,
         type_properties: props
       })
       when is_map(props) do
    host_id =
      Map.get(props, :host_flow_node_instance_id) ||
        Map.get(props, "host_flow_node_instance_id")

    if host_id,
      do: %{context | host_flow_node_instance_id: host_id},
      else: context
  end

  defp maybe_inject_boundary_host(context, _entry), do: context

  # -------------------------------------------------------------------
  # Boundary re-spawning on resume / retry
  # -------------------------------------------------------------------

  defp spawn_missing_boundary_fnis(data, flow_node, host_fni_id, token, process_instance_pid) do
    boundary_nodes = BoundaryOrchestrator.resolve_subscription_boundaries(data, flow_node)

    if boundary_nodes == [] do
      data
    else
      existing_boundary_flow_node_ids =
        data.flow_node_instance_states
        |> Enum.filter(fn {_id, entry} ->
          entry.flow_node_type == :boundary_event and
            entry.state in [:active, :waiting] and
            boundary_fni_for_host?(entry, host_fni_id)
        end)
        |> Enum.map(fn {_id, entry} -> entry.flow_node_id end)
        |> MapSet.new()

      boundary_nodes
      |> Enum.reject(fn boundary_node ->
        MapSet.member?(existing_boundary_flow_node_ids, boundary_node.id)
      end)
      |> Enum.reduce(data, fn boundary_node, accumulator ->
        dispatch_boundary_fni_on_resume(
          accumulator,
          boundary_node,
          host_fni_id,
          token,
          process_instance_pid
        )
      end)
    end
  end

  defp dispatch_boundary_fni_on_resume(
         data,
         boundary_node,
         host_fni_id,
         token,
         process_instance_pid
       ) do
    boundary_fni_id = generate_id()
    lane_name = resolve_lane_name(data.process_model, boundary_node)

    case persist_boundary_fni(data, boundary_fni_id, boundary_node, token, lane_name, host_fni_id) do
      {:ok, _} ->
        emit_boundary_fni_started(data, boundary_fni_id, boundary_node, lane_name)

        start_boundary_handler(
          data,
          boundary_fni_id,
          boundary_node,
          token,
          host_fni_id,
          process_instance_pid
        )

      {:error, _reason} ->
        Logger.error(
          "Resume: failed to persist boundary FNI #{boundary_fni_id} for host #{host_fni_id}"
        )

        data
    end
  end

  defp persist_boundary_fni(data, boundary_fni_id, boundary_node, token, lane_name, host_fni_id) do
    adapter = PersistenceAdapter.adapter()

    PersistenceRetry.with_retry(
      fn ->
        adapter.create_flow_node_instance(%{
          id: boundary_fni_id,
          process_instance_id: data.process_instance_id,
          flow_node_id: boundary_node.id,
          flow_node_type: Atom.to_string(boundary_node.type),
          event_type: extract_event_type(boundary_node),
          lane_name: lane_name,
          state: "active",
          started_at: DateTime.utc_now(),
          input_token: token.payload,
          previous_flow_node_instance_ids: [host_fni_id]
        })
      end,
      "FNI boundary create #{boundary_fni_id}"
    )
  end

  defp emit_boundary_fni_started(data, boundary_fni_id, boundary_node, lane_name) do
    EngineEventBus.publish(%Event.FlowNodeInstanceStarted{
      flow_node_instance_id: boundary_fni_id,
      process_instance_id: data.process_instance_id,
      root_process_instance_id: data.root_process_instance_id,
      flow_node_id: boundary_node.id,
      flow_node_type: boundary_node.type,
      event_type: extract_event_type(boundary_node),
      lane_name: lane_name,
      occurred_at: DateTime.utc_now()
    })
  end

  defp start_boundary_handler(
         data,
         boundary_fni_id,
         boundary_node,
         token,
         host_fni_id,
         process_instance_pid
       ) do
    case HandlerDispatch.handler_for(boundary_node) do
      {:ok, handler_module} ->
        spawn_boundary_handler_task(
          data,
          boundary_fni_id,
          boundary_node,
          token,
          host_fni_id,
          handler_module,
          process_instance_pid
        )

      {:error, reason} ->
        Logger.error(
          "Resume: unsupported boundary handler for #{boundary_node.id}: #{inspect(reason)}"
        )

        data
    end
  end

  defp spawn_boundary_handler_task(
         data,
         boundary_fni_id,
         boundary_node,
         token,
         host_fni_id,
         handler_module,
         process_instance_pid
       ) do
    handler_context =
      build_handler_context(data, boundary_fni_id, boundary_node, process_instance_pid)
      |> Map.put(:host_flow_node_instance_id, host_fni_id)

    case Task.Supervisor.start_child(data.task_supervisor, fn ->
           result = handler_module.handle_enter(boundary_node, token, handler_context)
           dispatch_handler_result(process_instance_pid, boundary_fni_id, result)
         end) do
      {:ok, task_pid} ->
        Process.monitor(task_pid)

        entry = %{
          pid: task_pid,
          flow_node_id: boundary_node.id,
          flow_node_type: boundary_node.type,
          event_type: extract_event_type(boundary_node),
          state: :active,
          token: token,
          previous_flow_node_instance_ids: [host_fni_id],
          type_properties: %{host_flow_node_instance_id: host_fni_id},
          next_flow_node_ids: []
        }

        put_in(data.flow_node_instance_states[boundary_fni_id], entry)

      {:error, reason} ->
        Logger.error(
          "Resume: failed to start boundary FNI #{boundary_fni_id}: #{inspect(reason)}"
        )

        data
    end
  end
end

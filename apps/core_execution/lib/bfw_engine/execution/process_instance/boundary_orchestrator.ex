defmodule BfwEngine.Execution.ProcessInstance.BoundaryOrchestrator do
  @moduledoc """
  Boundary event orchestration for Process Instance runtime.

  Handles boundary FNI lifecycle (finish, cancel siblings/host), subscription
  boundary resolution, and dispatch-target computation. Does not spawn FNIs or
  call `dispatch_flow_node_instance` — those remain in `ProcessInstance`.
  """

  require Logger

  alias BfwEngine.Execution.ProcessInstance.FlowNodeLookup
  alias BfwEngine.Execution.ProcessInstance.HandlerDispatch, as: InstanceHandlerDispatch
  alias BfwEngine.Execution.ProcessInstance.LaneResolution
  alias BfwEngine.Execution.UuidV7

  alias BfwEngine.BPMN.Model.EventDefinition
  alias BfwEngine.BPMN.Model.FlowNode
  alias BfwEngine.BPMN.Model.FlowNodeData
  alias BfwEngine.Events.EngineEventBus
  alias BfwEngine.Execution.FniLifecycle
  alias BfwEngine.Execution.Persistence, as: PersistenceAdapter
  alias BfwEngine.Execution.PersistenceRetry
  alias BfwEngine.Execution.TaskInboxEvents
  alias BfwEngine.Types.Event
  alias BfwEngine.Types.Token

  @fni_state_finished "finished"

  @type dispatch_target :: {FlowNode.t(), Token.t(), [String.t()]}

  @doc """
  Handles a boundary catch result from a subscription-model or activity-model
  boundary handler.

  Returns `{updated_data, host_fni_id, cancel_activity, dispatch_targets}`.
  The caller must invoke `handle_fni_interrupted/3` when `cancel_activity` is
  true, then reduce over `dispatch_targets` with `dispatch_flow_node_instance/4`.

  `triggerer_fni_id` is the FNI ID of the throwing event (message/signal/escalation
  thrower) that triggered this boundary catch, or `nil` when unknown.
  """
  @spec handle_boundary_catch(
          struct(),
          String.t(),
          String.t(),
          term(),
          boolean(),
          String.t() | nil
        ) :: {struct(), String.t(), boolean(), [dispatch_target()]}
  def handle_boundary_catch(
        data,
        flow_node_instance_id,
        boundary_node_id,
        payload,
        cancel_activity,
        triggerer_fni_id
      ) do
    host_fni_id = resolve_host_fni_id(data, flow_node_instance_id)
    is_subscription_model = host_fni_id != flow_node_instance_id

    {data, boundary_fni_id} =
      if is_subscription_model do
        {finish_boundary_fni(data, flow_node_instance_id, triggerer_fni_id),
         flow_node_instance_id}
      else
        case find_prespawned_boundary_fni_id(data, boundary_node_id) do
          nil ->
            Logger.warning(
              "No pre-spawned boundary FNI found for #{boundary_node_id}; " <>
                "this should not happen with correct pre-spawning"
            )

            create_and_finish_error_boundary_fni(data, boundary_node_id, host_fni_id, payload)

          prespawned_fni_id ->
            {finish_boundary_fni(data, prespawned_fni_id, triggerer_fni_id), prespawned_fni_id}
        end
      end

    data =
      if cancel_activity do
        cancel_sibling_boundary_fnis(data, host_fni_id, boundary_fni_id)
      else
        data
      end

    boundary_node = FlowNodeLookup.find_flow_node(data, boundary_node_id)
    new_token = build_boundary_token(data, boundary_fni_id, payload)

    dispatch_targets =
      build_dispatch_targets(data, boundary_node, new_token, boundary_fni_id)

    {data, host_fni_id, cancel_activity, dispatch_targets}
  end

  @doc """
  Handles an intermediate cycle fire from a non-interrupting boundary.

  Like `handle_boundary_catch/6`, but does not finish the boundary FNI.
  """
  @spec handle_boundary_cycle_fire(
          struct(),
          String.t(),
          String.t(),
          term(),
          boolean(),
          String.t() | nil
        ) :: {struct(), String.t(), boolean(), [dispatch_target()]}
  def handle_boundary_cycle_fire(
        data,
        flow_node_instance_id,
        boundary_node_id,
        payload,
        cancel_activity,
        _triggerer_fni_id
      ) do
    host_fni_id = resolve_host_fni_id(data, flow_node_instance_id)

    data =
      if cancel_activity do
        cancel_sibling_boundary_fnis(data, host_fni_id, flow_node_instance_id)
      else
        data
      end

    boundary_node = FlowNodeLookup.find_flow_node(data, boundary_node_id)
    new_token = build_boundary_token(data, flow_node_instance_id, payload)

    dispatch_targets =
      build_dispatch_targets(data, boundary_node, new_token, flow_node_instance_id)

    {data, host_fni_id, cancel_activity, dispatch_targets}
  end

  @doc """
  Resolves all boundary nodes attached to a host flow node for pre-spawning.
  """
  @spec resolve_subscription_boundaries(struct(), FlowNode.t()) :: [FlowNode.t()]
  def resolve_subscription_boundaries(data, flow_node) do
    boundary_refs = flow_node.boundary_event_refs

    if boundary_refs == [] do
      []
    else
      node_index = Map.new(data.process_model.flow_nodes, &{&1.id, &1})

      boundary_refs
      |> Enum.map(&Map.get(node_index, &1))
      |> Enum.reject(fn node ->
        is_nil(node) or compensation_boundary?(node) or cancel_boundary?(node)
      end)
    end
  end

  defp compensation_boundary?(%FlowNode{
         type: :boundary_event,
         type_data: %FlowNodeData.BoundaryEvent{
           event_definition: %EventDefinition.Compensation{}
         }
       }),
       do: true

  defp compensation_boundary?(_), do: false

  defp cancel_boundary?(%FlowNode{
         type: :boundary_event,
         type_data: %FlowNodeData.BoundaryEvent{
           event_definition: %EventDefinition.Cancel{}
         }
       }),
       do: true

  defp cancel_boundary?(_), do: false

  @doc "Interrupts all active/waiting boundary FNIs attached to the given host FNI."
  @spec cancel_boundary_fnis_for_host(struct(), String.t()) :: struct()
  def cancel_boundary_fnis_for_host(data, host_flow_node_instance_id) do
    data.flow_node_instance_states
    |> Enum.filter(fn {_id, entry} ->
      entry.state in [:active, :waiting] and
        boundary_fni_for_host?(entry, host_flow_node_instance_id)
    end)
    |> Enum.reduce(data, fn {boundary_fni_id, entry}, accumulator ->
      if entry.pid != nil, do: Process.exit(entry.pid, :kill)

      flow_node = FlowNodeLookup.find_flow_node(accumulator, entry.flow_node_id)
      InstanceHandlerDispatch.invoke_optional_callback(flow_node, :handle_aborted, [entry])

      _persist_result =
        FniLifecycle.transition_to_interrupted(
          boundary_fni_id,
          accumulator.process_instance_id,
          "host_completed",
          flow_node,
          Map.get(entry, :type_properties, %{}),
          LaneResolution.resolve_lane_name(accumulator.process_model, flow_node),
          accumulator.root_process_instance_id,
          multi_instance_id: Map.get(entry, :multi_instance_id),
          iteration_index: Map.get(entry, :iteration_index),
          was_waiting: entry.state == :waiting
        )

      accumulator =
        %{
          accumulator
          | conditional_waiters: Map.delete(accumulator.conditional_waiters, boundary_fni_id)
        }

      put_in(accumulator.flow_node_instance_states[boundary_fni_id], %{
        entry
        | state: :interrupted,
          pid: nil
      })
    end)
  end

  @doc "Interrupts sibling boundary FNIs when one boundary fires on the same host."
  @spec cancel_sibling_boundary_fnis(struct(), String.t(), String.t()) :: struct()
  def cancel_sibling_boundary_fnis(data, host_fni_id, triggering_boundary_fni_id) do
    data.flow_node_instance_states
    |> Enum.filter(fn {id, entry} ->
      id != triggering_boundary_fni_id and
        entry.state in [:active, :waiting] and
        boundary_fni_for_host?(entry, host_fni_id)
    end)
    |> Enum.reduce(data, fn {sibling_fni_id, entry}, accumulator ->
      if entry.pid != nil, do: Process.exit(entry.pid, :kill)

      flow_node = FlowNodeLookup.find_flow_node(accumulator, entry.flow_node_id)
      InstanceHandlerDispatch.invoke_optional_callback(flow_node, :handle_aborted, [entry])

      _persist_result =
        FniLifecycle.transition_to_interrupted(
          sibling_fni_id,
          accumulator.process_instance_id,
          "sibling_boundary_interrupted",
          flow_node,
          Map.get(entry, :type_properties, %{}),
          LaneResolution.resolve_lane_name(accumulator.process_model, flow_node),
          accumulator.root_process_instance_id,
          multi_instance_id: Map.get(entry, :multi_instance_id),
          iteration_index: Map.get(entry, :iteration_index),
          was_waiting: entry.state == :waiting
        )

      accumulator =
        %{
          accumulator
          | conditional_waiters: Map.delete(accumulator.conditional_waiters, sibling_fni_id)
        }

      put_in(accumulator.flow_node_instance_states[sibling_fni_id], %{
        entry
        | state: :interrupted,
          pid: nil
      })
    end)
  end

  @doc "Returns whether any boundary FNIs are attached to the given host FNI."
  @spec has_boundary_fnis?(struct(), String.t()) :: boolean()
  def has_boundary_fnis?(data, host_fni_id) do
    Enum.any?(data.flow_node_instance_states, fn {_id, entry} ->
      boundary_fni_for_host?(entry, host_fni_id)
    end)
  end

  defp finish_boundary_fni(data, boundary_fni_id, triggerer_fni_id) do
    case Map.get(data.flow_node_instance_states, boundary_fni_id) do
      nil ->
        data

      entry ->
        if entry.pid != nil, do: Process.exit(entry.pid, :kill)

        flow_node = FlowNodeLookup.find_flow_node(data, entry.flow_node_id)
        persist_result = persist_boundary_fni_finished(boundary_fni_id, triggerer_fni_id)

        if not match?({:error, _reason}, persist_result) do
          publish_finished_boundary(data, boundary_fni_id, triggerer_fni_id, entry, flow_node)
        end

        put_in(data.flow_node_instance_states[boundary_fni_id], %{
          entry
          | state: :finished,
            pid: nil
        })
    end
  end

  defp publish_finished_boundary(data, boundary_fni_id, triggerer_fni_id, entry, flow_node) do
    TaskInboxEvents.publish_flow_node_instance_finished(
      %Event.FlowNodeInstanceFinished{
        flow_node_instance_id: boundary_fni_id,
        process_instance_id: data.process_instance_id,
        root_process_instance_id: data.root_process_instance_id,
        flow_node_id: flow_node.id,
        flow_node_type: flow_node.type,
        event_type: FlowNodeLookup.extract_event_type(flow_node),
        lane_name: LaneResolution.resolve_lane_name(data.process_model, flow_node),
        terminal_state: :finished,
        triggerer_flow_node_instance_id: triggerer_fni_id,
        type_properties: %{},
        multi_instance_id: Map.get(entry, :multi_instance_id),
        iteration_index: Map.get(entry, :iteration_index),
        occurred_at: DateTime.utc_now()
      },
      flow_node
    )

    :telemetry.execute(
      [:bfw_engine, :flow_node_instance, :state_change],
      %{system_time: System.system_time()},
      %{
        flow_node_instance_id: boundary_fni_id,
        process_instance_id: data.process_instance_id,
        flow_node_type: flow_node.type,
        terminal_state: :finished
      }
    )
  end

  defp create_and_finish_error_boundary_fni(data, boundary_node_id, host_fni_id, payload) do
    boundary_node = FlowNodeLookup.find_flow_node(data, boundary_node_id)
    boundary_fni_id = UuidV7.generate()
    lane_name = LaneResolution.resolve_lane_name(data.process_model, boundary_node)
    now = DateTime.utc_now()
    event_type = FlowNodeLookup.extract_event_type(boundary_node)

    type_properties = %{"boundary_fired" => true, "error_info" => payload}

    persist_error_boundary_fni(
      data,
      boundary_fni_id,
      boundary_node,
      host_fni_id,
      lane_name,
      type_properties,
      now
    )

    EngineEventBus.publish(%Event.FlowNodeInstanceStarted{
      flow_node_instance_id: boundary_fni_id,
      process_instance_id: data.process_instance_id,
      root_process_instance_id: data.root_process_instance_id,
      flow_node_id: boundary_node.id,
      flow_node_type: boundary_node.type,
      event_type: event_type,
      lane_name: lane_name,
      occurred_at: now
    })

    :telemetry.execute(
      [:bfw_engine, :flow_node_instance, :started],
      %{system_time: System.system_time()},
      %{
        flow_node_instance_id: boundary_fni_id,
        flow_node_type: boundary_node.type,
        previous_flow_node_instance_ids: [host_fni_id]
      }
    )

    host_entry = Map.get(data.flow_node_instance_states, host_fni_id)

    TaskInboxEvents.publish_flow_node_instance_finished(
      %Event.FlowNodeInstanceFinished{
        flow_node_instance_id: boundary_fni_id,
        process_instance_id: data.process_instance_id,
        root_process_instance_id: data.root_process_instance_id,
        flow_node_id: boundary_node.id,
        flow_node_type: boundary_node.type,
        event_type: event_type,
        lane_name: lane_name,
        terminal_state: :finished,
        triggerer_flow_node_instance_id: nil,
        type_properties: type_properties,
        multi_instance_id: host_entry && Map.get(host_entry, :multi_instance_id),
        iteration_index: host_entry && Map.get(host_entry, :iteration_index),
        occurred_at: now
      },
      boundary_node
    )

    :telemetry.execute(
      [:bfw_engine, :flow_node_instance, :state_change],
      %{system_time: System.system_time()},
      %{
        flow_node_instance_id: boundary_fni_id,
        process_instance_id: data.process_instance_id,
        flow_node_type: boundary_node.type,
        terminal_state: :finished
      }
    )

    entry = %{
      pid: nil,
      flow_node_id: boundary_node.id,
      flow_node_type: boundary_node.type,
      event_type: event_type,
      state: :finished,
      token: nil,
      previous_flow_node_instance_ids: [host_fni_id],
      type_properties: %{host_flow_node_instance_id: host_fni_id},
      next_flow_node_ids: []
    }

    {put_in(data.flow_node_instance_states[boundary_fni_id], entry), boundary_fni_id}
  end

  defp persist_error_boundary_fni(
         data,
         boundary_fni_id,
         boundary_node,
         host_fni_id,
         lane_name,
         type_properties,
         now
       ) do
    adapter = PersistenceAdapter.adapter()

    attributes = %{
      id: boundary_fni_id,
      process_instance_id: data.process_instance_id,
      flow_node_id: boundary_node.id,
      flow_node_type: Atom.to_string(boundary_node.type),
      event_type: FlowNodeLookup.extract_event_type(boundary_node),
      lane_name: lane_name,
      state: @fni_state_finished,
      started_at: now,
      finished_at: now,
      input_token: nil,
      output_token: nil,
      type_properties: type_properties,
      previous_flow_node_instance_ids: [host_fni_id]
    }

    log_fni_persist_error(
      PersistenceRetry.with_retry(
        fn -> adapter.create_flow_node_instance(attributes) end,
        "Error boundary FNI create #{boundary_fni_id}"
      ),
      "Error boundary FNI create",
      boundary_fni_id
    )
  end

  defp persist_boundary_fni_finished(flow_node_instance_id, triggerer_fni_id) do
    adapter = PersistenceAdapter.adapter()

    changes = %{
      state: @fni_state_finished,
      finished_at: DateTime.utc_now(),
      output_token: nil,
      type_properties: %{"boundary_fired" => true}
    }

    changes =
      if triggerer_fni_id do
        Map.put(changes, :triggerer_flow_node_instance_id, triggerer_fni_id)
      else
        changes
      end

    persist_result =
      PersistenceRetry.with_retry(
        fn ->
          adapter.update_flow_node_instance(flow_node_instance_id, :update_finished, changes)
        end,
        "Boundary FNI finished #{flow_node_instance_id}"
      )

    log_fni_persist_error(persist_result, "Boundary FNI finished", flow_node_instance_id)
    persist_result
  end

  defp build_boundary_token(data, flow_node_instance_id, payload) do
    %Token{
      id: UuidV7.generate(),
      process_instance_id: data.process_instance_id,
      payload: payload,
      originating_flow_node_instance_id: flow_node_instance_id,
      created_at: DateTime.utc_now()
    }
  end

  defp build_dispatch_targets(data, boundary_node, token, source_fni_id) do
    node_index = Map.new(data.process_model.flow_nodes, &{&1.id, &1})
    outgoing_flows = fetch_outgoing_flows_for_node(boundary_node, data.process_model)

    outgoing_flows
    |> Enum.map(&Map.get(node_index, &1.target_ref))
    |> Enum.reject(&is_nil/1)
    |> Enum.map(fn target_node -> {target_node, token, [source_fni_id]} end)
  end

  defp fetch_outgoing_flows_for_node(node, process_model) do
    case node.outgoing do
      outgoing_ids when is_list(outgoing_ids) and outgoing_ids != [] ->
        flow_index = Map.new(process_model.sequence_flows, &{&1.id, &1})

        outgoing_ids
        |> Enum.map(&Map.get(flow_index, &1))
        |> Enum.reject(&is_nil/1)

      _ ->
        Enum.filter(process_model.sequence_flows, &(&1.source_ref == node.id))
    end
  end

  defp find_prespawned_boundary_fni_id(data, boundary_node_id) do
    Enum.find_value(data.flow_node_instance_states, fn {fni_id, entry} ->
      if entry.flow_node_id == boundary_node_id and entry.state in [:active, :waiting] do
        fni_id
      end
    end)
  end

  defp log_fni_persist_error(:ok, _what, _id), do: :ok
  defp log_fni_persist_error({:ok, _}, _what, _id), do: :ok
  defp log_fni_persist_error({:error, :already_terminal}, _what, _id), do: :ok

  defp log_fni_persist_error({:error, reason}, what, flow_node_instance_id) do
    Logger.error("Failed to persist #{what} for FNI #{flow_node_instance_id}: #{inspect(reason)}")

    :ok
  end

  @spec resolve_host_fni_id(struct(), String.t()) :: String.t()
  def resolve_host_fni_id(data, boundary_fni_id) do
    case Map.get(data.flow_node_instance_states, boundary_fni_id) do
      %{type_properties: %{host_flow_node_instance_id: host_id}} when is_binary(host_id) ->
        host_id

      %{type_properties: %{"host_flow_node_instance_id" => host_id}} when is_binary(host_id) ->
        host_id

      _ ->
        boundary_fni_id
    end
  end

  @spec boundary_fni_for_host?(map(), String.t()) :: boolean()
  def boundary_fni_for_host?(entry, host_fni_id) do
    type_props = entry.type_properties || %{}

    host_ref =
      Map.get(type_props, :host_flow_node_instance_id) ||
        Map.get(type_props, "host_flow_node_instance_id")

    host_ref == host_fni_id
  end
end

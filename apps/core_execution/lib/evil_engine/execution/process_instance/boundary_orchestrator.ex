defmodule EvilEngine.Execution.ProcessInstance.BoundaryOrchestrator do
  @moduledoc """
  Boundary event orchestration for Process Instance runtime.

  Handles boundary FNI lifecycle (finish, cancel siblings/host), subscription
  boundary resolution, and dispatch-target computation. Does not spawn FNIs or
  call `dispatch_flow_node_instance` — those remain in `ProcessInstance`.
  """

  require Logger

  alias EvilEngine.BPMN.Model.EventDefinition
  alias EvilEngine.BPMN.Model.FlowNode
  alias EvilEngine.BPMN.Model.FlowNodeData
  alias EvilEngine.Events.EngineEventBus
  alias EvilEngine.Execution.FniLifecycle
  alias EvilEngine.Execution.Persistence, as: PersistenceAdapter
  alias EvilEngine.Execution.PersistenceRetry
  alias EvilEngine.Execution.ProcessInstance.Helpers
  alias EvilEngine.Types.Event
  alias EvilEngine.Types.Token

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
    host_fni_id = Helpers.resolve_host_fni_id(data, flow_node_instance_id)
    is_subscription_model = host_fni_id != flow_node_instance_id

    {data, boundary_fni_id} =
      if is_subscription_model do
        {finish_boundary_fni(data, flow_node_instance_id, triggerer_fni_id), flow_node_instance_id}
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

    boundary_node = Helpers.find_flow_node(data, boundary_node_id)
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
    host_fni_id = Helpers.resolve_host_fni_id(data, flow_node_instance_id)

    data =
      if cancel_activity do
        cancel_sibling_boundary_fnis(data, host_fni_id, flow_node_instance_id)
      else
        data
      end

    boundary_node = Helpers.find_flow_node(data, boundary_node_id)
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
      |> Enum.reject(fn node -> is_nil(node) or compensation_boundary?(node) end)
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

  @doc "Interrupts all active/waiting boundary FNIs attached to the given host FNI."
  @spec cancel_boundary_fnis_for_host(struct(), String.t()) :: struct()
  def cancel_boundary_fnis_for_host(data, host_flow_node_instance_id) do
    data.flow_node_instance_states
    |> Enum.filter(fn {_id, entry} ->
      entry.state in [:active, :waiting] and
        Helpers.boundary_fni_for_host?(entry, host_flow_node_instance_id)
    end)
    |> Enum.reduce(data, fn {boundary_fni_id, entry}, accumulator ->
      if entry.pid != nil, do: Process.exit(entry.pid, :kill)

      flow_node = Helpers.find_flow_node(accumulator, entry.flow_node_id)
      Helpers.invoke_optional_callback(flow_node, :handle_aborted, [entry])

      _persist_result =
        FniLifecycle.transition_to_interrupted(
          boundary_fni_id,
          accumulator.process_instance_id,
          "host_completed",
          flow_node,
          Map.get(entry, :type_properties, %{}),
          Helpers.resolve_lane_name(accumulator.process_model, flow_node),
          accumulator.root_process_instance_id
        )

      accumulator =
        %{accumulator | conditional_waiters: Map.delete(accumulator.conditional_waiters, boundary_fni_id)}

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
        Helpers.boundary_fni_for_host?(entry, host_fni_id)
    end)
    |> Enum.reduce(data, fn {sibling_fni_id, entry}, accumulator ->
      if entry.pid != nil, do: Process.exit(entry.pid, :kill)

      flow_node = Helpers.find_flow_node(accumulator, entry.flow_node_id)
      Helpers.invoke_optional_callback(flow_node, :handle_aborted, [entry])

      _persist_result =
        FniLifecycle.transition_to_interrupted(
          sibling_fni_id,
          accumulator.process_instance_id,
          "sibling_boundary_interrupted",
          flow_node,
          Map.get(entry, :type_properties, %{}),
          Helpers.resolve_lane_name(accumulator.process_model, flow_node),
          accumulator.root_process_instance_id
        )

      accumulator =
        %{accumulator | conditional_waiters: Map.delete(accumulator.conditional_waiters, sibling_fni_id)}

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
      Helpers.boundary_fni_for_host?(entry, host_fni_id)
    end)
  end

  defp finish_boundary_fni(data, boundary_fni_id, triggerer_fni_id) do
    case Map.get(data.flow_node_instance_states, boundary_fni_id) do
      nil ->
        data

      entry ->
        if entry.pid != nil, do: Process.exit(entry.pid, :kill)

        flow_node = Helpers.find_flow_node(data, entry.flow_node_id)
        persist_boundary_fni_finished(boundary_fni_id, triggerer_fni_id)

        EngineEventBus.publish(%Event.FlowNodeInstanceFinished{
          flow_node_instance_id: boundary_fni_id,
          process_instance_id: data.process_instance_id,
          root_process_instance_id: data.root_process_instance_id,
          flow_node_id: flow_node.id,
          flow_node_type: flow_node.type,
          event_type: Helpers.extract_event_type(flow_node),
          lane_name: Helpers.resolve_lane_name(data.process_model, flow_node),
          terminal_state: :finished,
          triggerer_flow_node_instance_id: triggerer_fni_id,
          type_properties: %{},
          occurred_at: DateTime.utc_now()
        })

        :telemetry.execute(
          [:evil_engine, :flow_node_instance, :state_change],
          %{system_time: System.system_time()},
          %{
            flow_node_instance_id: boundary_fni_id,
            process_instance_id: data.process_instance_id,
            flow_node_type: flow_node.type,
            terminal_state: :finished
          }
        )

        put_in(data.flow_node_instance_states[boundary_fni_id], %{
          entry
          | state: :finished,
            pid: nil
        })
    end
  end

  defp create_and_finish_error_boundary_fni(data, boundary_node_id, host_fni_id, payload) do
    boundary_node = Helpers.find_flow_node(data, boundary_node_id)
    boundary_fni_id = Helpers.generate_id()
    lane_name = Helpers.resolve_lane_name(data.process_model, boundary_node)
    now = DateTime.utc_now()
    event_type = Helpers.extract_event_type(boundary_node)

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
      [:evil_engine, :flow_node_instance, :started],
      %{system_time: System.system_time()},
      %{
        flow_node_instance_id: boundary_fni_id,
        flow_node_type: boundary_node.type,
        previous_flow_node_instance_ids: [host_fni_id]
      }
    )

    EngineEventBus.publish(%Event.FlowNodeInstanceFinished{
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
      occurred_at: now
    })

    :telemetry.execute(
      [:evil_engine, :flow_node_instance, :state_change],
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
      event_type: Helpers.extract_event_type(boundary_node),
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

    log_fni_persist_error(
      PersistenceRetry.with_retry(
        fn -> adapter.update_flow_node_instance(flow_node_instance_id, :update_finished, changes) end,
        "Boundary FNI finished #{flow_node_instance_id}"
      ),
      "Boundary FNI finished",
      flow_node_instance_id
    )
  end

  defp build_boundary_token(data, flow_node_instance_id, payload) do
    %Token{
      id: Helpers.generate_id(),
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

  defp log_fni_persist_error({:error, reason}, what, flow_node_instance_id) do
    Logger.error("Failed to persist #{what} for FNI #{flow_node_instance_id}: #{inspect(reason)}")

    :ok
  end
end

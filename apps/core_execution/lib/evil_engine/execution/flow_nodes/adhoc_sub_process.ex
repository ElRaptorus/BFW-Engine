defmodule EvilEngine.Execution.FlowNodes.AdHocSubProcess do
  @moduledoc """
  Handler for `<bpmn:adHocSubProcess>` — ad-hoc subprocess execution.

  An ad-hoc subprocess contains activities that are not connected by
  sequence flows and can be activated on demand. Two execution modes:

  - **Engine-managed** (no `implementation`): The engine evaluates
    `evil:ActiveElements` (FEEL) or activates all inner activities,
    then waits for the completion condition to be met.
  - **Plugin-managed** (`implementation` set): Delegates to a plugin
    handler which controls activity activation via the facade.
    (Wired in Phase 5 — Facade.)

  ## Lifecycle

  1. `handle_enter/3` validates contents, applies input mappings,
     spawns a child PI in `AdHocMode`, then enters the activation loop.
  2. In engine-managed mode, activates initial activities per ordering
     and `activeElements` expression.
  3. Awaits child PI terminal message (finished, fatal, error, abort).
  4. On child completion, applies output mappings and returns.
  """

  @behaviour EvilEngine.Execution.FlowNodeHandler

  require Logger

  alias EvilEngine.BPMN.Model.FlowNode
  alias EvilEngine.BPMN.Model.FlowNodeData
  alias EvilEngine.Events.EngineEventBus
  alias EvilEngine.Execution.FlowNodes.ChildLifecycle
  alias EvilEngine.Execution.FniLifecycle
  alias EvilEngine.Execution.HandlerContext
  alias EvilEngine.Execution.Persistence
  alias EvilEngine.Execution.ProcessInstance
  alias EvilEngine.Execution.ProcessInstance.AdHocMode
  alias EvilEngine.Execution.ProcessInstance.Helpers
  alias EvilEngine.Expressions.Context, as: ExpressionsContext
  alias EvilEngine.Types.Event
  alias EvilEngine.Types.Token

  @child_label "Ad-hoc subprocess child process"

  # -------------------------------------------------------------------
  # FlowNodeHandler callbacks
  # -------------------------------------------------------------------

  @impl true
  @spec handle_enter(FlowNode.t(), Token.t(), HandlerContext.t()) ::
          {:async, String.t(), (-> term()), map()} | {:error, term()}
  def handle_enter(flow_node, token, context) do
    type_data = flow_node.type_data

    with :ok <- validate_adhoc_contents(flow_node.id, type_data),
         {:ok, next_ids} <- ChildLifecycle.resolve_outgoing(flow_node, context) do
      process_instance_pid = context.process_instance_pid
      child_process_instance_id = Helpers.generate_uuid_v7()

      continuation = fn ->
        run_child_lifecycle(
          flow_node,
          token,
          context,
          next_ids,
          process_instance_pid,
          child_process_instance_id
        )
      end

      async_type_properties = %{
        "is_ad_hoc" => true,
        "child_process_instance_id" => child_process_instance_id
      }

      case FniLifecycle.park_async(context, async_type_properties) do
        :ok ->
          {:async, context.flow_node_instance_id, continuation,
           Map.put(async_type_properties, "persisted", true)}

        {:error, :persistence_failed} ->
          {:error, :persistence_failed}
      end
    end
  end

  @doc """
  Resume an AdHocSubProcess FNI after engine restart.
  """
  @spec handle_resume(FlowNode.t(), map(), HandlerContext.t(), String.t() | nil) :: term()
  def handle_resume(flow_node, entry, context, nil) do
    run_fresh_lifecycle_from_entry(flow_node, entry, context, context.process_instance_pid)
  end

  def handle_resume(flow_node, entry, context, child_process_instance_id) do
    case ChildLifecycle.query_child_state(child_process_instance_id) do
      {:running, child_pid} ->
        ChildLifecycle.monitor_and_wait(
          flow_node,
          entry,
          context,
          child_pid,
          child_process_instance_id,
          context.process_instance_pid,
          @child_label
        )

      :not_found ->
        ChildLifecycle.resume_existing_child(
          flow_node,
          entry,
          context,
          child_process_instance_id,
          child_label: @child_label,
          extra_resume_opts: %{
            subprocess_node_id: flow_node.id,
            mode: AdHocMode
          },
          fresh_lifecycle_fn: &run_fresh_lifecycle_from_entry/4
        )
    end
  end

  @impl EvilEngine.Execution.FlowNodeHandler
  def handle_fatal(entry) do
    ChildLifecycle.cascade_to_child(entry, fn child_pid ->
      ProcessInstance.force_fatal(child_pid, %{reason: "parent_fatal"})
    end)
  end

  @impl EvilEngine.Execution.FlowNodeHandler
  def handle_aborted(entry) do
    ChildLifecycle.cascade_to_child(entry, fn child_pid ->
      ProcessInstance.abort(child_pid, "parent_aborted", nil)
    end)
  end

  # -------------------------------------------------------------------
  # Private: runtime validation
  # -------------------------------------------------------------------

  defp validate_adhoc_contents(subprocess_id, %FlowNodeData.SubProcess{} = type_data) do
    activities =
      Enum.filter(type_data.flow_nodes, fn node ->
        node.type not in [:start_event, :end_event, :boundary_event]
      end)

    if Enum.empty?(activities) do
      {:error,
       {:adhoc_subprocess_empty,
        "Ad-hoc subprocess '#{subprocess_id}' contains no activities"}}
    else
      :ok
    end
  end

  # -------------------------------------------------------------------
  # Private: lifecycle
  # -------------------------------------------------------------------

  defp run_child_lifecycle(
         flow_node,
         token,
         context,
         next_ids,
         process_instance_pid,
         child_process_instance_id
       ) do
    type_data = flow_node.type_data

    case ChildLifecycle.resolve_input_payload(flow_node, token, context) do
      {:ok, input_payload} ->
        case ChildLifecycle.validate_contract(type_data.payload_contract, input_payload) do
          :ok ->
            execute_child(
              flow_node,
              context,
              input_payload,
              next_ids,
              process_instance_pid,
              child_process_instance_id
            )

          {:error, violations} ->
            {:error, %{reason: :payload_contract_violation, violations: violations}}
        end

      {:error, reason} ->
        {:error, {:in_mapping_failed, reason}}
    end
  end

  defp execute_child(
         flow_node,
         context,
         input_payload,
         next_ids,
         process_instance_pid,
         child_process_instance_id
       ) do
    result =
      start_and_monitor_child(
        context,
        flow_node,
        input_payload,
        child_process_instance_id,
        process_instance_pid
      )

    emit_adhoc_completed(result, context, flow_node, child_process_instance_id)

    ChildLifecycle.dispatch_enter_result(
      result,
      flow_node,
      context,
      child_process_instance_id,
      process_instance_pid,
      next_ids,
      @child_label
    )
  end

  defp start_and_monitor_child(
         context,
         flow_node,
         input_payload,
         child_process_instance_id,
         process_instance_pid
       ) do
    handler_pid = self()
    type_data = flow_node.type_data
    subprocess_model_id = "#{context.process_model.id}__subprocess__#{flow_node.id}"

    start_opts = %{
      process_instance_id: child_process_instance_id,
      process_version_id: context.process_version_id,
      subprocess_node_id: flow_node.id,
      payload: input_payload,
      identity: context.identity,
      parent_process_instance_id: context.process_instance_id,
      root_process_instance_id: context.root_process_instance_id,
      triggerer_flow_node_instance_id: context.flow_node_instance_id,
      notify_pid: handler_pid,
      mode: AdHocMode,
      adhoc_completion_condition: type_data.adhoc_completion_condition,
      adhoc_completion_condition_compiled: type_data.adhoc_completion_condition_compiled,
      adhoc_cancel_remaining_instances: type_data.cancel_remaining_instances,
      adhoc_ordering: type_data.adhoc_ordering
    }

    case EvilEngine.Execution.start_process_instance(start_opts) do
      {:ok, child_pid} ->
        send(
          process_instance_pid,
          {:subprocess_child_started, context.flow_node_instance_id, child_process_instance_id,
           flow_node.id, subprocess_model_id, context.process_model.version, false, true}
        )

        ref = Process.monitor(child_pid)

        activate_initial_activities(child_pid, type_data, context, input_payload)

        ChildLifecycle.await_child_completion(
          child_pid,
          ref,
          child_process_instance_id,
          flow_node,
          context,
          process_instance_pid
        )

      {:error, _reason} ->
        {:fatal,
         %{
           error_code: "CHILD_START_FAILED",
           error_message: "Failed to start ad-hoc subprocess child process"
         }}
    end
  end

  defp activate_initial_activities(child_pid, type_data, context, input_payload) do
    if type_data.implementation != nil do
      Logger.debug(
        "Ad-hoc subprocess has implementation='#{type_data.implementation}' — " <>
          "plugin-managed mode: skipping engine-managed initial activation."
      )

      :ok
    else
      do_engine_managed_activation(child_pid, type_data, context, input_payload)
    end
  end

  defp do_engine_managed_activation(child_pid, type_data, context, input_payload) do
    handler_pid = self()

    inner_activities =
      Enum.filter(type_data.flow_nodes, fn node ->
        node.type not in [:start_event, :end_event, :boundary_event]
      end)

    activities_to_activate =
      inner_activities
      |> resolve_initial_activity_set(type_data, context)
      |> cap_sequential_initial_set(type_data.adhoc_ordering)

    Enum.each(activities_to_activate, fn activity ->
      activation_token = %Token{
        id: Helpers.generate_uuid_v7(),
        process_instance_id: nil,
        payload: input_payload,
        originating_flow_node_instance_id: nil,
        created_at: DateTime.utc_now()
      }

      :gen_statem.cast(
        child_pid,
        {:activate_adhoc_activity, activity.id, activation_token, handler_pid}
      )
    end)

    signal_natural_drain(child_pid, type_data)
  end

  defp resolve_initial_activity_set(inner_activities, type_data, context) do
    cond do
      type_data.active_elements_compiled != nil ->
        evaluate_compiled_active_elements(
          type_data.active_elements_compiled,
          inner_activities,
          context
        )

      type_data.active_elements_expression != nil ->
        evaluate_raw_active_elements(
          type_data.active_elements_expression,
          inner_activities,
          context
        )

      type_data.adhoc_ordering == :sequential ->
        Enum.take(inner_activities, 1)

      true ->
        inner_activities
    end
  end

  defp evaluate_compiled_active_elements(compiled_ref, inner_activities, context) do
    feel_context = build_feel_context(context)

    case EvilEngine.Expressions.evaluate(compiled_ref, feel_context) do
      {:ok, activity_ids} when is_list(activity_ids) ->
        activities_matching_ids_in_list_order(activity_ids, inner_activities)

      {:ok, _non_list} ->
        inner_activities

      {:error, reason} ->
        Logger.warning("ActiveElements FEEL evaluation failed: #{reason}")
        inner_activities
    end
  end

  defp evaluate_raw_active_elements(expression, inner_activities, context) do
    feel_context = build_feel_context(context)

    case EvilEngine.Expressions.eval(expression, feel_context) do
      {:ok, activity_ids} when is_list(activity_ids) ->
        activities_matching_ids_in_list_order(activity_ids, inner_activities)

      {:ok, _non_list} ->
        inner_activities

      {:error, reason} ->
        Logger.warning("ActiveElements FEEL evaluation failed: #{reason}")
        inner_activities
    end
  end

  defp activities_matching_ids_in_list_order(activity_ids, inner_activities) do
    Enum.flat_map(activity_ids, fn activity_id ->
      case Enum.find(inner_activities, &activity_ids_equal?(&1.id, activity_id)) do
        nil -> []
        node -> [node]
      end
    end)
  end

  defp activity_ids_equal?(left, right), do: to_string(left) == to_string(right)

  defp cap_sequential_initial_set(activities, :sequential) do
    case activities do
      [] ->
        []

      [_single] ->
        activities

      [first | rest] ->
        ignored_ids = Enum.map(rest, & &1.id)

        Logger.warning(
          "Sequential ad-hoc subprocess activates only the first activeElements id '#{first.id}'; ignoring #{inspect(ignored_ids)}"
        )

        [first]
    end
  end

  defp cap_sequential_initial_set(activities, _ordering), do: activities

  defp build_feel_context(context) do
    ExpressionsContext.from_handler_context(context, %{})
  end

  defp signal_natural_drain(child_pid, type_data) do
    if type_data.adhoc_completion_condition == nil do
      :gen_statem.cast(child_pid, :adhoc_natural_drain_enabled)
    end
  end

  # -------------------------------------------------------------------
  # Private: resume from scratch
  # -------------------------------------------------------------------

  defp emit_adhoc_completed(result, context, flow_node, child_process_instance_id) do
    completion_reason =
      case result do
        {:finished, _} -> :completed
        {:fatal, _} -> :fatal
        {:bpmn_error, _} -> :error
        :aborted -> :aborted
        {:crashed, _} -> :crashed
        {:escalation, _, _} -> :escalation
        _ -> :unknown
      end

    total_activations = count_child_activations(child_process_instance_id)

    EngineEventBus.publish(
      %Event.AdHocSubProcessCompleted{
        process_instance_id: context.process_instance_id,
        root_process_instance_id: context.root_process_instance_id,
        adhoc_flow_node_instance_id: context.flow_node_instance_id,
        adhoc_node_id: flow_node.id,
        completion_reason: completion_reason,
        total_activations: total_activations,
        lane_name: Helpers.resolve_lane_name_from_context(context, flow_node),
        occurred_at: DateTime.utc_now()
      }
    )
  end

  defp count_child_activations(child_process_instance_id) do
    case Persistence.adapter().count_all_flow_node_instances(child_process_instance_id) do
      {:ok, count} -> count
      _ -> 0
    end
  end

  defp run_fresh_lifecycle_from_entry(flow_node, entry, context, _process_instance_pid) do
    type_data = flow_node.type_data
    child_process_instance_id = Helpers.generate_uuid_v7()

    with {:ok, next_ids} <- ChildLifecycle.resolve_outgoing(flow_node, context),
         :ok <- validate_adhoc_contents(flow_node.id, type_data),
         {:ok, input_payload} <-
           ChildLifecycle.resolve_input_payload(flow_node, entry.token, context),
         :ok <- ChildLifecycle.validate_contract(type_data.payload_contract, input_payload) do
      execute_child(
        flow_node,
        context,
        input_payload,
        next_ids,
        context.process_instance_pid,
        child_process_instance_id
      )
    else
      {:error, %{} = structured} ->
        {:error, structured}

      {:error, reason} ->
        {:error, reason}
    end
  end
end

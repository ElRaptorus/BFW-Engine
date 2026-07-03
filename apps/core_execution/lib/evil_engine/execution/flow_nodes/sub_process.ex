defmodule EvilEngine.Execution.FlowNodes.SubProcess do
  @moduledoc """
  Handler for `<bpmn:subProcess>` — embedded subprocess execution.

  Follows the same async-continuation pattern as Call Activity:
  the handler Task parks the FNI as `:waiting`, starts a child PI
  for the subprocess's inner scope, monitors it, and processes the
  result when the child completes.

  Key differences from Call Activity:
  - The child PI reuses the parent's `process_version_id` with a
    synthetic `%Process{}` extracted from `FlowNodeData.SubProcess`
  - Runtime validation of subprocess contents (exactly one None
    Start Event, no typed start events, at least one End Event)
    happens here rather than at deploy time, allowing WIP diagrams
  - The `subprocess_node_id` is passed to `start_process_instance`
    so the child PI resolves the correct synthetic model
  """

  @behaviour EvilEngine.Execution.FlowNodeHandler

  @error_code_child_crash "CHILD_CRASH"
  @error_code_child_start_failed "CHILD_START_FAILED"
  @error_code_child_fatal "CHILD_FATAL"

  alias EvilEngine.BPMN.Model.EventDefinition
  alias EvilEngine.BPMN.Model.FlowNode
  alias EvilEngine.BPMN.Model.FlowNodeData
  alias EvilEngine.Execution.BoundaryResolver
  alias EvilEngine.Execution.EscalationResolver
  alias EvilEngine.Execution.FlowNodeResult
  alias EvilEngine.Execution.FniLifecycle
  alias EvilEngine.Execution.HandlerContext
  alias EvilEngine.Execution.MappingHelper
  alias EvilEngine.Execution.Persistence, as: PersistenceAdapter
  alias EvilEngine.Execution.ProcessInstance
  alias EvilEngine.Execution.SequenceFlowResolver
  alias EvilEngine.Types.Token

  # -------------------------------------------------------------------
  # FlowNodeHandler callbacks
  # -------------------------------------------------------------------

  @doc """
  Validates the subprocess contents at runtime, applies input mappings
  and payload contract, then spawns a child PI for the inner scope.
  """
  @spec handle_enter(FlowNode.t(), Token.t(), HandlerContext.t()) ::
          {:async, String.t(), (-> term()), map()} | {:error, term()}
  @impl true
  def handle_enter(flow_node, token, context) do
    type_data = flow_node.type_data

    with :ok <- guard_event_subprocess(type_data),
         {:ok, start_event_id} <- validate_subprocess_contents(flow_node.id, type_data),
         {:ok, next_ids} <- resolve_outgoing(flow_node, context) do
      process_instance_pid = context.process_instance_pid
      child_process_instance_id = generate_uuid_v7()

      continuation = fn ->
        run_child_lifecycle(
          flow_node,
          token,
          context,
          start_event_id,
          next_ids,
          process_instance_pid,
          child_process_instance_id
        )
      end

      async_type_properties = %{child_process_instance_id: child_process_instance_id}

      case FniLifecycle.park_async(context, async_type_properties) do
        :ok ->
          {:async, context.flow_node_instance_id, continuation,
           Map.put(async_type_properties, :persisted, true)}

        {:error, :persistence_failed} ->
          {:error, :persistence_failed}
      end
    end
  end

  @doc """
  Resume a SubProcess FNI after engine restart.

  Checks the child PI's state and either re-monitors a running child
  or re-executes the full lifecycle if no child was ever spawned.
  """
  @spec handle_resume(FlowNode.t(), map(), HandlerContext.t(), String.t() | nil) ::
          {:ok, FlowNodeResult.t()} | {:boundary, String.t(), term()} | {:error, term()}
  def handle_resume(flow_node, entry, context, nil) do
    run_fresh_lifecycle(flow_node, entry, context, context.process_instance_pid)
  end

  def handle_resume(flow_node, entry, context, child_process_instance_id) do
    case query_child_state(child_process_instance_id) do
      {:running, child_pid} ->
        monitor_and_wait(
          flow_node,
          entry,
          context,
          child_pid,
          child_process_instance_id,
          context.process_instance_pid
        )

      :not_found ->
        resume_existing_child(flow_node, entry, context, child_process_instance_id)
    end
  end

  @impl EvilEngine.Execution.FlowNodeHandler
  def handle_fatal(entry) do
    cascade_to_child(entry, fn child_pid ->
      ProcessInstance.force_fatal(child_pid, %{reason: "parent_fatal"})
    end)
  end

  @impl EvilEngine.Execution.FlowNodeHandler
  def handle_aborted(entry) do
    cascade_to_child(entry, fn child_pid ->
      ProcessInstance.abort(child_pid, "parent_aborted", nil)
    end)
  end

  # -------------------------------------------------------------------
  # Private: runtime validation
  # -------------------------------------------------------------------

  defp guard_event_subprocess(%FlowNodeData.SubProcess{triggered_by_event: true}) do
    {:error, :event_subprocess_not_supported}
  end

  defp guard_event_subprocess(_type_data), do: :ok

  defp validate_subprocess_contents(subprocess_id, %FlowNodeData.SubProcess{} = type_data) do
    none_start_events =
      Enum.filter(type_data.flow_nodes, fn node ->
        node.type == :start_event and
          match?(%EventDefinition.None{}, node.type_data.event_definition)
      end)

    typed_start_events =
      Enum.filter(type_data.flow_nodes, fn node ->
        node.type == :start_event and
          not match?(%EventDefinition.None{}, node.type_data.event_definition)
      end)

    end_events = Enum.filter(type_data.flow_nodes, &(&1.type == :end_event))

    cond do
      length(none_start_events) != 1 ->
        {:error,
         %{
           reason: :invalid_subprocess,
           detail:
             "Subprocess '#{subprocess_id}' must have exactly one None Start Event, found #{length(none_start_events)}"
         }}

      typed_start_events != [] ->
        {:error,
         %{
           reason: :invalid_subprocess,
           detail:
             "Subprocess '#{subprocess_id}' contains typed Start Events, which are only allowed in Event Subprocesses"
         }}

      end_events == [] ->
        {:error,
         %{
           reason: :invalid_subprocess,
           detail: "Subprocess '#{subprocess_id}' has no End Event"
         }}

      true ->
        {:ok, hd(none_start_events).id}
    end
  end

  # -------------------------------------------------------------------
  # Private: lifecycle
  # -------------------------------------------------------------------

  defp run_child_lifecycle(
         flow_node,
         token,
         context,
         start_event_id,
         next_ids,
         process_instance_pid,
         child_process_instance_id
       ) do
    case resolve_input_payload(flow_node, token, context) do
      {:ok, input_payload} ->
        case validate_payload_contract(flow_node.type_data.payload_contract, input_payload) do
          :ok ->
            execute_child(
              flow_node,
              context,
              input_payload,
              start_event_id,
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
         start_event_id,
         next_ids,
         process_instance_pid,
         child_process_instance_id
       ) do
    case start_and_monitor_child(
           context,
           flow_node,
           input_payload,
           child_process_instance_id,
           process_instance_pid,
           start_event_id
         ) do
      {:finished, final_tokens} ->
        apply_out_mappings_to_result(
          flow_node,
          context,
          final_tokens,
          next_ids,
          child_process_instance_id
        )

      {:escalation, escalation_info, final_tokens} ->
        handle_child_escalation_end(
          flow_node,
          context,
          escalation_info,
          final_tokens,
          child_process_instance_id,
          process_instance_pid,
          next_ids
        )

      {:fatal, reason} ->
        handle_child_error(flow_node, context, normalize_error(reason))

      {:bpmn_error, error_info} ->
        handle_child_bpmn_error(flow_node, context, error_info, child_process_instance_id)

      :aborted ->
        :abort_cascade

      {:crashed, _reason} ->
        error_info = %{
          error_code: @error_code_child_crash,
          error_message: "Subprocess child process crashed"
        }

        handle_child_error(flow_node, context, error_info)
    end
  end

  defp start_and_monitor_child(
         context,
         flow_node,
         input_payload,
         child_process_instance_id,
         process_instance_pid,
         start_event_id
       ) do
    handler_pid = self()
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
      start_event_id: start_event_id
    }

    case EvilEngine.Execution.start_process_instance(start_opts) do
      {:ok, child_pid} ->
        send(
          process_instance_pid,
          {:subprocess_child_started, context.flow_node_instance_id, child_process_instance_id,
           flow_node.id, subprocess_model_id, context.process_model.version, false}
        )

        ref = Process.monitor(child_pid)

        await_child_completion(
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
           error_code: @error_code_child_start_failed,
           error_message: "Failed to start subprocess child process"
         }}
    end
  end

  defp await_child_completion(
         child_pid,
         ref,
         child_process_instance_id,
         flow_node,
         context,
         process_instance_pid
       ) do
    receive do
      {:child_pi_finished, ^child_pid, final_tokens} ->
        Process.demonitor(ref, [:flush])
        {:finished, final_tokens}

      {:child_pi_fatal, ^child_pid, reason} ->
        Process.demonitor(ref, [:flush])
        {:fatal, reason}

      {:child_pi_bpmn_error, ^child_pid, error_info, _final_tokens} ->
        Process.demonitor(ref, [:flush])
        {:bpmn_error, error_info}

      {:child_pi_aborted, ^child_pid} ->
        Process.demonitor(ref, [:flush])
        :aborted

      {:child_pi_escalation, ^child_pid, escalation_info, final_tokens} ->
        Process.demonitor(ref, [:flush])
        {:escalation, escalation_info, final_tokens}

      {:child_pi_escalation_passthrough, ^child_pid, escalation_info} ->
        handle_escalation_passthrough_in_await(
          flow_node,
          context,
          escalation_info,
          process_instance_pid
        )

        await_child_completion(
          child_pid,
          ref,
          child_process_instance_id,
          flow_node,
          context,
          process_instance_pid
        )

      {:DOWN, ^ref, :process, ^child_pid, :normal} ->
        {:finished, aggregate_from_persistence(child_process_instance_id)}

      {:DOWN, ^ref, :process, ^child_pid, reason} ->
        {:crashed, reason}
    end
  end

  # -------------------------------------------------------------------
  # Private: result handling
  # -------------------------------------------------------------------

  defp apply_out_mappings_to_result(
         flow_node,
         context,
         final_tokens,
         next_ids,
         child_process_instance_id
       ) do
    aggregated = aggregate_tokens(final_tokens)
    type_properties = %{child_process_instance_id: child_process_instance_id}

    with {:ok, output} <- apply_out_mappings(flow_node, aggregated, context),
         :ok <- validate_result_contract(flow_node.type_data.result_contract, output),
         {:ok, lifecycle_result} <-
           FniLifecycle.finish(context, flow_node, output, type_properties) do
      {:ok,
       %FlowNodeResult{
         output_payload: output,
         next_flow_node_ids: next_ids,
         type_properties: type_properties,
         metadata: %{persisted: true, lifecycle: lifecycle_result}
       }}
    else
      {:error, violations} when is_list(violations) ->
        {:error, %{reason: :result_contract_violation, violations: violations}}

      {:error, reason} ->
        {:error, {:out_mapping_failed, reason}}
    end
  end

  defp aggregate_tokens(final_tokens) when is_list(final_tokens) do
    Enum.reduce(final_tokens, %{}, fn token, acc ->
      case token do
        %{payload: payload} when is_map(payload) -> Map.merge(acc, payload)
        _ -> acc
      end
    end)
  end

  defp aggregate_tokens(payload) when is_map(payload), do: payload
  defp aggregate_tokens(_), do: %{}

  # -------------------------------------------------------------------
  # Private: mappings and contracts
  # -------------------------------------------------------------------

  defp resolve_input_payload(flow_node, token, context) do
    MappingHelper.apply_in_mappings(flow_node.type_data.in_mappings, token.payload, context)
  end

  defp apply_out_mappings(flow_node, aggregated_payload, context) do
    MappingHelper.apply_out_mappings(
      flow_node.type_data.out_mappings,
      aggregated_payload,
      context
    )
  end

  defp validate_payload_contract(contract, payload) do
    MappingHelper.validate_contract(contract, payload)
  end

  defp validate_result_contract(contract, output) do
    MappingHelper.validate_contract(contract, output)
  end

  # -------------------------------------------------------------------
  # Private: error / boundary resolution
  # -------------------------------------------------------------------

  defp handle_child_bpmn_error(flow_node, context, error_info, child_process_instance_id) do
    case handle_child_error(flow_node, context, error_info) do
      {:boundary, _, _, _} = boundary_result ->
        boundary_result

      {:error, _} ->
        propagate_bpmn_error(flow_node, context, error_info, child_process_instance_id)
    end
  end

  defp propagate_bpmn_error(flow_node, context, error_info, child_process_instance_id) do
    type_properties = %{child_process_instance_id: child_process_instance_id}

    case FniLifecycle.finish_as_error(context, flow_node, nil, type_properties) do
      {:ok, lifecycle_result} ->
        {:bpmn_error, error_info,
         %FlowNodeResult{
           output_payload: nil,
           next_flow_node_ids: [],
           type_properties: type_properties,
           metadata: %{persisted: true, lifecycle: lifecycle_result}
         }}

      {:error, _persist_reason} ->
        {:error, error_info}
    end
  end

  defp handle_child_error(flow_node, context, error_info) do
    case BoundaryResolver.find_matching_error_boundary(
           flow_node,
           context.process_model,
           error_info
         ) do
      {:ok, boundary_node} ->
        cancel = Map.get(boundary_node.type_data, :cancel_activity, true)
        {:boundary, boundary_node.id, error_info, cancel}

      :none ->
        {:error, error_info}
    end
  end

  defp normalize_error(%{error_code: _} = reason), do: reason

  defp normalize_error(_reason) do
    %{error_code: @error_code_child_fatal, error_message: "Subprocess child ended in a fatal state"}
  end

  # -------------------------------------------------------------------
  # Private: routing
  # -------------------------------------------------------------------

  defp resolve_outgoing(flow_node, context) do
    case SequenceFlowResolver.resolve(flow_node, context.process_model) do
      {:ok, targets} ->
        {:ok, Enum.map(targets, & &1.id)}

      {:error, reason, meta} ->
        {:error, Map.put(meta, :reason, reason)}
    end
  end

  # -------------------------------------------------------------------
  # Private: resume helpers
  # -------------------------------------------------------------------

  defp query_child_state(nil), do: :not_found

  defp query_child_state(child_process_instance_id) do
    case EvilEngine.Execution.lookup_process_instance(child_process_instance_id) do
      {:ok, pid} -> {:running, pid}
      {:error, _} -> :not_found
    end
  end

  defp monitor_and_wait(
         flow_node,
         entry,
         context,
         child_pid,
         child_process_instance_id,
         process_instance_pid
       ) do
    set_child_notify_pid(child_pid, self())
    ref = Process.monitor(child_pid)

    result =
      await_child_completion(
        child_pid,
        ref,
        child_process_instance_id,
        flow_node,
        context,
        process_instance_pid
      )

    case result do
      {:finished, final_tokens} ->
        apply_result(flow_node, entry, context, final_tokens, child_process_instance_id)

      {:fatal, reason} ->
        handle_child_error(flow_node, context, normalize_error(reason))

      {:bpmn_error, error_info} ->
        handle_child_bpmn_error(flow_node, context, error_info, child_process_instance_id)

      {:escalation, escalation_info, final_tokens} ->
        {:ok, next_ids} = resolve_outgoing(flow_node, context)

        handle_child_escalation_end(
          flow_node,
          context,
          escalation_info,
          final_tokens,
          child_process_instance_id,
          process_instance_pid,
          next_ids
        )

      :aborted ->
        :abort_cascade

      {:crashed, _reason} ->
        error_info = %{
          error_code: @error_code_child_crash,
          error_message: "Subprocess child process crashed"
        }

        handle_child_error(flow_node, context, error_info)
    end
  end

  defp apply_result(flow_node, _entry, context, final_tokens, child_process_instance_id) do
    {:ok, next_ids} = resolve_outgoing(flow_node, context)
    aggregated = aggregate_tokens(final_tokens)
    type_properties = %{child_process_instance_id: child_process_instance_id}

    with {:ok, output} <- apply_out_mappings(flow_node, aggregated, context),
         :ok <- validate_result_contract(flow_node.type_data.result_contract, output),
         {:ok, lifecycle_result} <-
           FniLifecycle.finish(context, flow_node, output, type_properties) do
      {:ok,
       %FlowNodeResult{
         output_payload: output,
         next_flow_node_ids: next_ids,
         type_properties: type_properties,
         metadata: %{persisted: true, lifecycle: lifecycle_result}
       }}
    else
      {:error, violations} when is_list(violations) ->
        {:error, %{reason: :result_contract_violation, violations: violations}}

      {:error, reason} ->
        {:error, {:out_mapping_failed, reason}}
    end
  end

  defp set_child_notify_pid(child_pid, handler_pid) do
    ProcessInstance.update_notify_pid(child_pid, handler_pid)
  catch
    :exit, _ -> :ok
  end

  defp run_fresh_lifecycle(flow_node, entry, context, process_instance_pid) do
    type_data = flow_node.type_data
    child_process_instance_id = generate_uuid_v7()

    with :ok <- guard_event_subprocess(type_data),
         {:ok, next_ids} <- resolve_outgoing(flow_node, context),
         {:ok, start_event_id} <- validate_subprocess_contents(flow_node.id, type_data),
         {:ok, input_payload} <- resolve_input_payload(flow_node, entry.token, context),
         :ok <- validate_payload_contract(type_data.payload_contract, input_payload) do
      case start_and_monitor_child(
             context,
             flow_node,
             input_payload,
             child_process_instance_id,
             process_instance_pid,
             start_event_id
           ) do
        {:finished, final_tokens} ->
          apply_out_mappings_to_result(
            flow_node,
            context,
            final_tokens,
            next_ids,
            child_process_instance_id
          )

        {:fatal, reason} ->
          handle_child_error(flow_node, context, normalize_error(reason))

        {:bpmn_error, error_info} ->
          handle_child_bpmn_error(flow_node, context, error_info, child_process_instance_id)

        {:escalation, escalation_info, final_tokens} ->
          handle_child_escalation_end(
            flow_node,
            context,
            escalation_info,
            final_tokens,
            child_process_instance_id,
            process_instance_pid,
            next_ids
          )

        :aborted ->
          :abort_cascade

        {:crashed, _reason} ->
          error_info = %{
            error_code: @error_code_child_crash,
            error_message: "Subprocess child process crashed"
          }

          handle_child_error(flow_node, context, error_info)
      end
    else
      {:error, %{} = structured} ->
        {:error, structured}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resume_existing_child(flow_node, entry, context, child_process_instance_id) do
    adapter = PersistenceAdapter.adapter()
    process_instance_pid = context.process_instance_pid

    case adapter.get_process_instance_for_retry(child_process_instance_id) do
      {:ok, %{state: "finished"}} ->
        final_tokens = aggregate_from_persistence(child_process_instance_id)
        apply_result(flow_node, entry, context, final_tokens, child_process_instance_id)

      {:ok, %{state: "fatal", error_info: error_info}} ->
        handle_child_error(flow_node, context, normalize_error(error_info || "CHILD_FATAL"))

      {:ok, %{state: "error", error_info: error_info}} ->
        resume_from_bpmn_error_child(flow_node, context, error_info, child_process_instance_id)

      {:ok, %{state: "escalated", error_info: escalation_error_info}} ->
        resume_from_escalated_child(
          flow_node,
          context,
          child_process_instance_id,
          escalation_error_info,
          process_instance_pid
        )

      {:ok, %{state: "aborted"}} ->
        :abort_cascade

      {:ok, child_pi_data} ->
        start_child_from_persistence(
          flow_node,
          entry,
          context,
          child_process_instance_id,
          child_pi_data,
          adapter
        )

      {:error, :not_found} ->
        run_fresh_lifecycle(flow_node, entry, context, context.process_instance_pid)
    end
  end

  defp resume_from_bpmn_error_child(flow_node, context, error_info, child_process_instance_id) do
    handle_child_bpmn_error(
      flow_node,
      context,
      error_info || %{error_code: nil, error_message: nil},
      child_process_instance_id
    )
  end

  defp start_child_from_persistence(
         flow_node,
         entry,
         context,
         child_process_instance_id,
         child_pi_data,
         adapter
       ) do
    handler_pid = self()

    with {:ok, child_fnis} <- adapter.list_all_flow_node_instances(child_process_instance_id),
         {:ok, pending_arrivals} <-
           adapter.list_gateway_pending_arrivals(child_process_instance_id) do
      child_resume_opts = %{
        resume: true,
        process_instance_id: child_process_instance_id,
        process_version_id: child_pi_data.process_version_id,
        subprocess_node_id: flow_node.id,
        business_key: child_pi_data.business_key,
        parent_process_instance_id: child_pi_data.parent_process_instance_id,
        triggerer_flow_node_instance_id: child_pi_data.triggerer_flow_node_instance_id,
        started_at: child_pi_data.started_at,
        started_by: child_pi_data.started_by,
        started_with_context: child_pi_data.started_with_context,
        notify_pid: handler_pid,
        fni_data: child_fnis,
        pending_arrivals: pending_arrivals
      }

      case DynamicSupervisor.start_child(
             EvilEngine.Execution.Supervisor,
             {ProcessInstance, child_resume_opts}
           ) do
        {:ok, child_pid} ->
          monitor_and_wait(
            flow_node,
            entry,
            context,
            child_pid,
            child_process_instance_id,
            context.process_instance_pid
          )

        {:error, {:already_started, existing_pid}} ->
          monitor_and_wait(
            flow_node,
            entry,
            context,
            existing_pid,
            child_process_instance_id,
            context.process_instance_pid
          )

        {:error, reason} ->
          {:error,
           %{
             error_code: "child_resume_failed",
             message:
               "Failed to resume child PI #{child_process_instance_id}: #{inspect(reason)}"
           }}
      end
    else
      {:error, reason} ->
        {:error,
         %{
           error_code: "child_resume_failed",
           message: "Failed to load child PI data: #{inspect(reason)}"
         }}
    end
  end

  defp aggregate_from_persistence(child_process_instance_id) do
    adapter = PersistenceAdapter.adapter()

    case adapter.list_flow_node_instances(child_process_instance_id) do
      {:ok, flow_node_instances} ->
        flow_node_instances
        |> Enum.filter(fn flow_node_instance ->
          flow_node_instance.flow_node_type in ["end_event", :end_event] and
            flow_node_instance.state in ["finished", :finished]
        end)
        |> Enum.map(fn flow_node_instance ->
          %{payload: flow_node_instance[:output_token] || %{}}
        end)

      {:error, _} ->
        []
    end
  end

  # -------------------------------------------------------------------
  # Private: escalation handling
  # -------------------------------------------------------------------

  defp handle_child_escalation_end(
         flow_node,
         context,
         escalation_info,
         final_tokens,
         child_process_instance_id,
         process_instance_pid,
         next_ids
       ) do
    triggerer_fni_id = escalation_info[:triggerer_flow_node_instance_id]

    case EscalationResolver.find_first_interrupting_escalation_boundary(
           flow_node,
           context.process_model,
           context.definitions,
           escalation_info
         ) do
      {:ok, boundary_node} ->
        {:boundary, boundary_node.id, escalation_info, true, triggerer_fni_id}

      :none ->
        apply_non_interrupting_escalation_end(
          flow_node,
          context,
          escalation_info,
          final_tokens,
          child_process_instance_id,
          process_instance_pid,
          next_ids
        )
    end
  end

  defp apply_non_interrupting_escalation_end(
         flow_node,
         context,
         escalation_info,
         final_tokens,
         child_process_instance_id,
         process_instance_pid,
         next_ids
       ) do
    triggerer_fni_id = escalation_info[:triggerer_flow_node_instance_id]

    boundaries =
      EscalationResolver.find_non_interrupting_escalation_boundaries(
        flow_node,
        context.process_model,
        context.definitions,
        escalation_info
      )

    case boundaries do
      [] ->
        propagate_escalation_end(flow_node, context, escalation_info, next_ids)

      non_interrupting ->
        Enum.each(non_interrupting, fn boundary_node ->
          send(
            process_instance_pid,
            {:fni_result, context.flow_node_instance_id,
             {:boundary, boundary_node.id, escalation_info, false, triggerer_fni_id}}
          )
        end)

        apply_out_mappings_to_result(
          flow_node,
          context,
          final_tokens,
          next_ids,
          child_process_instance_id
        )
    end
  end

  defp resume_from_escalated_child(
         flow_node,
         context,
         child_process_instance_id,
         escalation_error_info,
         process_instance_pid
       ) do
    {:ok, next_ids} = resolve_outgoing(flow_node, context)

    escalation_info =
      if escalation_error_info do
        %{
          escalation_code: escalation_error_info["error_code"],
          escalation_name: escalation_error_info["message"]
        }
      else
        %{escalation_code: nil, escalation_name: nil}
      end

    final_tokens = aggregate_from_persistence(child_process_instance_id)

    handle_child_escalation_end(
      flow_node,
      context,
      escalation_info,
      final_tokens,
      child_process_instance_id,
      process_instance_pid,
      next_ids
    )
  end

  defp propagate_escalation_end(flow_node, context, escalation_info, _next_ids) do
    type_properties = %{}

    case FniLifecycle.finish(context, flow_node, nil, type_properties) do
      {:ok, lifecycle_result} ->
        {:escalation_end_propagate, escalation_info,
         %FlowNodeResult{
           output_payload: nil,
           next_flow_node_ids: [],
           type_properties: type_properties,
           metadata: %{persisted: true, lifecycle: lifecycle_result}
         }}

      {:error, _reason} ->
        {:error,
         %{
           error_code: "escalation_persist_failed",
           message: "Failed to finish subprocess FNI during escalation propagation"
         }}
    end
  end

  defp handle_escalation_passthrough_in_await(
         flow_node,
         context,
         escalation_info,
         process_instance_pid
       ) do
    triggerer_fni_id = escalation_info[:triggerer_flow_node_instance_id]

    case EscalationResolver.find_first_interrupting_escalation_boundary(
           flow_node,
           context.process_model,
           context.definitions,
           escalation_info
         ) do
      {:ok, boundary_node} ->
        send(
          process_instance_pid,
          {:fni_result, context.flow_node_instance_id,
           {:boundary, boundary_node.id, escalation_info, true, triggerer_fni_id}}
        )

      :none ->
        fire_non_interrupting_or_passthrough(
          flow_node,
          context,
          escalation_info,
          process_instance_pid
        )
    end
  end

  defp fire_non_interrupting_or_passthrough(
         flow_node,
         context,
         escalation_info,
         process_instance_pid
       ) do
    triggerer_fni_id = escalation_info[:triggerer_flow_node_instance_id]

    boundaries =
      EscalationResolver.find_non_interrupting_escalation_boundaries(
        flow_node,
        context.process_model,
        context.definitions,
        escalation_info
      )

    if Enum.empty?(boundaries) do
      send(process_instance_pid, {:escalation_passthrough, escalation_info})
    else
      Enum.each(boundaries, fn boundary_node ->
        send(
          process_instance_pid,
          {:fni_result, context.flow_node_instance_id,
           {:boundary, boundary_node.id, escalation_info, false, triggerer_fni_id}}
        )
      end)
    end
  end

  # -------------------------------------------------------------------
  # Private: cascade callbacks
  # -------------------------------------------------------------------

  defp cascade_to_child(entry, action) do
    child_process_instance_id = get_child_process_instance_id(entry.type_properties)

    if is_binary(child_process_instance_id) do
      case EvilEngine.Execution.lookup_process_instance(child_process_instance_id) do
        {:ok, child_pid} -> action.(child_pid)
        {:error, :not_found} -> :ok
      end
    else
      :ok
    end
  catch
    :exit, _ -> :ok
  end

  defp get_child_process_instance_id(nil), do: nil

  defp get_child_process_instance_id(type_properties) do
    type_properties[:child_process_instance_id] ||
      type_properties["child_process_instance_id"]
  end

  # -------------------------------------------------------------------
  # Private: helpers
  # -------------------------------------------------------------------

  defp generate_uuid_v7 do
    timestamp_ms = System.system_time(:millisecond)
    <<rand_a::12, rand_b::62, _::6>> = :crypto.strong_rand_bytes(10)

    <<timestamp_ms::48, 7::4, rand_a::12, 2::2, rand_b::62>>
    |> Base.encode16(case: :lower)
    |> then(fn <<a::binary-8, b::binary-4, c::binary-4, d::binary-4, e::binary-12>> ->
      "#{a}-#{b}-#{c}-#{d}-#{e}"
    end)
  end
end

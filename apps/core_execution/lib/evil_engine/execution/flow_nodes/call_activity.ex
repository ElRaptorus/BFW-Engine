defmodule EvilEngine.Execution.FlowNodes.CallActivity do
  @moduledoc """
  Handler for `<bpmn:callActivity>` — invokes another process as a child.

  Owns the full lifecycle: version resolution, child PI spawn, monitoring,
  result/error handling, out-mapping evaluation, and boundary event resolution.
  The PI remains a pure dispatcher — it receives standard result shapes
  (`{:ok, ...}`, `{:error, ...}`, `{:boundary, ...}`) and reacts generically.

  The handler Task stays alive while the child PI runs, using the
  `{:async, flow_node_instance_id}` parking mechanism to keep the FNI in `:waiting`.
  """

  @behaviour EvilEngine.Execution.FlowNodeHandler

  @error_code_child_crash "CHILD_CRASH"
  @error_code_child_start_failed "CHILD_START_FAILED"
  @error_code_child_fatal "CHILD_FATAL"

  alias EvilEngine.BPMN.Model.FlowNode
  alias EvilEngine.Execution.BoundaryResolver
  alias EvilEngine.Execution.CalledElementResolver
  alias EvilEngine.Execution.EscalationResolver
  alias EvilEngine.Execution.FlowNodeResult
  alias EvilEngine.Execution.FniLifecycle
  alias EvilEngine.Execution.HandlerContext
  alias EvilEngine.Execution.MappingHelper
  alias EvilEngine.Execution.Persistence, as: PersistenceAdapter
  alias EvilEngine.Execution.ProcessInstance
  alias EvilEngine.Execution.SequenceFlowResolver
  alias EvilEngine.Types.Token

  @doc "Resolves the called element, spawns a child PI, and parks the FNI as `:waiting`."
  @spec handle_enter(FlowNode.t(), Token.t(), HandlerContext.t()) ::
          {:async, String.t(), (-> term()), map()} | {:error, term()}
  @impl true
  def handle_enter(flow_node, token, context) do
    called_element = flow_node.type_data.called_element

    with {:ok, next_ids} <- resolve_outgoing(flow_node, context),
         {:ok, resolved} <- resolve_called_version(called_element) do
      process_instance_pid = context.process_instance_pid
      child_process_instance_id = generate_uuid_v7()

      continuation = fn ->
        run_child_lifecycle(
          flow_node,
          token,
          context,
          resolved,
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
  Resume a Call Activity FNI after engine restart.

  Checks the child PI's state in persistence and either processes
  the result immediately, re-monitors the running child, or
  re-executes the full lifecycle if no child was ever spawned.
  """
  @spec handle_resume(FlowNode.t(), map(), HandlerContext.t(), String.t() | nil) ::
          {:ok, FlowNodeResult.t()} | {:boundary, String.t(), term()} | {:error, term()}
  def handle_resume(flow_node, entry, context, nil) do
    run_fresh_lifecycle(flow_node, entry, context, context.process_instance_pid)
  end

  def handle_resume(flow_node, entry, context, child_process_instance_id) do
    case query_child_state(PersistenceAdapter.adapter(), child_process_instance_id) do
      {:running, child_pid} ->
        monitor_and_wait(flow_node, entry, context, child_pid, child_process_instance_id)

      :not_found ->
        resume_existing_child(flow_node, entry, context, child_process_instance_id)
    end
  end

  # -- Private: lifecycle ----------------------------------------------------

  defp run_child_lifecycle(
         flow_node,
         token,
         context,
         resolved,
         next_ids,
         process_instance_pid,
         child_process_instance_id
       ) do
    case resolve_input_payload(flow_node, token, context) do
      {:ok, input_payload} ->
        case start_and_monitor_child(
               flow_node,
               context,
               resolved,
               input_payload,
               child_process_instance_id,
               process_instance_pid,
               flow_node.type_data.start_event_id
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
              error_message: "Child process crashed"
            }

            handle_child_error(flow_node, context, error_info)
        end

      {:error, reason} ->
        {:error, {:in_mapping_failed, reason}}
    end
  end

  defp start_and_monitor_child(
         flow_node,
         context,
         resolved,
         input_payload,
         child_process_instance_id,
         process_instance_pid,
         start_event_id
       ) do
    handler_pid = self()

    start_opts =
      %{
        process_instance_id: child_process_instance_id,
        process_version_id: resolved.process_version_id,
        payload: input_payload,
        identity: context.identity,
        parent_process_instance_id: context.process_instance_id,
        root_process_instance_id: child_process_instance_id,
        triggerer_flow_node_instance_id: context.flow_node_instance_id,
        notify_pid: handler_pid
      }
      |> maybe_put_start_event_id(start_event_id)

    case EvilEngine.Execution.start_process_instance(start_opts) do
      {:ok, child_pid} ->
        send(
          process_instance_pid,
          {:call_activity_child_started, context.flow_node_instance_id, child_process_instance_id,
           resolved.process_model_id, resolved.version}
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
           error_message: "Failed to start child process"
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

      {:child_pi_escalation, ^child_pid, escalation_info, final_tokens} ->
        Process.demonitor(ref, [:flush])
        {:escalation, escalation_info, final_tokens}

      {:child_pi_escalation_passthrough, ^child_pid, escalation_info} ->
        handle_escalation_passthrough_in_await(
          escalation_info,
          flow_node,
          context,
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

      {:child_pi_fatal, ^child_pid, reason} ->
        Process.demonitor(ref, [:flush])
        {:fatal, reason}

      {:child_pi_bpmn_error, ^child_pid, error_info, _final_tokens} ->
        Process.demonitor(ref, [:flush])
        {:bpmn_error, error_info}

      {:child_pi_aborted, ^child_pid} ->
        Process.demonitor(ref, [:flush])
        :aborted

      {:DOWN, ^ref, :process, ^child_pid, :normal} ->
        {:finished, aggregate_from_persistence(child_process_instance_id)}

      {:DOWN, ^ref, :process, ^child_pid, reason} ->
        {:crashed, reason}
    end
  end

  # -- Private: result handling ----------------------------------------------

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
      {:error, reason} ->
        {:error, {:out_mapping_failed, reason}}
    end
  end

  defp apply_result(flow_node, _entry, context, final_tokens, child_process_instance_id) do
    {:ok, next_ids} = resolve_outgoing(flow_node, context)
    aggregated = aggregate_tokens(final_tokens)
    type_properties = %{child_process_instance_id: child_process_instance_id}

    with {:ok, output} <- apply_out_mappings(flow_node, aggregated, context),
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

  defp apply_out_mappings(flow_node, aggregated_payload, context) do
    MappingHelper.apply_out_mappings(
      flow_node.type_data.out_mappings,
      aggregated_payload,
      context
    )
  end

  # -- Private: error / boundary resolution ----------------------------------

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
        propagate_escalation_end(flow_node, context, escalation_info, child_process_instance_id)

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

  defp propagate_escalation_end(flow_node, context, escalation_info, child_process_instance_id) do
    type_properties = %{child_process_instance_id: child_process_instance_id}

    case FniLifecycle.finish(context, flow_node, nil, type_properties) do
      {:ok, lifecycle_result} ->
        {:escalation_end_propagate, escalation_info,
         %FlowNodeResult{
           output_payload: nil,
           next_flow_node_ids: [],
           type_properties: type_properties,
           metadata: %{persisted: true, lifecycle: lifecycle_result}
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_escalation_passthrough_in_await(
         escalation_info,
         flow_node,
         context,
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
        non_interrupting =
          EscalationResolver.find_non_interrupting_escalation_boundaries(
            flow_node,
            context.process_model,
            context.definitions,
            escalation_info
          )

        Enum.each(non_interrupting, fn boundary_node ->
          send(
            process_instance_pid,
            {:fni_result, context.flow_node_instance_id,
             {:boundary, boundary_node.id, escalation_info, false, triggerer_fni_id}}
          )
        end)

        if non_interrupting == [] do
          send(process_instance_pid, {:escalation_passthrough, escalation_info})
        end
    end
  end

  defp normalize_error(%{error_code: _} = reason), do: reason

  defp normalize_error(_reason) do
    %{error_code: @error_code_child_fatal, error_message: "Child process ended in a fatal state"}
  end

  # -- Private: input payload ------------------------------------------------

  defp resolve_input_payload(flow_node, token, context) do
    MappingHelper.apply_in_mappings(flow_node.type_data.in_mappings, token.payload, context)
  end

  # -- Private: routing ------------------------------------------------------

  defp resolve_outgoing(flow_node, context) do
    case SequenceFlowResolver.resolve(flow_node, context.process_model) do
      {:ok, targets} ->
        {:ok, Enum.map(targets, & &1.id)}

      {:error, reason, meta} ->
        {:error, Map.put(meta, :reason, reason)}
    end
  end

  defp resolve_called_version(called_element) do
    CalledElementResolver.adapter().resolve_latest_version(called_element)
  end

  # -- Private: resume helpers -----------------------------------------------

  defp query_child_state(_persistence, nil), do: :not_found

  defp query_child_state(_persistence, child_process_instance_id) do
    case EvilEngine.Execution.lookup_process_instance(child_process_instance_id) do
      {:ok, pid} -> {:running, pid}
      {:error, _} -> :not_found
    end
  end

  defp monitor_and_wait(flow_node, entry, context, child_pid, child_process_instance_id) do
    process_instance_pid = context.process_instance_pid
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

      {:fatal, reason} ->
        handle_child_error(flow_node, context, normalize_error(reason))

      {:bpmn_error, error_info} ->
        handle_child_bpmn_error(flow_node, context, error_info, child_process_instance_id)

      :aborted ->
        :abort_cascade

      {:crashed, _reason} ->
        error_info = %{
          error_code: @error_code_child_crash,
          error_message: "Child process crashed"
        }

        handle_child_error(flow_node, context, error_info)
    end
  end

  defp set_child_notify_pid(child_pid, handler_pid) do
    ProcessInstance.update_notify_pid(child_pid, handler_pid)
  catch
    :exit, _ -> :ok
  end

  defp run_fresh_lifecycle(flow_node, entry, context, _process_instance_pid) do
    called_element = flow_node.type_data.called_element
    process_instance_pid = context.process_instance_pid
    child_process_instance_id = generate_uuid_v7()

    with {:ok, next_ids} <- resolve_outgoing(flow_node, context),
         {:ok, resolved} <- resolve_called_version(called_element),
         {:ok, input_payload} <- resolve_input_payload(flow_node, entry.token, context) do
      case start_and_monitor_child(
             flow_node,
             context,
             resolved,
             input_payload,
             child_process_instance_id,
             process_instance_pid,
             flow_node.type_data.start_event_id
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
            error_message: "Child process crashed"
          }

          handle_child_error(flow_node, context, error_info)
      end
    else
      {:error, %{} = structured} ->
        {:error, structured}

      {:error, reason} ->
        {:error, {:called_element_resolution_failed, reason}}
    end
  end

  defp resume_existing_child(flow_node, entry, context, child_process_instance_id) do
    adapter = PersistenceAdapter.adapter()
    process_instance_pid = context.process_instance_pid

    case adapter.get_process_instance_for_retry(child_process_instance_id) do
      {:ok, %{state: "finished"}} ->
        final_tokens = aggregate_from_persistence(child_process_instance_id)
        apply_result(flow_node, entry, context, final_tokens, child_process_instance_id)

      {:ok, %{state: "escalated", error_info: escalation_error_info}} ->
        resume_from_escalated_child(
          flow_node,
          context,
          child_process_instance_id,
          escalation_error_info,
          process_instance_pid
        )

      {:ok, %{state: "fatal", error_info: error_info}} ->
        handle_child_error(flow_node, context, normalize_error(error_info || "CHILD_FATAL"))

      {:ok, %{state: "error", error_info: error_info}} ->
        resume_from_bpmn_error_child(flow_node, context, error_info, child_process_instance_id)

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
          monitor_and_wait(flow_node, entry, context, child_pid, child_process_instance_id)

        {:error, {:already_started, existing_pid}} ->
          monitor_and_wait(flow_node, entry, context, existing_pid, child_process_instance_id)

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
  # Cascade callbacks — propagate fatal/abort to child PIs
  # -------------------------------------------------------------------

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

  defp cascade_to_child(entry, action) do
    child_process_instance_id =
      get_child_process_instance_id(entry.type_properties)

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
  # Private helpers
  # -------------------------------------------------------------------

  defp maybe_put_start_event_id(opts, nil), do: opts

  defp maybe_put_start_event_id(opts, start_event_id),
    do: Map.put(opts, :start_event_id, start_event_id)

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

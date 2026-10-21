defmodule BfwEngine.Execution.FlowNodes.ChildLifecycle do
  @moduledoc """
  Shared child-PI lifecycle infrastructure for `CallActivity`, `SubProcess`,
  and `TransactionSubProcess` handlers.

  Contains the generic machinery for awaiting a child PI, processing its
  result (output mapping, contract validation, token aggregation), handling
  child errors and BPMN errors, resolving escalation boundaries, resuming
  after engine restart, and cascading fatal/abort signals.

  Each handler provides type-specific setup (start_opts construction,
  version resolution, subprocess validation) and delegates the shared
  lifecycle operations to this module.
  """

  alias BfwEngine.BPMN.Model.FlowNode
  alias BfwEngine.BPMN.ModelCache
  alias BfwEngine.Events.EngineEventBus
  alias BfwEngine.Execution.BoundaryResolver
  alias BfwEngine.Execution.EscalationResolver
  alias BfwEngine.Execution.FlowNodeResult
  alias BfwEngine.Execution.FniLifecycle
  alias BfwEngine.Execution.HandlerContext
  alias BfwEngine.Execution.MappingHelper
  alias BfwEngine.Execution.Persistence, as: PersistenceAdapter
  alias BfwEngine.Execution.PersistenceRetry
  alias BfwEngine.Execution.ProcessInstance
  alias BfwEngine.Execution.ProcessInstance.ErrorInfo
  alias BfwEngine.Execution.SequenceFlowResolver
  alias BfwEngine.Types.Event
  alias BfwEngine.Types.Token

  # ===================================================================
  # §A — Await child completion
  # ===================================================================

  @doc """
  Blocks the handler Task until the child PI sends a terminal message.

  Returns a tagged tuple describing the child outcome:
  - `{:finished, final_tokens}`
  - `{:fatal, reason}`
  - `{:bpmn_error, error_info}`
  - `{:escalation, escalation_info, final_tokens}`
  - `:aborted`
  - `{:crashed, reason}`

  Escalation passthroughs (non-terminal) are handled inline and the
  receive loop re-enters.

  The optional `extra_message_handler` callback receives the awaited
  child's `{:child_pi_cancelled, child_pid, final_tokens}` message and
  returns either `{:handled, result}` to break the loop or `:skip` to
  re-enter. This allows `TransactionSubProcess` to resolve its Cancel
  Boundary. Any other message stays in the mailbox.
  """
  @spec await_child_completion(
          pid(),
          reference(),
          String.t(),
          FlowNode.t(),
          HandlerContext.t(),
          pid(),
          (term() -> {:handled, term()} | :skip) | nil
        ) :: term()
  def await_child_completion(
        child_pid,
        ref,
        child_process_instance_id,
        flow_node,
        context,
        process_instance_pid,
        extra_message_handler \\ nil
      ) do
    receive do
      {:child_pi_finished, ^child_pid, final_tokens} ->
        Process.demonitor(ref, [:flush])
        {:finished, final_tokens}

      {:child_pi_compensated, ^child_pid, final_tokens} ->
        Process.demonitor(ref, [:flush])
        {:compensated, final_tokens}

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
          process_instance_pid,
          extra_message_handler
        )

      {:DOWN, ^ref, :process, ^child_pid, :normal} ->
        {:finished, aggregate_from_persistence(child_process_instance_id)}

      {:DOWN, ^ref, :process, ^child_pid, :noproc} ->
        noproc_outcome(child_pid, child_process_instance_id, extra_message_handler)

      {:DOWN, ^ref, :process, ^child_pid, reason} ->
        crashed_child_outcome(child_process_instance_id, reason, flow_node, context)

      {:child_pi_cancelled, ^child_pid, _final_tokens} = cancelled_message
      when is_function(extra_message_handler, 1) ->
        case extra_message_handler.(cancelled_message) do
          {:handled, result} ->
            Process.demonitor(ref, [:flush])
            result

          :skip ->
            await_child_completion(
              child_pid,
              ref,
              child_process_instance_id,
              flow_node,
              context,
              process_instance_pid,
              extra_message_handler
            )
        end
    end
  end

  @doc """
  Model cache id of a subprocess scope: the top-level process id, `__subprocess__`,
  and the subprocess node id. A subprocess nested in a subprocess runs under a
  context whose process model id is already a scope id, so only its top-level
  part is kept.
  """
  @spec subprocess_model_id(HandlerContext.t(), FlowNode.t()) :: String.t()
  def subprocess_model_id(context, flow_node) do
    top_level_process_id =
      context.process_model.id |> String.split("__subprocess__") |> hd()

    "#{top_level_process_id}__subprocess__#{flow_node.id}"
  end

  @doc """
  Outcome of a child PI that went down with an abnormal reason before it
  announced a terminal state (a crash its `terminate/3` could not record).
  A child row still `running` is persisted `fatal` with
  `process_instance_crashed`, together with its live FNIs, a
  `ProcessInstanceStateChanged` event, and its running descendants (force-fataled
  when alive, written fatal the same way when not). The shell gets
  `{:fatal, reason}`, which reaches Error Boundaries as `CHILD_FATAL`. A child
  stopped by an engine shutdown (`:shutdown`, `{:shutdown, _}`) keeps its row
  for resume and yields `{:crashed, reason}`.

  `shell_flow_node` (the awaiting shell) selects the child's model for the
  FNI events; `context` supplies the root process instance id.
  """
  @spec crashed_child_outcome(String.t(), term(), FlowNode.t() | nil, HandlerContext.t() | nil) ::
          {:fatal, {:process_instance_crashed, map()}} | {:crashed, term()}
  def crashed_child_outcome(child_process_instance_id, reason, shell_flow_node, context)

  def crashed_child_outcome(_child_process_instance_id, :shutdown, _shell_flow_node, _context),
    do: {:crashed, :shutdown}

  def crashed_child_outcome(
        _child_process_instance_id,
        {:shutdown, _detail} = reason,
        _shell_flow_node,
        _context
      ),
      do: {:crashed, reason}

  def crashed_child_outcome(child_process_instance_id, reason, shell_flow_node, context) do
    crash_reason = ErrorInfo.process_instance_crashed(child_process_instance_id, reason)
    root_process_instance_id = context && context.root_process_instance_id

    _ =
      case fetch_persisted_child(child_process_instance_id) do
        {:ok, %{state: "running"} = child} ->
          fatal_dead_instance(child, crash_reason, shell_flow_node, root_process_instance_id)

        _not_running ->
          :ok
      end

    {:fatal, crash_reason}
  end

  defp fatal_dead_instance(instance, crash_reason, shell_flow_node, root_process_instance_id) do
    persist_result =
      PersistenceRetry.with_retry(
        fn ->
          PersistenceAdapter.adapter().update_process_instance(instance.id, %{
            state: "fatal",
            finished_at: DateTime.utc_now(),
            error_info: ErrorInfo.build(crash_reason)
          })
        end,
        "crashed child PI fatal #{instance.id}"
      )

    with :ok <- persist_result do
      process_model = dead_instance_process_model(instance.process_version_id, shell_flow_node)

      flow_node_instances =
        fatal_live_flow_node_instances(
          instance.id,
          crash_reason,
          process_model,
          root_process_instance_id
        )

      emit_dead_instance_fatal(
        instance,
        process_model,
        flow_node_instances,
        root_process_instance_id
      )

      fatal_running_descendants(instance.id, process_model, root_process_instance_id)
    end
  end

  defp dead_instance_process_model(process_version_id, %FlowNode{type: :sub_process, id: node_id}) do
    case ModelCache.fetch_subprocess_model(process_version_id, node_id) do
      {:ok, process_model, _definitions} -> process_model
      _error -> nil
    end
  end

  defp dead_instance_process_model(process_version_id, %FlowNode{
         type: :call_activity,
         type_data: %{called_element: called_element}
       }) do
    case ModelCache.fetch(process_version_id) do
      {:ok, definitions} -> Enum.find(definitions.processes, &(&1.id == called_element))
      _error -> nil
    end
  end

  defp dead_instance_process_model(_process_version_id, _shell_flow_node), do: nil

  defp fatal_live_flow_node_instances(
         process_instance_id,
         crash_reason,
         process_model,
         root_process_instance_id
       ) do
    case PersistenceAdapter.adapter().list_flow_node_instances(process_instance_id) do
      {:ok, flow_node_instances} ->
        flow_node_instances
        |> Enum.filter(&(to_string(&1.state) in ["active", "waiting"]))
        |> Enum.each(fn flow_node_instance ->
          FniLifecycle.transition_to_fatal(
            flow_node_instance.id,
            process_instance_id,
            crash_reason,
            find_model_flow_node(process_model, flow_node_instance.flow_node_id),
            flow_node_instance.type_properties || %{},
            flow_node_instance.lane_name,
            root_process_instance_id
          )
        end)

        flow_node_instances

      {:error, _reason} ->
        []
    end
  end

  defp find_model_flow_node(nil, _flow_node_id), do: nil

  defp find_model_flow_node(process_model, flow_node_id),
    do: Enum.find(process_model.flow_nodes, &(&1.id == flow_node_id))

  defp emit_dead_instance_fatal(
         instance,
         process_model,
         flow_node_instances,
         root_process_instance_id
       ) do
    lane_names = Enum.map(flow_node_instances, & &1.lane_name)

    EngineEventBus.publish(%Event.ProcessInstanceStateChanged{
      process_instance_id: instance.id,
      process_model_id: process_model && process_model.id,
      version: process_model && process_model.version,
      parent_process_instance_id: instance.parent_process_instance_id,
      root_process_instance_id: root_process_instance_id,
      triggerer_flow_node_instance_id: instance.triggerer_flow_node_instance_id,
      old_state: :running,
      new_state: :fatal,
      started_by_id: get_in(instance.started_by || %{}, ["id"]),
      has_laneless_flow_node: Enum.any?(lane_names, &is_nil/1),
      lane_names: lane_names |> Enum.reject(&is_nil/1) |> Enum.uniq() |> Enum.sort(),
      occurred_at: DateTime.utc_now()
    })
  end

  # A descendant of a killed instance outlives it: its awaiting handler Task
  # died with the killed instance's Task.Supervisor.
  defp fatal_running_descendants(process_instance_id, process_model, root_process_instance_id) do
    case PersistenceAdapter.adapter().list_child_process_instances(process_instance_id) do
      {:ok, children} ->
        children
        |> Enum.filter(&(&1.state == "running"))
        |> Enum.each(&fatal_running_descendant(&1, process_model, root_process_instance_id))

      {:error, _reason} ->
        :ok
    end
  end

  defp fatal_running_descendant(child, process_model, root_process_instance_id) do
    case BfwEngine.Execution.lookup_process_instance(child.id) do
      {:ok, child_pid} ->
        force_fatal_descendant(child_pid)

      {:error, :not_found} ->
        with {:ok, %{state: "running"} = instance} <- fetch_persisted_child(child.id) do
          fatal_dead_instance(
            instance,
            ErrorInfo.process_instance_crashed(child.id, :parent_crashed),
            descendant_shell_flow_node(child, process_model),
            root_process_instance_id
          )
        end
    end
  end

  defp force_fatal_descendant(child_pid) do
    ProcessInstance.force_fatal(child_pid, %{reason: "parent_fatal"})
  catch
    :exit, _reason -> :ok
  end

  defp descendant_shell_flow_node(%{triggerer_flow_node_instance_id: nil}, _process_model),
    do: nil

  defp descendant_shell_flow_node(child, process_model) do
    case PersistenceAdapter.adapter().get_flow_node_instance_by_id(
           child.triggerer_flow_node_instance_id
         ) do
      {:ok, shell} -> find_model_flow_node(process_model, shell.flow_node_id)
      _error -> nil
    end
  end

  # Only the transaction shell's extra message handler understands a cancelled child.
  defp noproc_outcome(child_pid, child_process_instance_id, extra_message_handler)
       when is_function(extra_message_handler, 1) do
    lookup_result = fetch_persisted_child(child_process_instance_id)

    with {:ok, %{state: "cancelled"}} <- lookup_result,
         {:handled, result} <-
           extra_message_handler.(
             {:child_pi_cancelled, child_pid,
              aggregate_from_persistence(child_process_instance_id)}
           ) do
      result
    else
      _not_cancelled -> outcome_from_lookup(lookup_result, child_process_instance_id)
    end
  end

  defp noproc_outcome(_child_pid, child_process_instance_id, _extra_message_handler),
    do: persisted_child_outcome(child_process_instance_id)

  @doc """
  Reads a child PI's persisted row, retrying transient database errors.
  Returns `{:ok, child_pi_data}`, `{:error, :not_found}` when no row exists
  (answered on the first attempt), or `{:error, reason}` when the database
  stays unavailable. A shell must never treat `{:error, reason}` as a missing
  child: spawning a fresh one would run the child twice.
  """
  @spec fetch_persisted_child(String.t()) ::
          {:ok, map()} | {:error, :not_found} | {:error, term()}
  def fetch_persisted_child(child_process_instance_id) do
    PersistenceRetry.with_retry(
      fn ->
        PersistenceAdapter.adapter().get_process_instance_for_retry(child_process_instance_id)
      end,
      "child PI lookup #{child_process_instance_id}",
      final_reasons: [:not_found]
    )
  end

  @doc """
  Maps a child PI's persisted terminal state to the tagged outcome
  `await_child_completion/7` returns. Used when the child is no longer
  alive to send its terminal message (it finished before it was
  monitored). A child whose row is still `running`, or that ended
  `cancelled`, yields `{:crashed, :noproc}`; `await_child_completion/7`
  replays a `cancelled` child to its extra message handler first. A child
  row that cannot be read yields `{:crashed, {:child_lookup_failed, reason}}`.
  """
  @spec persisted_child_outcome(String.t()) ::
          :aborted
          | {:bpmn_error, %{error_code: term(), error_message: term()}}
          | {:compensated, [map()]}
          | {:crashed, :noproc | {:child_lookup_failed, term()}}
          | {:fatal, term()}
          | {:finished, [map()]}
          | {:escalation, %{escalation_code: term(), escalation_name: term()}, [map()]}
  def persisted_child_outcome(child_process_instance_id) do
    child_process_instance_id
    |> fetch_persisted_child()
    |> outcome_from_lookup(child_process_instance_id)
  end

  defp outcome_from_lookup({:ok, child_pi_data}, child_process_instance_id),
    do: child_outcome(child_pi_data, child_process_instance_id)

  defp outcome_from_lookup({:error, :not_found}, _child_process_instance_id),
    do: {:crashed, :noproc}

  defp outcome_from_lookup({:error, reason}, _child_process_instance_id),
    do: {:crashed, {:child_lookup_failed, reason}}

  defp child_outcome(%{state: "finished"}, child_process_instance_id),
    do: {:finished, aggregate_from_persistence(child_process_instance_id)}

  defp child_outcome(%{state: "compensated"}, child_process_instance_id),
    do: {:compensated, aggregate_from_persistence(child_process_instance_id)}

  defp child_outcome(%{state: "fatal", error_info: error_info}, _child_process_instance_id),
    do: {:fatal, error_info || "CHILD_FATAL"}

  defp child_outcome(%{state: "error", error_info: error_info}, _child_process_instance_id),
    do: {:bpmn_error, live_error_info(error_info)}

  defp child_outcome(%{state: "escalated", error_info: error_info}, child_process_instance_id) do
    {:escalation, persisted_escalation_info(error_info),
     aggregate_from_persistence(child_process_instance_id)}
  end

  defp child_outcome(%{state: "aborted"}, _child_process_instance_id), do: :aborted
  defp child_outcome(_child_pi_data, _child_process_instance_id), do: {:crashed, :noproc}

  defp persisted_escalation_info(%{} = error_info) do
    %{escalation_code: error_info["error_code"], escalation_name: error_info["message"]}
  end

  defp persisted_escalation_info(_error_info), do: %{escalation_code: nil, escalation_name: nil}

  @doc """
  Turns the persisted `error_info` of a child in state `error` into the live
  `%{error_code:, error_message:}` shape that Error Boundary and Error Event
  Subprocess matching reads. The raised values are taken from `detail` (the
  live map as JSON), because the top-level `error_code` defaults to
  `bpmn_error` when the Error End Event raised no code.
  """
  @spec live_error_info(map() | nil) :: %{error_code: term(), error_message: term()}
  def live_error_info(%{error_code: _} = error_info), do: error_info

  def live_error_info(%{"detail" => %{"error_code" => error_code} = detail}),
    do: %{error_code: error_code, error_message: detail["error_message"]}

  def live_error_info(%{} = error_info),
    do: %{error_code: error_info["error_code"], error_message: error_info["message"]}

  def live_error_info(_error_info), do: %{error_code: nil, error_message: nil}

  # ===================================================================
  # §B — Result processing
  # ===================================================================

  @spec apply_out_mappings_to_result(
          FlowNode.t(),
          HandlerContext.t(),
          term(),
          [String.t()],
          String.t()
        ) ::
          {:ok, FlowNodeResult.t()} | {:error, term()}
  defp apply_out_mappings_to_result(
         flow_node,
         context,
         final_tokens,
         next_ids,
         child_process_instance_id
       ) do
    aggregated = aggregate_tokens(final_tokens)
    type_properties = %{child_process_instance_id: child_process_instance_id}
    result_contract = Map.get(flow_node.type_data, :result_contract, nil)

    with {:ok, output} <- apply_out_mappings(flow_node, aggregated, context),
         :ok <-
           MappingHelper.validate_contract(result_contract, output, :result_contract_violation),
         {:ok, lifecycle_result} <-
           FniLifecycle.finish(context, flow_node, output, type_properties) do
      {:ok,
       %FlowNodeResult{
         output_payload: output,
         next_flow_node_ids: next_ids,
         type_properties: type_properties,
         metadata: %{persisted: true, lifecycle: lifecycle_result}
       }}
    end
  end

  @spec apply_result(FlowNode.t(), term(), HandlerContext.t(), term(), String.t()) ::
          {:ok, FlowNodeResult.t()} | {:error, term()}
  defp apply_result(flow_node, _entry, context, final_tokens, child_process_instance_id) do
    with {:ok, next_ids} <- resolve_outgoing(flow_node, context) do
      apply_out_mappings_to_result(
        flow_node,
        context,
        final_tokens,
        next_ids,
        child_process_instance_id
      )
    end
  end

  # ===================================================================
  # §C — Token aggregation
  # ===================================================================

  @doc "Merges a list of end-event tokens into a single payload map."
  @spec aggregate_tokens(term()) :: map()
  def aggregate_tokens(final_tokens) when is_list(final_tokens) do
    Enum.reduce(final_tokens, %{}, fn token, acc ->
      case token do
        %{payload: payload} when is_map(payload) -> Map.merge(acc, payload)
        _ -> acc
      end
    end)
  end

  def aggregate_tokens(payload) when is_map(payload), do: payload
  def aggregate_tokens(_), do: %{}

  # ===================================================================
  # §D — Error / boundary resolution
  # ===================================================================

  @spec handle_child_error(FlowNode.t(), HandlerContext.t(), map()) ::
          {:boundary, String.t(), map(), boolean()} | {:error, map()}
  defp handle_child_error(flow_node, context, error_info) do
    case BoundaryResolver.find_matching_error_boundary(
           flow_node,
           context.process_model,
           context.definitions,
           error_info
         ) do
      {:ok, boundary_node} ->
        cancel = Map.get(boundary_node.type_data, :cancel_activity, true)
        {:boundary, boundary_node.id, error_info, cancel}

      :none ->
        {:error, error_info}
    end
  end

  @spec handle_child_bpmn_error(FlowNode.t(), HandlerContext.t(), map(), String.t()) :: term()
  defp handle_child_bpmn_error(flow_node, context, error_info, child_process_instance_id) do
    case handle_child_error(flow_node, context, error_info) do
      {:boundary, _, _, _} = boundary_result ->
        boundary_result

      {:error, _} ->
        propagate_bpmn_error(flow_node, context, error_info, child_process_instance_id)
    end
  end

  @spec propagate_bpmn_error(FlowNode.t(), HandlerContext.t(), map(), String.t()) :: term()
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

  @spec normalize_error(term(), String.t()) :: map()
  defp normalize_error(%{error_code: _} = reason, _default_message), do: reason

  defp normalize_error(_reason, default_message) do
    %{error_code: "CHILD_FATAL", error_message: default_message}
  end

  # ===================================================================
  # §E — Escalation handling
  # ===================================================================

  @spec handle_child_escalation_end(
          FlowNode.t(),
          HandlerContext.t(),
          map(),
          term(),
          String.t(),
          pid()
        ) :: term()
  defp handle_child_escalation_end(
         flow_node,
         context,
         escalation_info,
         final_tokens,
         child_process_instance_id,
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
        {:boundary, boundary_node.id, escalation_info, true, triggerer_fni_id}

      :none ->
        apply_non_interrupting_escalation_end(
          flow_node,
          context,
          escalation_info,
          final_tokens,
          child_process_instance_id,
          process_instance_pid
        )
    end
  end

  defp apply_non_interrupting_escalation_end(
         flow_node,
         context,
         escalation_info,
         final_tokens,
         child_process_instance_id,
         process_instance_pid
       ) do
    boundaries =
      EscalationResolver.find_non_interrupting_escalation_boundaries(
        flow_node,
        context.process_model,
        context.definitions,
        escalation_info
      )

    case boundaries do
      [] ->
        propagate_escalation_end(
          flow_node,
          context,
          escalation_info,
          child_process_instance_id,
          final_tokens
        )

      non_interrupting ->
        with {:ok, next_ids} <- resolve_outgoing(flow_node, context) do
          signal_non_interrupting_boundaries(
            non_interrupting,
            context,
            escalation_info,
            process_instance_pid
          )

          apply_out_mappings_to_result(
            flow_node,
            context,
            final_tokens,
            next_ids,
            child_process_instance_id
          )
        end
    end
  end

  defp signal_non_interrupting_boundaries(
         boundary_nodes,
         context,
         escalation_info,
         process_instance_pid
       ) do
    triggerer_fni_id = escalation_info[:triggerer_flow_node_instance_id]

    Enum.each(boundary_nodes, fn boundary_node ->
      send(
        process_instance_pid,
        {:fni_result, context.flow_node_instance_id,
         {:boundary, boundary_node.id, escalation_info, false, triggerer_fni_id}}
      )
    end)
  end

  defp propagate_escalation_end(
         flow_node,
         context,
         escalation_info,
         child_process_instance_id,
         final_tokens
       ) do
    type_properties = %{child_process_instance_id: child_process_instance_id}
    output_payload = output_payload_from_final_tokens(final_tokens)

    case FniLifecycle.finish(context, flow_node, output_payload, type_properties) do
      {:ok, lifecycle_result} ->
        {:escalation_end_propagate, escalation_info,
         %FlowNodeResult{
           output_payload: output_payload,
           next_flow_node_ids: [],
           type_properties: type_properties,
           metadata: %{persisted: true, lifecycle: lifecycle_result}
         }}

      {:error, _reason} ->
        {:error,
         %{
           error_code: "escalation_persist_failed",
           message: "Failed to finish FNI during escalation propagation"
         }}
    end
  end

  defp resume_from_escalated_child(
         flow_node,
         context,
         child_process_instance_id,
         escalation_error_info,
         process_instance_pid
       ) do
    escalation_info = persisted_escalation_info(escalation_error_info)
    final_tokens = aggregate_from_persistence(child_process_instance_id)

    handle_child_escalation_end(
      flow_node,
      context,
      escalation_info,
      final_tokens,
      child_process_instance_id,
      process_instance_pid
    )
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

  # ===================================================================
  # §F — Resume helpers
  # ===================================================================

  @doc "Looks up a child PI in the process registry."
  @spec query_child_state(String.t() | nil) :: {:running, pid()} | :not_found
  def query_child_state(nil), do: :not_found

  def query_child_state(child_process_instance_id) do
    case BfwEngine.Execution.lookup_process_instance(child_process_instance_id) do
      {:ok, pid} -> {:running, pid}
      {:error, _} -> :not_found
    end
  end

  @doc """
  Re-monitors a running child PI, awaits its result, and dispatches
  the outcome through the standard result handling pipeline.

  `child_label` is used for error messages (e.g. "Child process",
  "Subprocess child process").
  """
  @spec monitor_and_wait(
          FlowNode.t(),
          map(),
          HandlerContext.t(),
          pid(),
          String.t(),
          pid(),
          String.t(),
          (term() -> {:handled, term()} | :skip) | nil
        ) ::
          :abort_cascade
          | {:error, term()}
          | {:ok, FlowNodeResult.t()}
          | {:bpmn_error, map(), FlowNodeResult.t()}
          | {:escalation_end_propagate, map(), FlowNodeResult.t()}
          | {:boundary, String.t(), map(), boolean()}
          | {:boundary, String.t(), map(), true, term()}
  def monitor_and_wait(
        flow_node,
        entry,
        context,
        child_pid,
        child_process_instance_id,
        process_instance_pid,
        child_label,
        extra_message_handler \\ nil
      ) do
    set_child_notify_pid(child_pid, self())
    ref = Process.monitor(child_pid)
    send(process_instance_pid, {:resume_settled, context.flow_node_instance_id})

    result =
      await_child_completion(
        child_pid,
        ref,
        child_process_instance_id,
        flow_node,
        context,
        process_instance_pid,
        extra_message_handler
      )

    dispatch_await_result(
      result,
      flow_node,
      entry,
      context,
      child_process_instance_id,
      process_instance_pid,
      child_label
    )
  end

  @spec dispatch_await_result(
          term(),
          FlowNode.t(),
          map(),
          HandlerContext.t(),
          String.t(),
          pid(),
          String.t()
        ) ::
          term()
  defp dispatch_await_result(
         result,
         flow_node,
         entry,
         context,
         child_process_instance_id,
         process_instance_pid,
         child_label
       ) do
    case result do
      {:finished, final_tokens} ->
        apply_result(flow_node, entry, context, final_tokens, child_process_instance_id)

      {:compensated, final_tokens} ->
        apply_result(flow_node, entry, context, final_tokens, child_process_instance_id)

      {:escalation, escalation_info, final_tokens} ->
        handle_child_escalation_end(
          flow_node,
          context,
          escalation_info,
          final_tokens,
          child_process_instance_id,
          process_instance_pid
        )

      {:fatal, reason} ->
        handle_child_error(
          flow_node,
          context,
          normalize_error(reason, "#{child_label} ended in a fatal state")
        )

      {:bpmn_error, error_info} ->
        handle_child_bpmn_error(flow_node, context, error_info, child_process_instance_id)

      :aborted ->
        :abort_cascade

      {:crashed, _reason} ->
        error_info = %{
          error_code: "CHILD_CRASH",
          error_message: "#{child_label} crashed"
        }

        handle_child_error(flow_node, context, error_info)
    end
  end

  @doc """
  Dispatches the tagged result from `await_child_completion` when
  `next_ids` is already known (used on the enter and fresh-lifecycle paths).
  """
  @spec dispatch_enter_result(
          term(),
          FlowNode.t(),
          HandlerContext.t(),
          String.t(),
          pid(),
          [String.t()],
          String.t()
        ) ::
          term()
  def dispatch_enter_result(
        result,
        flow_node,
        context,
        child_process_instance_id,
        process_instance_pid,
        next_ids,
        child_label
      ) do
    case result do
      {:finished, final_tokens} ->
        apply_out_mappings_to_result(
          flow_node,
          context,
          final_tokens,
          next_ids,
          child_process_instance_id
        )

      {:compensated, final_tokens} ->
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
          process_instance_pid
        )

      {:fatal, reason} ->
        handle_child_error(
          flow_node,
          context,
          normalize_error(reason, "#{child_label} ended in a fatal state")
        )

      {:bpmn_error, error_info} ->
        handle_child_bpmn_error(flow_node, context, error_info, child_process_instance_id)

      :aborted ->
        :abort_cascade

      {:crashed, _reason} ->
        error_info = %{
          error_code: "CHILD_CRASH",
          error_message: "#{child_label} crashed"
        }

        handle_child_error(flow_node, context, error_info)
    end
  end

  @doc """
  Resumes a child PI from persistence when it is not currently running
  in memory. Checks the child's persisted state and routes accordingly.

  `opts` supports:
  - `:extra_terminal_states` — map from state string to handler function
    `(flow_node, entry, context, child_pi_data) -> result`. Allows
    `TransactionSubProcess` to handle `"cancelled"` without modifying
    this module.
  - `:child_label` — for error messages
  - `:extra_resume_opts` — map merged into child resume opts
  - `:fresh_lifecycle_fn` — fallback when child PI is not found
  - `:extra_message_handler` — callback for `await_child_completion`
  """
  @spec resume_existing_child(
          FlowNode.t(),
          map(),
          HandlerContext.t(),
          String.t(),
          keyword()
        ) :: term()
  def resume_existing_child(
        flow_node,
        entry,
        context,
        child_process_instance_id,
        opts \\ []
      ) do
    case fetch_persisted_child(child_process_instance_id) do
      {:ok, child_pi_data} ->
        dispatch_persisted_child_state(
          child_pi_data,
          flow_node,
          entry,
          context,
          child_process_instance_id,
          PersistenceAdapter.adapter(),
          opts
        )

      {:error, :not_found} ->
        handle_child_not_found(flow_node, entry, context, child_process_instance_id, opts)

      {:error, reason} ->
        child_resume_failed(context, child_process_instance_id, reason)
    end
  end

  @doc """
  Ends a resumed shell whose child row could not be read: reports the resume
  settled and returns `{:error, {:child_resume_failed, detail}}`, which
  fatals the shell instead of spawning a second child.
  """
  @spec child_resume_failed(HandlerContext.t(), String.t(), term()) :: {:error, term()}
  def child_resume_failed(context, child_process_instance_id, reason) do
    send(context.process_instance_pid, {:resume_settled, context.flow_node_instance_id})

    {:error,
     {:child_resume_failed,
      %{child_process_instance_id: child_process_instance_id, reason: reason}}}
  end

  defp dispatch_persisted_child_state(
         %{state: "finished"},
         flow_node,
         entry,
         context,
         child_process_instance_id,
         _adapter,
         _opts
       ) do
    final_tokens = aggregate_from_persistence(child_process_instance_id)
    apply_result(flow_node, entry, context, final_tokens, child_process_instance_id)
  end

  defp dispatch_persisted_child_state(
         %{state: "compensated"},
         flow_node,
         entry,
         context,
         child_process_instance_id,
         _adapter,
         _opts
       ) do
    final_tokens = aggregate_from_persistence(child_process_instance_id)
    apply_result(flow_node, entry, context, final_tokens, child_process_instance_id)
  end

  defp dispatch_persisted_child_state(
         %{state: "fatal", error_info: error_info},
         flow_node,
         _entry,
         context,
         _child_process_instance_id,
         _adapter,
         opts
       ) do
    child_label = Keyword.get(opts, :child_label, "Child process")

    handle_child_error(
      flow_node,
      context,
      normalize_error(error_info || "CHILD_FATAL", "#{child_label} ended in a fatal state")
    )
  end

  defp dispatch_persisted_child_state(
         %{state: "error", error_info: error_info},
         flow_node,
         _entry,
         context,
         child_process_instance_id,
         _adapter,
         _opts
       ) do
    resume_from_bpmn_error_child(flow_node, context, error_info, child_process_instance_id)
  end

  defp dispatch_persisted_child_state(
         %{state: "escalated", error_info: escalation_error_info},
         flow_node,
         _entry,
         context,
         child_process_instance_id,
         _adapter,
         _opts
       ) do
    resume_from_escalated_child(
      flow_node,
      context,
      child_process_instance_id,
      escalation_error_info,
      context.process_instance_pid
    )
  end

  defp dispatch_persisted_child_state(
         %{state: "aborted"},
         _flow_node,
         _entry,
         _context,
         _child_process_instance_id,
         _adapter,
         _opts
       ) do
    :abort_cascade
  end

  defp dispatch_persisted_child_state(
         %{state: state} = child_pi_data,
         flow_node,
         entry,
         context,
         child_process_instance_id,
         adapter,
         opts
       ) do
    extra_terminal_states = Keyword.get(opts, :extra_terminal_states, %{})

    if handler = Map.get(extra_terminal_states, state) do
      handler.(flow_node, entry, context, child_pi_data)
    else
      start_child_from_persistence(
        flow_node,
        entry,
        context,
        child_process_instance_id,
        child_pi_data,
        adapter,
        child_label: Keyword.get(opts, :child_label, "Child process"),
        extra_resume_opts: Keyword.get(opts, :extra_resume_opts, %{}),
        extra_message_handler: Keyword.get(opts, :extra_message_handler)
      )
    end
  end

  defp handle_child_not_found(flow_node, entry, context, child_process_instance_id, opts) do
    fresh_lifecycle_fn = Keyword.get(opts, :fresh_lifecycle_fn)
    send(context.process_instance_pid, {:resume_settled, context.flow_node_instance_id})

    if fresh_lifecycle_fn do
      fresh_lifecycle_fn.(flow_node, entry, context, context.process_instance_pid)
    else
      {:error,
       %{
         error_code: "child_not_found",
         message:
           "Child PI #{child_process_instance_id} not found in persistence and no fresh lifecycle available"
       }}
    end
  end

  defp resume_from_bpmn_error_child(flow_node, context, error_info, child_process_instance_id) do
    handle_child_bpmn_error(
      flow_node,
      context,
      live_error_info(error_info),
      child_process_instance_id
    )
  end

  @spec start_child_from_persistence(
          FlowNode.t(),
          map(),
          HandlerContext.t(),
          String.t(),
          map(),
          module(),
          keyword()
        ) :: term()
  defp start_child_from_persistence(
         flow_node,
         entry,
         context,
         child_process_instance_id,
         child_pi_data,
         adapter,
         opts
       ) do
    child_label = Keyword.get(opts, :child_label, "Child process")
    extra_resume_opts = Keyword.get(opts, :extra_resume_opts, %{})

    case start_persisted_child(
           context,
           child_process_instance_id,
           child_pi_data,
           adapter,
           extra_resume_opts
         ) do
      {:ok, child_pid} ->
        monitor_and_wait(
          flow_node,
          entry,
          context,
          child_pid,
          child_process_instance_id,
          context.process_instance_pid,
          child_label,
          Keyword.get(opts, :extra_message_handler)
        )

      {:error, _error_info} = error ->
        error
    end
  end

  @doc """
  Starts a child PI from its persisted rows (resume) with the calling
  handler Task as its `notify_pid`. The child inherits the parent scope's
  `root_process_instance_id`, which is not persisted. `extra_resume_opts`
  is merged into the resume options (e.g. `subprocess_node_id`, `mode`).

  Returns `{:ok, child_pid}` (also when the child is already running) or
  `{:error, error_info}`.
  """
  @spec start_persisted_child(HandlerContext.t(), String.t(), map(), module(), map()) ::
          {:ok, pid()} | {:error, map()}
  def start_persisted_child(
        context,
        child_process_instance_id,
        child_pi_data,
        adapter,
        extra_resume_opts
      ) do
    with {:ok, child_fnis} <- adapter.list_all_flow_node_instances(child_process_instance_id),
         {:ok, pending_arrivals} <-
           adapter.list_gateway_pending_arrivals(child_process_instance_id) do
      child_resume_opts =
        %{
          resume: true,
          process_instance_id: child_process_instance_id,
          process_version_id: child_pi_data.process_version_id,
          business_key: child_pi_data.business_key,
          parent_process_instance_id: child_pi_data.parent_process_instance_id,
          root_process_instance_id: context.root_process_instance_id,
          triggerer_flow_node_instance_id: child_pi_data.triggerer_flow_node_instance_id,
          started_at: child_pi_data.started_at,
          started_by: child_pi_data.started_by,
          started_with_context: child_pi_data.started_with_context,
          notify_pid: self(),
          fni_data: child_fnis,
          pending_arrivals: pending_arrivals
        }
        |> Map.merge(extra_resume_opts)

      case DynamicSupervisor.start_child(
             BfwEngine.Execution.Supervisor,
             {ProcessInstance, child_resume_opts}
           ) do
        {:ok, child_pid} ->
          {:ok, child_pid}

        {:error, {:already_started, existing_pid}} ->
          {:ok, existing_pid}

        {:error, reason} ->
          {:error,
           %{
             error_code: "child_resume_failed",
             message: "Failed to resume child PI #{child_process_instance_id}: #{inspect(reason)}"
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

  @doc """
  Records the id of a child PI that a resumed shell spawns afresh: patches
  the shell FNI's persisted `type_properties` and the process instance's
  in-memory entry, so later fatal, abort, and terminate cascades reach the
  new child instead of the id the shell carried before.

  Called before the child is started. When the patch still fails after
  `PersistenceRetry`, the child is never started: the shell reports its
  resume settled and returns `{:error, {:child_record_failed, detail}}`,
  which fatals it.
  """
  @spec record_fresh_child(HandlerContext.t(), String.t()) :: :ok | {:error, term()}
  def record_fresh_child(context, child_process_instance_id) do
    patch_result =
      PersistenceRetry.with_retry(
        fn ->
          PersistenceAdapter.adapter().patch_fni_type_properties(
            context.flow_node_instance_id,
            %{"child_process_instance_id" => child_process_instance_id}
          )
        end,
        "FNI record fresh child #{context.flow_node_instance_id}"
      )

    case patch_result do
      :ok ->
        merge_fresh_child(context, child_process_instance_id)

      {:error, reason} ->
        send(context.process_instance_pid, {:resume_settled, context.flow_node_instance_id})

        {:error,
         {:child_record_failed,
          %{child_process_instance_id: child_process_instance_id, reason: reason}}}
    end
  end

  defp merge_fresh_child(context, child_process_instance_id) do
    send(
      context.process_instance_pid,
      {:fni_merge_type_properties, context.flow_node_instance_id,
       %{
         :child_process_instance_id => child_process_instance_id,
         "child_process_instance_id" => child_process_instance_id
       }}
    )

    :ok
  end

  @spec aggregate_from_persistence(String.t()) :: [map()]
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

  # ===================================================================
  # §G — Cascade callbacks
  # ===================================================================

  @doc """
  Propagates a fatal or abort signal to a child PI. Looks up the child
  by its persisted ID and invokes the given action callback.
  """
  @spec cascade_to_child(map(), (pid() -> term())) :: term()
  def cascade_to_child(entry, action) do
    child_process_instance_id = get_child_process_instance_id(entry.type_properties)

    if is_binary(child_process_instance_id) do
      case BfwEngine.Execution.lookup_process_instance(child_process_instance_id) do
        {:ok, child_pid} -> action.(child_pid)
        {:error, :not_found} -> :ok
      end
    else
      :ok
    end
  catch
    :exit, _ -> :ok
  end

  @spec get_child_process_instance_id(map() | nil) :: String.t() | nil
  defp get_child_process_instance_id(nil), do: nil

  defp get_child_process_instance_id(type_properties) do
    type_properties[:child_process_instance_id] ||
      type_properties["child_process_instance_id"]
  end

  # ===================================================================
  # §H — Mapping and contract helpers
  # ===================================================================

  @doc "Applies input mappings to transform the incoming token payload."
  @spec resolve_input_payload(FlowNode.t(), Token.t(), HandlerContext.t()) ::
          {:ok, map()} | {:error, term()}
  def resolve_input_payload(flow_node, token, context) do
    MappingHelper.apply_in_mappings(flow_node.type_data.in_mappings, token.payload, context)
  end

  @spec apply_out_mappings(FlowNode.t(), map(), HandlerContext.t()) ::
          {:ok, map()} | {:error, term()}
  defp apply_out_mappings(flow_node, aggregated_payload, context) do
    MappingHelper.apply_out_mappings(
      flow_node.type_data.out_mappings,
      aggregated_payload,
      context
    )
  end

  @doc "Validates the subprocess input against `bfw:payloadContract`."
  @spec validate_payload_contract(map() | nil, map()) ::
          :ok | {:error, {:payload_contract_violation, term()}}
  def validate_payload_contract(contract, data) do
    MappingHelper.validate_contract(contract, data, :payload_contract_violation)
  end

  @doc "Resolves outgoing sequence flow IDs for the handler's flow node."
  @spec resolve_outgoing(FlowNode.t(), HandlerContext.t()) ::
          {:ok, [String.t()]} | {:error, term()}
  def resolve_outgoing(flow_node, context) do
    case SequenceFlowResolver.resolve(flow_node, context.process_model) do
      {:ok, targets} ->
        {:ok, Enum.map(targets, & &1.id)}

      {:error, reason, meta} ->
        {:error, Map.put(meta, :reason, reason)}
    end
  end

  # ===================================================================
  # §I — Misc helpers
  # ===================================================================

  defp output_payload_from_final_tokens(final_tokens) when is_list(final_tokens) do
    payload =
      Enum.find_value(final_tokens, fn
        %{payload: payload} when is_map(payload) -> payload
        _other -> nil
      end)

    payload || %{}
  end

  defp output_payload_from_final_tokens(_final_tokens), do: %{}

  @spec set_child_notify_pid(pid(), pid()) :: :ok
  defp set_child_notify_pid(child_pid, handler_pid) do
    ProcessInstance.update_notify_pid(child_pid, handler_pid)
  catch
    :exit, _ -> :ok
  end
end

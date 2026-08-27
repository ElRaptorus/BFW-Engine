defmodule EvilEngine.Execution.FlowNodes.ChildLifecycle do
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

  alias EvilEngine.BPMN.Model.FlowNode
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

  The optional `extra_message_handler` callback receives the raw message
  and returns either `{:handled, result}` to break the loop or `:skip`
  to re-enter. This allows `TransactionSubProcess` to intercept
  `{:child_pi_cancelled, ...}` without modifying this module.
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

      {:DOWN, ^ref, :process, ^child_pid, reason} ->
        {:crashed, reason}

      other_message when is_function(extra_message_handler, 1) ->
        case extra_message_handler.(other_message) do
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

  # ===================================================================
  # §B — Result processing
  # ===================================================================

  @doc """
  Processes a successful child completion: aggregates tokens, applies
  out-mappings, validates result contract, finishes the FNI, and
  returns `{:ok, FlowNodeResult.t()}`.

  Used on the enter path when `next_ids` is already resolved.
  """
  @spec apply_out_mappings_to_result(
          FlowNode.t(),
          HandlerContext.t(),
          term(),
          [String.t()],
          String.t()
        ) ::
          {:ok, FlowNodeResult.t()} | {:error, term()}
  def apply_out_mappings_to_result(
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
         :ok <- validate_contract(result_contract, output),
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

  @doc """
  Processes a successful child completion on the resume path.

  Resolves outgoing sequence flows internally (unlike
  `apply_out_mappings_to_result/5` which receives them as input).
  """
  @spec apply_result(FlowNode.t(), term(), HandlerContext.t(), term(), String.t()) ::
          {:ok, FlowNodeResult.t()} | {:error, term()}
  def apply_result(flow_node, _entry, context, final_tokens, child_process_instance_id) do
    {:ok, next_ids} = resolve_outgoing(flow_node, context)

    apply_out_mappings_to_result(
      flow_node,
      context,
      final_tokens,
      next_ids,
      child_process_instance_id
    )
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

  @doc """
  Attempts to match a child error against an error boundary on the
  handler's flow node. Returns `{:boundary, ...}` if matched, or
  `{:error, error_info}` if no boundary catches it.
  """
  @spec handle_child_error(FlowNode.t(), HandlerContext.t(), map()) ::
          {:boundary, String.t(), map(), boolean()} | {:error, map()}
  def handle_child_error(flow_node, context, error_info) do
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

  @doc """
  Handles a child BPMN error: tries boundary matching first, then
  propagates upward if no boundary catches it.
  """
  @spec handle_child_bpmn_error(FlowNode.t(), HandlerContext.t(), map(), String.t()) :: term()
  def handle_child_bpmn_error(flow_node, context, error_info, child_process_instance_id) do
    case handle_child_error(flow_node, context, error_info) do
      {:boundary, _, _, _} = boundary_result ->
        boundary_result

      {:error, _} ->
        propagate_bpmn_error(flow_node, context, error_info, child_process_instance_id)
    end
  end

  @doc """
  Finishes the handler FNI as `:error` and returns a `{:bpmn_error, ...}`
  tuple for the PI to propagate to the parent.
  """
  @spec propagate_bpmn_error(FlowNode.t(), HandlerContext.t(), map(), String.t()) :: term()
  def propagate_bpmn_error(flow_node, context, error_info, child_process_instance_id) do
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

  @doc """
  Normalizes a child error reason into a `%{error_code, error_message}` map.

  If the reason already has an `error_code` key it is returned as-is;
  otherwise a generic fatal error is constructed using `default_message`.
  """
  @spec normalize_error(term(), String.t()) :: map()
  def normalize_error(%{error_code: _} = reason, _default_message), do: reason

  def normalize_error(_reason, default_message) do
    %{error_code: "CHILD_FATAL", error_message: default_message}
  end

  # ===================================================================
  # §E — Escalation handling
  # ===================================================================

  @doc """
  Routes a child escalation-end outcome: checks for interrupting
  boundary first, then non-interrupting boundaries, then propagation.
  """
  @spec handle_child_escalation_end(
          FlowNode.t(),
          HandlerContext.t(),
          map(),
          term(),
          String.t(),
          pid(),
          [String.t()]
        ) :: term()
  def handle_child_escalation_end(
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

  @doc false
  def apply_non_interrupting_escalation_end(
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

  @doc false
  def propagate_escalation_end(flow_node, context, escalation_info, child_process_instance_id) do
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

      {:error, _reason} ->
        {:error,
         %{
           error_code: "escalation_persist_failed",
           message: "Failed to finish FNI during escalation propagation"
         }}
    end
  end

  @doc false
  def resume_from_escalated_child(
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

  @doc false
  def handle_escalation_passthrough_in_await(
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

  @doc false
  def fire_non_interrupting_or_passthrough(
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
    case EvilEngine.Execution.lookup_process_instance(child_process_instance_id) do
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
        ) :: term()
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

  @doc """
  Routes the tagged result from `await_child_completion` to the
  appropriate handler function. Used by `monitor_and_wait` and can be
  called directly by handlers that manage their own await loop.

  `next_ids` is resolved lazily when needed (`{:finished, ...}` and
  `{:escalation, ...}` paths).
  """
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
  def dispatch_await_result(
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
          process_instance_pid,
          next_ids
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
    adapter = PersistenceAdapter.adapter()

    case adapter.get_process_instance_for_retry(child_process_instance_id) do
      {:ok, child_pi_data} ->
        dispatch_persisted_child_state(
          child_pi_data,
          flow_node,
          entry,
          context,
          child_process_instance_id,
          adapter,
          opts
        )

      {:error, :not_found} ->
        handle_child_not_found(flow_node, entry, context, child_process_instance_id, opts)
    end
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

  @doc false
  def resume_from_bpmn_error_child(flow_node, context, error_info, child_process_instance_id) do
    handle_child_bpmn_error(
      flow_node,
      context,
      error_info || %{error_code: nil, error_message: nil},
      child_process_instance_id
    )
  end

  @doc """
  Resumes a child PI from persistence data by starting a new process
  with the persisted state. After start, monitors and waits for completion.

  `opts` supports:
  - `:extra_resume_opts` — map merged into the child's resume opts
    (e.g. `%{subprocess_node_id: flow_node.id}`)
  - `:child_label` — for error messages
  - `:extra_message_handler` — callback for `await_child_completion`
  """
  @spec start_child_from_persistence(
          FlowNode.t(),
          map(),
          HandlerContext.t(),
          String.t(),
          map(),
          module(),
          keyword()
        ) :: term()
  def start_child_from_persistence(
        flow_node,
        entry,
        context,
        child_process_instance_id,
        child_pi_data,
        adapter,
        opts \\ []
      ) do
    handler_pid = self()
    process_instance_pid = context.process_instance_pid
    child_label = Keyword.get(opts, :child_label, "Child process")
    extra_resume_opts = Keyword.get(opts, :extra_resume_opts, %{})
    extra_message_handler = Keyword.get(opts, :extra_message_handler)

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
          triggerer_flow_node_instance_id: child_pi_data.triggerer_flow_node_instance_id,
          started_at: child_pi_data.started_at,
          started_by: child_pi_data.started_by,
          started_with_context: child_pi_data.started_with_context,
          notify_pid: handler_pid,
          fni_data: child_fnis,
          pending_arrivals: pending_arrivals
        }
        |> Map.merge(extra_resume_opts)

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
            process_instance_pid,
            child_label,
            extra_message_handler
          )

        {:error, {:already_started, existing_pid}} ->
          monitor_and_wait(
            flow_node,
            entry,
            context,
            existing_pid,
            child_process_instance_id,
            process_instance_pid,
            child_label,
            extra_message_handler
          )

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

  @doc "Reads finished end-event FNIs from persistence and extracts their output tokens."
  @spec aggregate_from_persistence(String.t()) :: [map()]
  def aggregate_from_persistence(child_process_instance_id) do
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

  @doc "Extracts the child PI ID from the FNI's type_properties."
  @spec get_child_process_instance_id(map() | nil) :: String.t() | nil
  def get_child_process_instance_id(nil), do: nil

  def get_child_process_instance_id(type_properties) do
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

  @doc "Applies output mappings to transform the aggregated child payload."
  @spec apply_out_mappings(FlowNode.t(), map(), HandlerContext.t()) ::
          {:ok, map()} | {:error, term()}
  def apply_out_mappings(flow_node, aggregated_payload, context) do
    MappingHelper.apply_out_mappings(
      flow_node.type_data.out_mappings,
      aggregated_payload,
      context
    )
  end

  @doc "Validates a payload or result against a JSON Schema contract."
  @spec validate_contract(map() | nil, map()) :: :ok | {:error, list()}
  def validate_contract(contract, data) do
    MappingHelper.validate_contract(contract, data)
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

  @doc "Updates the child PI's notify_pid so completion messages reach the current handler Task."
  @spec set_child_notify_pid(pid(), pid()) :: :ok
  def set_child_notify_pid(child_pid, handler_pid) do
    ProcessInstance.update_notify_pid(child_pid, handler_pid)
  catch
    :exit, _ -> :ok
  end
end

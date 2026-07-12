defmodule EvilEngine.Execution.FlowNodes.TransactionSubProcess do
  @moduledoc """
  Handler for `<bpmn:transaction>` — transactional subprocess execution.

  Identical to `SubProcess` in structure, but adds cancel-aware child
  lifecycle:

  - The `extra_message_handler` intercepts `{:child_pi_cancelled, ...}`
    from the child PI and resolves the Cancel Boundary on the transaction
    shell.
  - On cancel with a matching Cancel Boundary: returns
    `{:boundary, cancel_boundary_id, cancel_token, true}` — always
    interrupting.
  - On cancel without a Cancel Boundary: returns
    `{:error, unhandled_cancel_error}` — parent PI fatals (hazard).

  ## Three outcomes

  | Child PI state | Handler result |
  |----------------|----------------|
  | `:finished` | Normal subprocess completion, outgoing flow dispatched |
  | `:cancelled` | Cancel Boundary resolution: `{:boundary, ...}` or fatal |
  | `:fatal` / `:error` | Error Boundary resolution (same as SubProcess) |
  | `:aborted` | `:abort_cascade` |
  | `:escalated` | Escalation Boundary resolution (same as SubProcess) |

  ## `method` attribute

  The BPMN `method` attribute is parsed and stored in `FlowNodeData.SubProcess`
  as `transaction_method` but is intentionally ignored at runtime. The engine
  implements saga-pattern compensation, not wire-level transaction protocols
  (TX-D6).
  """

  @behaviour EvilEngine.Execution.FlowNodeHandler

  @child_label "Transaction subprocess child process"

  alias EvilEngine.BPMN.Model.EventDefinition
  alias EvilEngine.BPMN.Model.FlowNode
  alias EvilEngine.BPMN.Model.FlowNodeData
  alias EvilEngine.Execution.BoundaryResolver
  alias EvilEngine.Execution.FlowNodes.ChildLifecycle
  alias EvilEngine.Execution.FniLifecycle
  alias EvilEngine.Execution.HandlerContext
  alias EvilEngine.Execution.ProcessInstance
  alias EvilEngine.Execution.ProcessInstance.Helpers
  alias EvilEngine.Types.Token

  # -------------------------------------------------------------------
  # FlowNodeHandler callbacks
  # -------------------------------------------------------------------

  @doc """
  Validates the transaction contents at runtime, applies input mappings
  and payload contract, then spawns a child PI for the inner scope.
  """
  @spec handle_enter(FlowNode.t(), Token.t(), HandlerContext.t()) ::
          {:async, String.t(), (-> term()), map()} | {:error, term()}
  @impl true
  def handle_enter(flow_node, token, context) do
    type_data = flow_node.type_data

    with {:ok, start_event_id} <- validate_subprocess_contents(flow_node.id, type_data),
         {:ok, next_ids} <- ChildLifecycle.resolve_outgoing(flow_node, context) do
      process_instance_pid = context.process_instance_pid
      child_process_instance_id = Helpers.generate_uuid_v7()

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

      async_type_properties = %{
        "is_transaction" => true,
        child_process_instance_id: child_process_instance_id
      }

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
  Resume a TransactionSubProcess FNI after engine restart.

  `"cancelled"` is an extra terminal state — re-resolves the Cancel
  Boundary from persistence.
  """
  @spec handle_resume(FlowNode.t(), map(), HandlerContext.t(), String.t() | nil) ::
          {:ok, term()} | {:boundary, String.t(), term()} | {:error, term()}
  def handle_resume(flow_node, entry, context, nil) do
    run_fresh_lifecycle(flow_node, entry, context, context.process_instance_pid)
  end

  def handle_resume(flow_node, entry, context, child_process_instance_id) do
    cancel_handler = build_cancel_message_handler(flow_node, context)

    case ChildLifecycle.query_child_state(child_process_instance_id) do
      {:running, child_pid} ->
        ChildLifecycle.monitor_and_wait(
          flow_node,
          entry,
          context,
          child_pid,
          child_process_instance_id,
          context.process_instance_pid,
          @child_label,
          cancel_handler
        )

      :not_found ->
        ChildLifecycle.resume_existing_child(
          flow_node,
          entry,
          context,
          child_process_instance_id,
          child_label: @child_label,
          extra_resume_opts: %{subprocess_node_id: flow_node.id},
          extra_terminal_states: %{"cancelled" => &resume_from_cancelled_child/4},
          extra_message_handler: cancel_handler,
          fresh_lifecycle_fn: &run_fresh_lifecycle/4
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

  defp validate_subprocess_contents(transaction_id, %FlowNodeData.SubProcess{} = type_data) do
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
           reason: :invalid_transaction,
           detail:
             "Transaction '#{transaction_id}' must have exactly one None Start Event, found #{length(none_start_events)}"
         }}

      typed_start_events != [] ->
        {:error,
         %{
           reason: :invalid_transaction,
           detail:
             "Transaction '#{transaction_id}' contains typed Start Events, which are not allowed"
         }}

      end_events == [] ->
        {:error,
         %{
           reason: :invalid_transaction,
           detail: "Transaction '#{transaction_id}' has no End Event"
         }}

      true ->
        {:ok, hd(none_start_events).id}
    end
  end

  # -------------------------------------------------------------------
  # Private: cancel message handler
  # -------------------------------------------------------------------

  defp build_cancel_message_handler(flow_node, context) do
    fn
      {:child_pi_cancelled, _child_pid, final_tokens} ->
        {:handled, resolve_cancel_boundary(flow_node, context, final_tokens)}

      _other ->
        :skip
    end
  end

  defp resolve_cancel_boundary(flow_node, context, final_tokens) do
    case BoundaryResolver.find_matching_cancel_boundary(
           flow_node,
           context.process_model
         ) do
      {:ok, boundary_node} ->
        aggregated = ChildLifecycle.aggregate_tokens(final_tokens)
        {:boundary, boundary_node.id, aggregated, true}

      :none ->
        {:error,
         %{
           error_code: "unhandled_cancel",
           message:
             "Transaction '#{flow_node.id}' was cancelled but has no Cancel Boundary Event. " <>
               "This is a hazard — the parent process fatals."
         }}
    end
  end

  defp resume_from_cancelled_child(flow_node, _entry, context, _child_pi_data) do
    final_tokens = []
    resolve_cancel_boundary(flow_node, context, final_tokens)
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
    case ChildLifecycle.resolve_input_payload(flow_node, token, context) do
      {:ok, input_payload} ->
        case ChildLifecycle.validate_contract(
               flow_node.type_data.payload_contract,
               input_payload
             ) do
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
    cancel_handler = build_cancel_message_handler(flow_node, context)

    result =
      start_and_monitor_child(
        context,
        flow_node,
        input_payload,
        child_process_instance_id,
        process_instance_pid,
        start_event_id,
        cancel_handler
      )

    handle_child_result(result, flow_node, context, child_process_instance_id, process_instance_pid, next_ids)
  end

  defp handle_child_result(result, flow_node, context, child_process_instance_id, process_instance_pid, next_ids) do
    case result do
      {:boundary, _, _, _} ->
        result

      {:error, _} ->
        result

      other ->
        ChildLifecycle.dispatch_enter_result(
          other,
          flow_node,
          context,
          child_process_instance_id,
          process_instance_pid,
          next_ids,
          @child_label
        )
    end
  end

  defp start_and_monitor_child(
         context,
         flow_node,
         input_payload,
         child_process_instance_id,
         process_instance_pid,
         start_event_id,
         cancel_handler
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

        result =
          ChildLifecycle.await_child_completion(
            child_pid,
            ref,
            child_process_instance_id,
            flow_node,
            context,
            process_instance_pid,
            cancel_handler
          )

        case result do
          {:boundary, _, _, _} -> result
          {:error, _} -> result
          other -> other
        end

      {:error, _reason} ->
        {:fatal,
         %{
           error_code: "CHILD_START_FAILED",
           error_message: "Failed to start transaction subprocess child process"
         }}
    end
  end

  # -------------------------------------------------------------------
  # Private: resume from scratch
  # -------------------------------------------------------------------

  defp run_fresh_lifecycle(flow_node, entry, context, process_instance_pid) do
    type_data = flow_node.type_data
    child_process_instance_id = Helpers.generate_uuid_v7()

    with {:ok, next_ids} <- ChildLifecycle.resolve_outgoing(flow_node, context),
         {:ok, start_event_id} <- validate_subprocess_contents(flow_node.id, type_data),
         {:ok, input_payload} <- ChildLifecycle.resolve_input_payload(flow_node, entry.token, context),
         :ok <- ChildLifecycle.validate_contract(type_data.payload_contract, input_payload) do
      execute_child(
        flow_node,
        context,
        input_payload,
        start_event_id,
        next_ids,
        process_instance_pid,
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

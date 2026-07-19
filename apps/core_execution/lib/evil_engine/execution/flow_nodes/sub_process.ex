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

  Shared child-PI lifecycle logic (await, result handling, error/
  escalation resolution, resume, cascade) is delegated to
  `ChildLifecycle`.
  """

  @behaviour EvilEngine.Execution.FlowNodeHandler

  @child_label "Subprocess child process"

  alias EvilEngine.BPMN.Model.EventDefinition
  alias EvilEngine.BPMN.Model.FlowNode
  alias EvilEngine.BPMN.Model.FlowNodeData
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
          {:ok, term()} | {:boundary, String.t(), term()} | {:error, term()}
  def handle_resume(flow_node, entry, context, nil) do
    run_fresh_lifecycle(flow_node, entry, context, context.process_instance_pid)
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
          extra_resume_opts: %{subprocess_node_id: flow_node.id},
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
    result =
      start_and_monitor_child(
        context,
        flow_node,
        input_payload,
        child_process_instance_id,
        process_instance_pid,
        start_event_id
      )

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
           flow_node.id, subprocess_model_id, context.process_model.version, false, false}
        )

        ref = Process.monitor(child_pid)

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
           error_message: "Failed to start subprocess child process"
         }}
    end
  end

  # -------------------------------------------------------------------
  # Private: resume from scratch
  # -------------------------------------------------------------------

  defp run_fresh_lifecycle(flow_node, entry, context, process_instance_pid) do
    type_data = flow_node.type_data
    child_process_instance_id = Helpers.generate_uuid_v7()

    with :ok <- guard_event_subprocess(type_data),
         {:ok, next_ids} <- ChildLifecycle.resolve_outgoing(flow_node, context),
         {:ok, start_event_id} <- validate_subprocess_contents(flow_node.id, type_data),
         {:ok, input_payload} <- ChildLifecycle.resolve_input_payload(flow_node, entry.token, context),
         :ok <- ChildLifecycle.validate_contract(type_data.payload_contract, input_payload) do
      result =
        start_and_monitor_child(
          context,
          flow_node,
          input_payload,
          child_process_instance_id,
          process_instance_pid,
          start_event_id
        )

      ChildLifecycle.dispatch_enter_result(
        result,
        flow_node,
        context,
        child_process_instance_id,
        process_instance_pid,
        next_ids,
        @child_label
      )
    else
      {:error, %{} = structured} ->
        {:error, structured}

      {:error, reason} ->
        {:error, reason}
    end
  end
end

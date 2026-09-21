defmodule BfwEngine.Execution.FlowNodes.CallActivity do
  @moduledoc """
  Handler for `<bpmn:callActivity>` — invokes another process as a child.

  Owns the type-specific lifecycle: version resolution, start_opts
  construction with `calledElement`, and optional `start_event_id`.
  The PI remains a pure dispatcher — it receives standard result shapes
  (`{:ok, ...}`, `{:error, ...}`, `{:boundary, ...}`) and reacts generically.

  Shared child-PI lifecycle logic (await, result handling, error/
  escalation resolution, resume, cascade) is delegated to
  `ChildLifecycle`.
  """

  @behaviour BfwEngine.Execution.FlowNodeHandler

  @child_label "Child process"

  alias BfwEngine.BPMN.Model.FlowNode
  alias BfwEngine.Execution.CalledElementResolver
  alias BfwEngine.Execution.FlowNodes.ChildLifecycle
  alias BfwEngine.Execution.FniLifecycle
  alias BfwEngine.Execution.HandlerContext
  alias BfwEngine.Execution.ProcessInstance
  alias BfwEngine.Execution.ProcessInstance.Helpers
  alias BfwEngine.Types.Token

  # -------------------------------------------------------------------
  # FlowNodeHandler callbacks
  # -------------------------------------------------------------------

  @doc "Resolves the called element, spawns a child PI, and parks the FNI as `:waiting`."
  @spec handle_enter(FlowNode.t(), Token.t(), HandlerContext.t()) ::
          {:async, String.t(), (-> term()), map()} | {:error, term()}
  @impl true
  def handle_enter(flow_node, token, context) do
    with {:ok, next_ids} <- ChildLifecycle.resolve_outgoing(flow_node, context),
         {:ok, resolved} <- resolve_called_version(flow_node) do
      process_instance_pid = context.process_instance_pid
      child_process_instance_id = Helpers.generate_uuid_v7()

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
          fresh_lifecycle_fn: &run_fresh_lifecycle/4
        )
    end
  end

  @impl BfwEngine.Execution.FlowNodeHandler
  def handle_fatal(entry) do
    ChildLifecycle.cascade_to_child(entry, fn child_pid ->
      ProcessInstance.force_fatal(child_pid, %{reason: "parent_fatal"})
    end)
  end

  @impl BfwEngine.Execution.FlowNodeHandler
  def handle_aborted(entry) do
    ChildLifecycle.cascade_to_child(entry, fn child_pid ->
      ProcessInstance.abort(child_pid, "parent_aborted", nil)
    end)
  end

  # -------------------------------------------------------------------
  # Private: lifecycle
  # -------------------------------------------------------------------

  defp run_child_lifecycle(
         flow_node,
         token,
         context,
         resolved,
         next_ids,
         process_instance_pid,
         child_process_instance_id
       ) do
    case ChildLifecycle.resolve_input_payload(flow_node, token, context) do
      {:ok, input_payload} ->
        result =
          start_and_monitor_child(
            flow_node,
            context,
            resolved,
            input_payload,
            child_process_instance_id,
            process_instance_pid,
            flow_node.type_data.start_event_id
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
        root_process_instance_id: context.root_process_instance_id,
        triggerer_flow_node_instance_id: context.flow_node_instance_id,
        notify_pid: handler_pid
      }
      |> maybe_put_start_event_id(start_event_id)

    case BfwEngine.Execution.start_process_instance(start_opts) do
      {:ok, child_pid} ->
        send(
          process_instance_pid,
          {:call_activity_child_started, context.flow_node_instance_id, child_process_instance_id,
           resolved.process_model_id, resolved.version}
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
           error_message: "Failed to start child process"
         }}
    end
  end

  # -------------------------------------------------------------------
  # Private: resume from scratch
  # -------------------------------------------------------------------

  defp run_fresh_lifecycle(flow_node, entry, context, _process_instance_pid) do
    process_instance_pid = context.process_instance_pid
    child_process_instance_id = Helpers.generate_uuid_v7()

    with {:ok, next_ids} <- ChildLifecycle.resolve_outgoing(flow_node, context),
         {:ok, resolved} <- resolve_called_version(flow_node),
         {:ok, input_payload} <-
           ChildLifecycle.resolve_input_payload(flow_node, entry.token, context) do
      result =
        start_and_monitor_child(
          flow_node,
          context,
          resolved,
          input_payload,
          child_process_instance_id,
          process_instance_pid,
          flow_node.type_data.start_event_id
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
        {:error, {:called_element_resolution_failed, reason}}
    end
  end

  # -------------------------------------------------------------------
  # Private: CA-specific helpers
  # -------------------------------------------------------------------

  defp resolve_called_version(flow_node) do
    called_element = flow_node.type_data.called_element

    case pinned_called_process_version(flow_node.type_data) do
      nil ->
        CalledElementResolver.adapter().resolve_latest_version(called_element)

      version_string ->
        case CalledElementResolver.adapter().resolve_specific_version(
               called_element,
               version_string
             ) do
          {:ok, resolved} ->
            {:ok, resolved}

          {:error, :version_not_found} ->
            {:error, {:called_process_version_not_found, called_element, version_string}}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp pinned_called_process_version(%{called_process_version: called_process_version})
       when is_binary(called_process_version) do
    trimmed = String.trim(called_process_version)

    if trimmed == "" do
      nil
    else
      trimmed
    end
  end

  defp pinned_called_process_version(_type_data), do: nil

  defp maybe_put_start_event_id(opts, nil), do: opts

  defp maybe_put_start_event_id(opts, start_event_id),
    do: Map.put(opts, :start_event_id, start_event_id)
end

defmodule EvilEngine.Execution.FlowNodes.EventSubprocess do
  @moduledoc """
  Handler for the shell FNI of an Event Subprocess
  (`<bpmn:subProcess triggeredByEvent="true">`) **and** the scope-level
  trigger API that manages ESP dormant trigger registration, resolution,
  and firing decisions.

  ## Shell FNI handler (§A — FlowNodeHandler callbacks)

  - starts the ESP child PI at the ESP's single **typed** start event
    (message/signal/timer/error/escalation/conditional — validator-enforced),
    passing the trigger payload straight through (**no data mappings** —
    ESP-D decision D),
  - **parks the shell FNI as async-waiting** (`FniLifecycle.park_async`) with the
    pre-generated `child_process_instance_id`, so an engine restart can reattach
    the in-flight child PI via `handle_resume/4` (ESP-D10),
  - monitors the child and finishes the shell FNI when the child completes
    (no outgoing flows: `next_flow_node_ids: []`),
  - bubbles an uncaught child BPMN error / escalation to the **scope PI's own
    parent** (ESP-D11) — after first checking the shell's own boundary events,
  - cascades fatal/abort to the child PI (`handle_fatal/1`, `handle_aborted/1`).

  Interrupting vs non-interrupting is decided by the scope PI *before*
  dispatching this handler (interrupting first interrupts all other FNIs and
  tears down the other triggers); this handler is identical for both variants.

  ## Scope-level trigger API (§B — called by ProcessInstance)

  Public functions for managing the ESP trigger lifecycle. The scope PI's
  `gen_statem` loop invokes these; all ESP-specific decision logic lives
  here, the PI keeps only thin delegation and generic execution primitives
  (`interrupt_remaining_fnis`, `dispatch_flow_node_instance`).

  The API returns `trigger_action()` tuples that the PI executes:

  - `{:fire_interrupting, %FlowNode{}, payload}` — PI interrupts siblings,
    tears down triggers, dispatches the shell FNI
  - `{:fire_non_interrupting, %FlowNode{}, payload}` — PI dispatches only
  - `:noop` — no action
  """

  @behaviour EvilEngine.Execution.FlowNodeHandler

  @error_code_child_crash "CHILD_CRASH"
  @error_code_child_start_failed "CHILD_START_FAILED"
  @error_code_child_fatal "CHILD_FATAL"

  alias EvilEngine.BPMN.Model.EventDefinition
  alias EvilEngine.BPMN.Model.FlowNode
  alias EvilEngine.BPMN.Model.FlowNodeData
  alias EvilEngine.Events.EngineEventBus
  alias EvilEngine.Events.MessageSubscriptions
  alias EvilEngine.Events.SignalSubscriptions
  alias EvilEngine.Execution.BoundaryResolver
  alias EvilEngine.Execution.EscalationResolver
  alias EvilEngine.Execution.EventSubprocessResolver
  alias EvilEngine.Execution.EventSubprocessTrigger
  alias EvilEngine.Execution.FlowNodeResult
  alias EvilEngine.Execution.FlowNodes.MessageEventHelper
  alias EvilEngine.Execution.FniLifecycle
  alias EvilEngine.Execution.HandlerContext
  alias EvilEngine.Execution.Persistence, as: PersistenceAdapter
  alias EvilEngine.Execution.ProcessInstance
  alias EvilEngine.Execution.ProcessInstance.Helpers, as: PiHelpers
  alias EvilEngine.Execution.ProcessInstance.State
  alias EvilEngine.Expressions
  alias EvilEngine.Expressions.Context, as: FeelContext
  alias EvilEngine.Timers.ISO8601
  alias EvilEngine.Timers.Scheduler
  alias EvilEngine.Types.Event
  alias EvilEngine.Types.Token

  @type trigger_action ::
          {:fire_interrupting, FlowNode.t(), map()}
          | {:fire_non_interrupting, FlowNode.t(), map()}
          | :noop

  # -------------------------------------------------------------------
  # FlowNodeHandler callbacks
  # -------------------------------------------------------------------

  @spec handle_enter(FlowNode.t(), Token.t(), HandlerContext.t()) ::
          {:async, String.t(), (-> term()), map()} | {:error, term()}
  @impl true
  def handle_enter(flow_node, token, context) do
    with {:ok, start_event_id} <- resolve_esp_start_event(flow_node.type_data) do
      process_instance_pid = context.process_instance_pid
      child_process_instance_id = PiHelpers.generate_uuid_v7()

      continuation = fn ->
        run_child_lifecycle(
          flow_node,
          token,
          context,
          start_event_id,
          process_instance_pid,
          child_process_instance_id
        )
      end

      async_type_properties = %{
        child_process_instance_id: child_process_instance_id,
        is_event_subprocess: true
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
  Resume an Event Subprocess shell FNI after engine restart.

  Reattaches to a running ESP child PI or re-derives the result from the
  child's persisted terminal state (mirrors `FlowNodes.SubProcess`).
  """
  @spec handle_resume(FlowNode.t(), map(), HandlerContext.t(), String.t() | nil) ::
          {:ok, FlowNodeResult.t()}
          | {:bpmn_error, map(), FlowNodeResult.t()}
          | {:escalation_end_propagate, map(), FlowNodeResult.t()}
          | {:boundary, String.t(), term(), boolean()}
          | {:boundary, String.t(), term(), boolean(), String.t() | nil}
          | :abort_cascade
          | {:error, term()}
  def handle_resume(flow_node, entry, context, nil) do
    run_fresh_lifecycle(flow_node, entry, context, context.process_instance_pid)
  end

  def handle_resume(flow_node, entry, context, child_process_instance_id) do
    case query_child_state(child_process_instance_id) do
      {:running, child_pid} ->
        monitor_and_wait(
          flow_node,
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
  # Start-event resolution
  # -------------------------------------------------------------------

  @doc false
  @spec resolve_esp_start_event(FlowNodeData.SubProcess.t()) ::
          {:ok, String.t()} | {:error, term()}
  def resolve_esp_start_event(%FlowNodeData.SubProcess{flow_nodes: flow_nodes}) do
    case Enum.filter(flow_nodes, &(&1.type == :start_event)) do
      [start] ->
        {:ok, start.id}

      _ ->
        {:error,
         %{reason: :invalid_event_subprocess, detail: "expected exactly one start event"}}
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
         process_instance_pid,
         child_process_instance_id
       ) do
    input_payload = token_payload(token)

    case start_and_monitor_child(
           flow_node,
           context,
           input_payload,
           start_event_id,
           process_instance_pid,
           child_process_instance_id
         ) do
      {:finished, final_tokens} ->
        finish_shell(flow_node, context, final_tokens, child_process_instance_id)

      {:fatal, reason} ->
        handle_child_error(flow_node, context, normalize_error(reason))

      {:bpmn_error, error_info} ->
        handle_child_bpmn_error(flow_node, context, error_info, child_process_instance_id)

      {:escalation, escalation_info, _final_tokens} ->
        handle_child_escalation(flow_node, context, escalation_info, child_process_instance_id)

      :aborted ->
        :abort_cascade

      {:crashed, _reason} ->
        handle_child_error(flow_node, context, %{
          error_code: @error_code_child_crash,
          error_message: "Event Subprocess child process crashed"
        })
    end
  end

  defp start_and_monitor_child(
         flow_node,
         context,
         input_payload,
         start_event_id,
         process_instance_pid,
         child_process_instance_id
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
      start_event_id: start_event_id,
      esp_start_passthrough: true
    }

    case EvilEngine.Execution.start_process_instance(start_opts) do
      {:ok, child_pid} ->
        send(
          process_instance_pid,
          {:subprocess_child_started, context.flow_node_instance_id, child_process_instance_id,
           flow_node.id, subprocess_model_id, context.process_model.version, true}
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
           error_message: "Failed to start Event Subprocess child process"
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

  defp finish_shell(flow_node, context, final_tokens, child_process_instance_id) do
    output = aggregate_tokens(final_tokens)
    type_properties = shell_type_properties(child_process_instance_id)

    case FniLifecycle.finish(context, flow_node, output, type_properties) do
      {:ok, lifecycle_result} ->
        {:ok,
         %FlowNodeResult{
           output_payload: output,
           next_flow_node_ids: [],
           type_properties: type_properties,
           metadata: %{persisted: true, lifecycle: lifecycle_result}
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # An uncaught child BPMN error is first offered to the ESP shell's own error
  # boundary; if none matches, it bubbles to the scope PI's parent (ESP-D11).
  defp handle_child_bpmn_error(flow_node, context, error_info, child_process_instance_id) do
    case handle_child_error(flow_node, context, error_info) do
      {:boundary, _, _, _} = boundary_result ->
        boundary_result

      {:error, _} ->
        propagate_bpmn_error(flow_node, context, error_info, child_process_instance_id)
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

  defp propagate_bpmn_error(flow_node, context, error_info, child_process_instance_id) do
    type_properties = shell_type_properties(child_process_instance_id)

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

  defp handle_child_escalation(flow_node, context, escalation_info, child_process_instance_id) do
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
        propagate_escalation(flow_node, context, escalation_info, child_process_instance_id)
    end
  end

  defp propagate_escalation(flow_node, context, escalation_info, child_process_instance_id) do
    type_properties = shell_type_properties(child_process_instance_id)

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
           error_message: "Failed to finish Event Subprocess FNI during escalation propagation"
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
        route_non_interrupting_escalation(
          flow_node,
          context,
          escalation_info,
          process_instance_pid,
          triggerer_fni_id
        )
    end
  end

  defp route_non_interrupting_escalation(
         flow_node,
         context,
         escalation_info,
         process_instance_pid,
         triggerer_fni_id
       ) do
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
      notify_non_interrupting_boundaries(
        boundaries,
        context.flow_node_instance_id,
        escalation_info,
        process_instance_pid,
        triggerer_fni_id
      )
    end
  end

  defp notify_non_interrupting_boundaries(
         boundaries,
         flow_node_instance_id,
         escalation_info,
         process_instance_pid,
         triggerer_fni_id
       ) do
    Enum.each(boundaries, fn boundary_node ->
      send(
        process_instance_pid,
        {:fni_result, flow_node_instance_id,
         {:boundary, boundary_node.id, escalation_info, false, triggerer_fni_id}}
      )
    end)
  end

  # -------------------------------------------------------------------
  # Private: resume helpers
  # -------------------------------------------------------------------

  defp query_child_state(child_process_instance_id) do
    case EvilEngine.Execution.lookup_process_instance(child_process_instance_id) do
      {:ok, pid} -> {:running, pid}
      {:error, _} -> :not_found
    end
  end

  defp monitor_and_wait(
         flow_node,
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

    handle_resume_result(flow_node, context, result, child_process_instance_id)
  end

  defp resume_existing_child(flow_node, entry, context, child_process_instance_id) do
    adapter = PersistenceAdapter.adapter()

    case adapter.get_process_instance_for_retry(child_process_instance_id) do
      {:ok, %{state: "finished"}} ->
        final_tokens = aggregate_from_persistence(child_process_instance_id)
        finish_shell(flow_node, context, final_tokens, child_process_instance_id)

      {:ok, %{state: "fatal", error_info: error_info}} ->
        handle_child_error(flow_node, context, normalize_error(error_info || "CHILD_FATAL"))

      {:ok, %{state: "error", error_info: error_info}} ->
        handle_child_bpmn_error(
          flow_node,
          context,
          normalize_error(error_info || "CHILD_FATAL"),
          child_process_instance_id
        )

      _ ->
        run_fresh_lifecycle(flow_node, entry, context, context.process_instance_pid)
    end
  end

  defp handle_resume_result(flow_node, context, result, child_process_instance_id) do
    case result do
      {:finished, final_tokens} ->
        finish_shell(flow_node, context, final_tokens, child_process_instance_id)

      {:fatal, reason} ->
        handle_child_error(flow_node, context, normalize_error(reason))

      {:bpmn_error, error_info} ->
        handle_child_bpmn_error(flow_node, context, error_info, child_process_instance_id)

      {:escalation, escalation_info, _final_tokens} ->
        handle_child_escalation(flow_node, context, escalation_info, child_process_instance_id)

      :aborted ->
        :abort_cascade

      {:crashed, _reason} ->
        handle_child_error(flow_node, context, %{
          error_code: @error_code_child_crash,
          error_message: "Event Subprocess child process crashed"
        })
    end
  end

  defp run_fresh_lifecycle(flow_node, entry, context, process_instance_pid) do
    with {:ok, start_event_id} <- resolve_esp_start_event(flow_node.type_data) do
      child_process_instance_id = PiHelpers.generate_uuid_v7()

      run_child_lifecycle(
        flow_node,
        entry.token,
        context,
        start_event_id,
        process_instance_pid,
        child_process_instance_id
      )
    end
  end

  defp set_child_notify_pid(child_pid, handler_pid) do
    ProcessInstance.update_notify_pid(child_pid, handler_pid)
  catch
    :exit, _ -> :ok
  end

  # -------------------------------------------------------------------
  # Private: helpers
  # -------------------------------------------------------------------

  defp shell_type_properties(child_process_instance_id) do
    %{child_process_instance_id: child_process_instance_id, is_event_subprocess: true}
  end

  defp token_payload(%Token{payload: payload}) when is_map(payload), do: payload
  defp token_payload(_), do: %{}

  defp aggregate_tokens(final_tokens) when is_list(final_tokens) do
    Enum.reduce(final_tokens, %{}, fn token, accumulator ->
      case token do
        %{payload: payload} when is_map(payload) -> Map.merge(accumulator, payload)
        _ -> accumulator
      end
    end)
  end

  defp aggregate_tokens(payload) when is_map(payload), do: payload
  defp aggregate_tokens(_), do: %{}

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

  defp normalize_error(%{error_code: _} = reason), do: reason

  defp normalize_error(_reason) do
    %{
      error_code: @error_code_child_fatal,
      error_message: "Event Subprocess child ended in a fatal state"
    }
  end

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

  # ===================================================================
  # §B — Scope-level trigger API (called by ProcessInstance)
  # ===================================================================
  #
  # Public functions for managing the ESP trigger lifecycle. The scope
  # PI's gen_statem loop invokes these; all ESP-specific decision logic
  # lives here, the PI keeps only thin delegation and the generic
  # execution primitives (`interrupt_remaining_fnis`,
  # `dispatch_flow_node_instance`).

  @doc """
  Register dormant triggers for all ESP shells declared in the scope
  model. Called from fresh `init` and from `Resumption.resume`.
  """
  @spec register_triggers(State.t()) :: State.t()
  def register_triggers(data) do
    (data.process_model.flow_nodes || [])
    |> Enum.filter(&event_subprocess_shell?/1)
    |> Enum.reduce(data, fn esp_node, accumulator ->
      case build_trigger(accumulator, esp_node) do
        {:ok, trigger} ->
          accumulator = put_in(accumulator.event_subprocess_triggers[esp_node.id], trigger)

          put_in(
            accumulator.event_subprocess_kinds[esp_node.id],
            {trigger.trigger_kind, trigger.is_interrupting}
          )

        :skip ->
          accumulator
      end
    end)
  end

  @doc """
  Tear down all armed triggers (cancel timers, clear trigger map).
  Message/signal ETS subscriptions are purged by `interrupt_remaining_fnis`.
  """
  @spec teardown_triggers(State.t()) :: State.t()
  def teardown_triggers(data) do
    Enum.each(data.event_subprocess_triggers, fn {_node_id, trigger} ->
      if trigger.timer_ref, do: Scheduler.cancel(trigger.timer_ref)
    end)

    %{data | event_subprocess_triggers: %{}}
  end

  @doc """
  Resolve a message/signal/timer trigger fire into an action tuple.

  Returns `{:fire_interrupting, esp_node, payload}`,
  `{:fire_non_interrupting, esp_node, payload}`, or `:noop`.
  """
  @spec resolve_trigger(State.t(), String.t(), map()) :: trigger_action()
  def resolve_trigger(data, subprocess_node_id, payload) do
    with %EventSubprocessTrigger{armed?: true} = trigger <-
           Map.get(data.event_subprocess_triggers, subprocess_node_id),
         %FlowNode{} = esp_node <- PiHelpers.find_flow_node(data, subprocess_node_id) do
      build_fire_action(trigger, esp_node, payload)
    else
      _ -> :noop
    end
  end

  @doc """
  Resolve a reactive trigger (error/escalation) into an action tuple.
  """
  @spec resolve_reactive_trigger(State.t(), EventSubprocessTrigger.t(), map()) :: trigger_action()
  def resolve_reactive_trigger(data, trigger, payload) do
    case PiHelpers.find_flow_node(data, trigger.subprocess_node_id) do
      %FlowNode{} = esp_node -> build_fire_action(trigger, esp_node, payload)
      _ -> :noop
    end
  end

  @doc """
  Re-arm a non-interrupting cycle timer after fire. Date/duration timers
  are one-shot; interrupting timers are torn down, so neither re-arms.
  """
  @spec rearm_timer(State.t(), String.t(), map()) :: State.t()
  def rearm_timer(data, subprocess_node_id, _metadata) do
    case Map.get(data.event_subprocess_triggers, subprocess_node_id) do
      %EventSubprocessTrigger{
        is_interrupting: false,
        armed?: true,
        timer_spec: %EventDefinition.Timer{time_cycle: cycle}
      } = trigger
      when is_binary(cycle) and cycle != "" ->
        do_rearm_cycle_timer(data, subprocess_node_id, trigger, cycle)

      _ ->
        data
    end
  end

  @doc """
  Attempt to catch a `{:error, reason}` FNI failure with a scope ESP
  error start. Only *modeled* errors (structured `%{error_code: ...}`
  maps) are eligible — engine failures (atoms/tuples) always fatal.

  Returns `{:caught, updated_data, trigger_action}` or `:not_caught`.
  """
  @spec resolve_error_catch(State.t(), String.t(), term()) ::
          {:caught, State.t(), trigger_action()} | :not_caught
  def resolve_error_catch(data, flow_node_instance_id, reason) do
    with {:ok, error_info} <- reactive_error_info(reason),
         {:ok, trigger} <-
           EventSubprocessResolver.find_matching_error_start(
             data.event_subprocess_triggers,
             error_info
           ) do
      data = mark_fni_as_error(data, flow_node_instance_id, error_info)
      action = resolve_reactive_trigger(data, trigger, error_payload(error_info))
      {:caught, data, action}
    else
      _ -> :not_caught
    end
  end

  @doc """
  Resolve whether an error (from a BPMN Error End Event) can be caught
  by a scope ESP error start. Used in the `handle_fni_bpmn_error` path.

  Returns `{:ok, trigger_action}` or `:none`.
  """
  @spec resolve_bpmn_error_catch(State.t(), map()) :: {:ok, trigger_action()} | :none
  def resolve_bpmn_error_catch(data, error_info) do
    case EventSubprocessResolver.find_matching_error_start(
           data.event_subprocess_triggers,
           error_info
         ) do
      {:ok, trigger} ->
        {:ok, resolve_reactive_trigger(data, trigger, error_payload(error_info))}

      :none ->
        :none
    end
  end

  @doc """
  Resolve whether an escalation can be caught by a scope ESP escalation
  start. Used in escalation-end, escalation-throw, and escalation-propagate
  handlers (ESP-D6 proximity).

  Returns `{:ok, trigger_action}` or `:none`.
  """
  @spec resolve_escalation_catch(State.t(), map()) :: {:ok, trigger_action()} | :none
  def resolve_escalation_catch(data, escalation_info) do
    case EventSubprocessResolver.find_matching_escalation_start(
           data.event_subprocess_triggers,
           escalation_info
         ) do
      {:ok, trigger} ->
        {:ok, resolve_reactive_trigger(data, trigger, %{})}

      :none ->
        :none
    end
  end

  @doc """
  Resolve whether a scope-level compensation throw (broadcast, no `activityRef`)
  can be consumed by a Compensation-start Event Subprocess.

  Returns `{:ok, trigger_action}` or `:none`.
  """
  @spec resolve_compensation_esp_catch(State.t()) :: {:ok, trigger_action()} | :none
  def resolve_compensation_esp_catch(data) do
    case EventSubprocessResolver.find_matching_compensation_start(
           data.event_subprocess_triggers
         ) do
      {:ok, trigger} ->
        {:ok, resolve_reactive_trigger(data, trigger, %{})}

      :none ->
        :none
    end
  end

  @doc """
  Edge-evaluate conditional ESP triggers against current scope state.

  Returns `{updated_data, [trigger_action]}` — the PI executes each action.
  """
  @spec evaluate_conditionals(State.t()) :: {State.t(), [trigger_action()]}
  def evaluate_conditionals(%{event_subprocess_triggers: triggers} = data)
      when map_size(triggers) == 0,
      do: {data, []}

  def evaluate_conditionals(data) do
    conditional_triggers =
      Enum.filter(data.event_subprocess_triggers, fn {_node_id, trigger} ->
        trigger.trigger_kind == :conditional and trigger.armed?
      end)

    Enum.reduce(conditional_triggers, {data, []}, fn {node_id, trigger},
                                                     {accumulator, actions} ->
      evaluate_single_conditional(accumulator, actions, node_id, trigger)
    end)
  end

  @doc """
  Neutralise Timer/Conditional/Escalation start events for ESP child
  pass-through. The trigger has already fired at the scope — the child
  must treat the start event as a simple pass-through, not re-arm or
  re-wait. Message and Signal start events already have pass-through
  handlers; Error falls through to the generic StartEvent handler.
  """
  @spec passthrough_start_event(FlowNode.t(), boolean() | nil) :: FlowNode.t()
  def passthrough_start_event(
        %FlowNode{type_data: %FlowNodeData.StartEvent{} = type_data} = start_event,
        true
      ) do
    if start_needs_passthrough?(type_data.event_definition) do
      %{start_event | type_data: %{type_data | event_definition: %EventDefinition.None{}}}
    else
      start_event
    end
  end

  def passthrough_start_event(start_event, _passthrough), do: start_event

  @doc """
  Emit `EventSubprocessTriggered` for an ESP child spawn. The trigger
  kind and interrupting flag are read from `event_subprocess_kinds`,
  which survives interrupting teardown.
  """
  @spec maybe_emit_triggered(State.t(), String.t(), String.t(), boolean()) :: :ok
  def maybe_emit_triggered(data, subprocess_node_id, child_process_instance_id, true) do
    case Map.get(data.event_subprocess_kinds, subprocess_node_id) do
      {trigger_kind, is_interrupting} ->
        do_emit_triggered(
          data,
          subprocess_node_id,
          child_process_instance_id,
          trigger_kind,
          is_interrupting
        )

      nil ->
        :ok
    end
  end

  def maybe_emit_triggered(_data, _node_id, _child_id, _not_esp), do: :ok

  # -------------------------------------------------------------------
  # §B private: trigger construction
  # -------------------------------------------------------------------

  defp event_subprocess_shell?(%FlowNode{
         type: :sub_process,
         type_data: %FlowNodeData.SubProcess{triggered_by_event: true}
       }),
       do: true

  defp event_subprocess_shell?(_flow_node), do: false

  defp build_trigger(data, esp_node) do
    case esp_start_event_node(esp_node) do
      {:ok, start_event} -> register_trigger_source(data, esp_node, start_event)
      :error -> :skip
    end
  end

  defp esp_start_event_node(%FlowNode{type_data: %FlowNodeData.SubProcess{flow_nodes: nodes}}) do
    case Enum.filter(nodes || [], &(&1.type == :start_event)) do
      [start_event] -> {:ok, start_event}
      _ -> :error
    end
  end

  defp esp_start_event_node(_esp_node), do: :error

  defp register_trigger_source(data, esp_node, start_event) do
    base = %EventSubprocessTrigger{
      subprocess_node_id: esp_node.id,
      start_event_id: start_event.id,
      trigger_kind: :message,
      is_interrupting: esp_start_interrupting?(start_event),
      armed?: true,
      last_condition_value: false
    }

    case start_event.type_data.event_definition do
      %EventDefinition.Message{} ->
        register_message_trigger(data, base, start_event)

      %EventDefinition.Signal{} = signal_definition ->
        register_signal_trigger(data, base, signal_definition)

      %EventDefinition.Timer{} = timer_definition ->
        register_timer_trigger(base, timer_definition)

      %EventDefinition.Error{} = error_definition ->
        {:ok, %{base | trigger_kind: :error, error_code: resolve_error_code(data, error_definition)}}

      %EventDefinition.Escalation{} = escalation_definition ->
        {:ok,
         %{
           base
           | trigger_kind: :escalation,
             escalation_code: resolve_escalation_code(data, escalation_definition)
         }}

      %EventDefinition.Conditional{condition_expression: expression} ->
        {:ok, %{base | trigger_kind: :conditional, condition_expression: expression}}

      %EventDefinition.Compensation{} ->
        {:ok, %{base | trigger_kind: :compensation, is_interrupting: true}}

      _other ->
        :skip
    end
  end

  defp esp_start_interrupting?(%FlowNode{type_data: %{is_interrupting: value}})
       when is_boolean(value),
       do: value

  defp esp_start_interrupting?(_start_event), do: true

  defp register_message_trigger(data, base, start_event) do
    case MessageEventHelper.resolve_message_name(start_event, data.definitions) do
      {:ok, message_name} ->
        correlation = evaluate_correlation_value(data, start_event)

        {:ok, subscription_id} =
          MessageSubscriptions.register(%{
            process_instance_id: data.process_instance_id,
            flow_node_instance_id: base.start_event_id,
            flow_node_id: base.subprocess_node_id,
            message_name: message_name,
            expected_correlation_value: correlation,
            kind: :event_subprocess_start,
            via_pid: self()
          })

        {:ok,
         %{
           base
           | trigger_kind: :message,
             message_name: message_name,
             correlation_value: correlation,
             subscription_id: subscription_id
         }}

      {:error, _reason} ->
        :skip
    end
  end

  defp evaluate_correlation_value(data, start_event) do
    context = PiHelpers.build_handler_context(data, start_event.id, start_event, self())

    case MessageEventHelper.evaluate_correlation_key(
           data.process_model,
           context,
           data.started_with_context || %{}
         ) do
      {:ok, :none} -> :none
      {:ok, value} -> value
    end
  end

  defp register_signal_trigger(data, base, signal_definition) do
    case resolve_signal_name(data, signal_definition) do
      {:ok, signal_name} ->
        {:ok, subscription_id} =
          SignalSubscriptions.register(%{
            process_instance_id: data.process_instance_id,
            flow_node_instance_id: base.start_event_id,
            flow_node_id: base.subprocess_node_id,
            signal_name: signal_name,
            kind: :event_subprocess_start,
            via_pid: self()
          })

        {:ok,
         %{base | trigger_kind: :signal, signal_name: signal_name, subscription_id: subscription_id}}

      :error ->
        :skip
    end
  end

  defp resolve_signal_name(data, %EventDefinition.Signal{signal_ref: signal_ref})
       when is_binary(signal_ref) do
    case Enum.find(data.definitions.signals, &(&1.id == signal_ref)) do
      %{name: name} when is_binary(name) and name != "" -> {:ok, name}
      _ -> :error
    end
  end

  defp resolve_signal_name(_data, _signal_definition), do: :error

  defp register_timer_trigger(base, timer_definition) do
    case timer_fire_at(timer_definition, DateTime.utc_now()) do
      {:ok, fire_at} ->
        {:ok, timer_ref} =
          Scheduler.schedule(%{
            fire_at: fire_at,
            target: self(),
            metadata: %{kind: :event_subprocess_start, subprocess_node_id: base.subprocess_node_id}
          })

        {:ok, %{base | trigger_kind: :timer, timer_spec: timer_definition, timer_ref: timer_ref}}

      :error ->
        :skip
    end
  end

  # -------------------------------------------------------------------
  # §B private: timer helpers
  # -------------------------------------------------------------------

  defp timer_fire_at(%EventDefinition.Timer{time_date: date}, reference_time)
       when is_binary(date) and date != "" do
    case ISO8601.resolve_fire_at(:date, date, reference_time) do
      {:ok, %DateTime{} = fire_at} -> {:ok, fire_at}
      _ -> :error
    end
  end

  defp timer_fire_at(%EventDefinition.Timer{time_duration: duration}, reference_time)
       when is_binary(duration) and duration != "" do
    case ISO8601.resolve_fire_at(:duration, duration, reference_time) do
      {:ok, %DateTime{} = fire_at} -> {:ok, fire_at}
      _ -> :error
    end
  end

  defp timer_fire_at(%EventDefinition.Timer{time_cycle: cycle}, reference_time)
       when is_binary(cycle) and cycle != "" do
    case ISO8601.resolve_fire_at(:cycle, cycle, reference_time) do
      {:ok, {:cycle, cycle_spec}} -> {:ok, ISO8601.first_fire_at(cycle_spec, reference_time)}
      _ -> :error
    end
  end

  defp timer_fire_at(_timer_definition, _reference_time), do: :error

  defp do_rearm_cycle_timer(data, subprocess_node_id, trigger, cycle) do
    now = DateTime.utc_now()

    case ISO8601.resolve_fire_at(:cycle, cycle, now) do
      {:ok, {:cycle, cycle_spec}} ->
        next_fire = DateTime.shift(now, cycle_spec.interval_duration)

        {:ok, timer_ref} =
          Scheduler.schedule(%{
            fire_at: next_fire,
            target: self(),
            metadata: %{kind: :event_subprocess_start, subprocess_node_id: subprocess_node_id}
          })

        put_in(data.event_subprocess_triggers[subprocess_node_id], %{trigger | timer_ref: timer_ref})

      _ ->
        data
    end
  end

  # -------------------------------------------------------------------
  # §B private: code resolution
  # -------------------------------------------------------------------

  defp resolve_error_code(_data, %EventDefinition.Error{error_code: code})
       when is_binary(code) and code != "",
       do: code

  defp resolve_error_code(data, %EventDefinition.Error{error_ref: ref}) when is_binary(ref) do
    case Enum.find(data.definitions.errors, &(&1.id == ref)) do
      %{error_code: code} when is_binary(code) and code != "" -> code
      _ -> nil
    end
  end

  defp resolve_error_code(_data, _error_definition), do: nil

  defp resolve_escalation_code(_data, %EventDefinition.Escalation{escalation_code: code})
       when is_binary(code) and code != "",
       do: code

  defp resolve_escalation_code(data, %EventDefinition.Escalation{escalation_ref: ref})
       when is_binary(ref) do
    case Enum.find(data.definitions.escalations, &(&1.id == ref)) do
      %{escalation_code: code} when is_binary(code) and code != "" -> code
      _ -> nil
    end
  end

  defp resolve_escalation_code(_data, _escalation_definition), do: nil

  # -------------------------------------------------------------------
  # §B private: fire action builder
  # -------------------------------------------------------------------

  defp build_fire_action(%EventSubprocessTrigger{is_interrupting: true}, esp_node, payload) do
    {:fire_interrupting, esp_node, payload}
  end

  defp build_fire_action(%EventSubprocessTrigger{is_interrupting: false}, esp_node, payload) do
    {:fire_non_interrupting, esp_node, payload}
  end

  # -------------------------------------------------------------------
  # §B private: error helpers
  # -------------------------------------------------------------------

  defp reactive_error_info(%{error_code: _} = reason), do: {:ok, reason}

  defp reactive_error_info(%{"error_code" => _} = reason) do
    {:ok,
     %{
       error_code: reason["error_code"],
       error_message: reason["error_message"] || reason["message"]
     }}
  end

  defp reactive_error_info(_reason), do: :not_modeled

  defp error_payload(%{} = error_info), do: error_info

  defp mark_fni_as_error(data, flow_node_instance_id, error_info) do
    case Map.get(data.flow_node_instance_states, flow_node_instance_id) do
      nil ->
        data

      entry ->
        flow_node = PiHelpers.find_flow_node(data, entry.flow_node_id)
        context = PiHelpers.build_handler_context(data, flow_node_instance_id, flow_node, self())

        type_properties =
          entry
          |> Map.get(:type_properties, %{})
          |> Map.put(:error_info, error_info)

        _ = FniLifecycle.finish_as_error(context, flow_node, nil, type_properties)

        put_in(data.flow_node_instance_states[flow_node_instance_id], %{
          entry
          | state: :error,
            pid: nil
        })
    end
  end

  # -------------------------------------------------------------------
  # §B private: start event passthrough
  # -------------------------------------------------------------------

  defp start_needs_passthrough?(%EventDefinition.Timer{}), do: true
  defp start_needs_passthrough?(%EventDefinition.Conditional{}), do: true
  defp start_needs_passthrough?(%EventDefinition.Escalation{}), do: true
  defp start_needs_passthrough?(%EventDefinition.Compensation{}), do: true
  defp start_needs_passthrough?(_event_definition), do: false

  # -------------------------------------------------------------------
  # §B private: conditional evaluation
  # -------------------------------------------------------------------

  defp evaluate_single_conditional(data, actions, node_id, trigger) do
    current = condition_true?(data, trigger)

    cond do
      current and not trigger.last_condition_value ->
        action = resolve_trigger(data, node_id, %{})
        data = set_condition_value(data, node_id, true)
        {data, actions ++ [action]}

      not current and trigger.last_condition_value ->
        {set_condition_value(data, node_id, false), actions}

      true ->
        {data, actions}
    end
  end

  defp set_condition_value(data, node_id, value) do
    case Map.get(data.event_subprocess_triggers, node_id) do
      nil -> data
      _present -> put_in(data.event_subprocess_triggers[node_id].last_condition_value, value)
    end
  end

  defp condition_true?(_data, %EventSubprocessTrigger{condition_expression: expression})
       when expression in [nil, ""],
       do: false

  defp condition_true?(data, %EventSubprocessTrigger{
         condition_expression: expression,
         subprocess_node_id: node_id,
         start_event_id: start_event_id
       }) do
    with %FlowNode{} = esp_node <- PiHelpers.find_flow_node(data, node_id),
         {:ok, start_event} <- esp_start_event_node(esp_node) do
      context = PiHelpers.build_handler_context(data, start_event_id, start_event, self())
      feel_context = FeelContext.from_handler_context(context, data.started_with_context || %{})

      case Expressions.eval(expression, feel_context) do
        {:ok, true} -> true
        _ -> false
      end
    else
      _ -> false
    end
  rescue
    _exception -> false
  end

  # -------------------------------------------------------------------
  # §B private: event emission
  # -------------------------------------------------------------------

  defp do_emit_triggered(
         data,
         subprocess_node_id,
         child_process_instance_id,
         trigger_kind,
         is_interrupting
       ) do
    EngineEventBus.publish(%Event.EventSubprocessTriggered{
      scope_process_instance_id: data.process_instance_id,
      root_process_instance_id: data.root_process_instance_id,
      subprocess_node_id: subprocess_node_id,
      child_process_instance_id: child_process_instance_id,
      trigger_kind: trigger_kind,
      is_interrupting: is_interrupting,
      occurred_at: DateTime.utc_now()
    })

    :telemetry.execute(
      [:evil_engine, :event_subprocess, :triggered],
      %{system_time: System.system_time()},
      %{
        scope_process_instance_id: data.process_instance_id,
        subprocess_node_id: subprocess_node_id,
        child_process_instance_id: child_process_instance_id,
        trigger_kind: trigger_kind,
        is_interrupting: is_interrupting
      }
    )
  end
end

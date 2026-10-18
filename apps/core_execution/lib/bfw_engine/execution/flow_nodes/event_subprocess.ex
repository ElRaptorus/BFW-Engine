defmodule BfwEngine.Execution.FlowNodes.EventSubprocess do
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

  @behaviour BfwEngine.Execution.FlowNodeHandler

  @error_code_child_crash "CHILD_CRASH"
  @error_code_child_start_failed "CHILD_START_FAILED"
  @error_code_child_fatal "CHILD_FATAL"

  alias BfwEngine.BPMN.Model.EventDefinition
  alias BfwEngine.BPMN.Model.FlowNode
  alias BfwEngine.BPMN.Model.FlowNodeData
  alias BfwEngine.Events.EngineEventBus
  alias BfwEngine.Events.MessageSubscriptions
  alias BfwEngine.Events.SignalSubscriptions
  alias BfwEngine.Execution.BoundaryResolver
  alias BfwEngine.Execution.EscalationResolver
  alias BfwEngine.Execution.EventSubprocessResolver
  alias BfwEngine.Execution.EventSubprocessTrigger
  alias BfwEngine.Execution.FlowNodeResult
  alias BfwEngine.Execution.FlowNodes.ChildLifecycle
  alias BfwEngine.Execution.FlowNodes.MessageEventHelper
  alias BfwEngine.Execution.FlowNodes.TimerSpecResolver
  alias BfwEngine.Execution.FniLifecycle
  alias BfwEngine.Execution.HandlerContext
  alias BfwEngine.Execution.Persistence, as: PersistenceAdapter
  alias BfwEngine.Execution.ProcessInstance
  alias BfwEngine.Execution.ProcessInstance.FlowNodeLookup
  alias BfwEngine.Execution.ProcessInstance.HandlerDispatch, as: InstanceHandlerDispatch
  alias BfwEngine.Execution.ProcessInstance.LaneResolution
  alias BfwEngine.Execution.ProcessInstance.State
  alias BfwEngine.Execution.UuidV7
  alias BfwEngine.Expressions
  alias BfwEngine.Expressions.Context, as: FeelContext
  alias BfwEngine.Timers.ISO8601
  alias BfwEngine.Timers.Scheduler
  alias BfwEngine.Types.Event
  alias BfwEngine.Types.Token

  require Logger

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
      child_process_instance_id = UuidV7.generate()

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
    send(context.process_instance_pid, {:resume_settled, context.flow_node_instance_id})
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

  @impl BfwEngine.Execution.FlowNodeHandler
  def handle_fatal(entry) do
    cascade_to_child(entry, fn child_pid ->
      ProcessInstance.force_fatal(child_pid, %{reason: "parent_fatal"})
    end)
  end

  @impl BfwEngine.Execution.FlowNodeHandler
  def handle_aborted(entry) do
    cascade_to_child(entry, fn child_pid ->
      ProcessInstance.abort(child_pid, "parent_aborted", nil)
    end)
  end

  # -------------------------------------------------------------------
  # Start-event resolution
  # -------------------------------------------------------------------

  @spec resolve_esp_start_event(FlowNodeData.SubProcess.t()) ::
          {:ok, String.t()} | {:error, term()}
  defp resolve_esp_start_event(%FlowNodeData.SubProcess{flow_nodes: flow_nodes}) do
    case Enum.filter(flow_nodes, &(&1.type == :start_event)) do
      [start] ->
        {:ok, start.id}

      _ ->
        {:error, %{reason: :invalid_event_subprocess, detail: "expected exactly one start event"}}
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

      {:compensated, final_tokens} ->
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

    case BfwEngine.Execution.start_process_instance(start_opts) do
      {:ok, child_pid} ->
        send(
          process_instance_pid,
          {:subprocess_child_started, context.flow_node_instance_id, child_process_instance_id,
           flow_node.id, subprocess_model_id, context.process_model.version, true, false}
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
          process_instance_pid
        )

      {:DOWN, ^ref, :process, ^child_pid, :normal} ->
        {:finished, aggregate_from_persistence(child_process_instance_id)}

      {:DOWN, ^ref, :process, ^child_pid, :noproc} ->
        ChildLifecycle.persisted_child_outcome(child_process_instance_id)

      {:DOWN, ^ref, :process, ^child_pid, reason} ->
        ChildLifecycle.crashed_child_outcome(
          child_process_instance_id,
          reason,
          flow_node,
          context
        )
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
    case BfwEngine.Execution.lookup_process_instance(child_process_instance_id) do
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
    send(process_instance_pid, {:resume_settled, context.flow_node_instance_id})

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
    case ChildLifecycle.fetch_persisted_child(child_process_instance_id) do
      {:ok, %{state: "running"} = child_pi_data} ->
        resume_persisted_child(
          flow_node,
          context,
          child_process_instance_id,
          child_pi_data,
          PersistenceAdapter.adapter()
        )

      {:ok, %{state: "error", error_info: error_info}} ->
        handle_child_bpmn_error(
          flow_node,
          context,
          ChildLifecycle.live_error_info(error_info),
          child_process_instance_id
        )

      {:ok, _terminal_child} ->
        outcome = ChildLifecycle.persisted_child_outcome(child_process_instance_id)
        handle_resume_result(flow_node, context, outcome, child_process_instance_id)

      {:error, :not_found} ->
        send(context.process_instance_pid, {:resume_settled, context.flow_node_instance_id})
        run_fresh_lifecycle(flow_node, entry, context, context.process_instance_pid)

      {:error, reason} ->
        ChildLifecycle.child_resume_failed(context, child_process_instance_id, reason)
    end
  end

  defp resume_persisted_child(
         flow_node,
         context,
         child_process_instance_id,
         child_pi_data,
         adapter
       ) do
    case ChildLifecycle.start_persisted_child(
           context,
           child_process_instance_id,
           child_pi_data,
           adapter,
           %{subprocess_node_id: flow_node.id}
         ) do
      {:ok, child_pid} ->
        monitor_and_wait(
          flow_node,
          context,
          child_pid,
          child_process_instance_id,
          context.process_instance_pid
        )

      {:error, error_info} ->
        {:error, error_info}
    end
  end

  defp handle_resume_result(flow_node, context, result, child_process_instance_id) do
    case result do
      {:finished, final_tokens} ->
        finish_shell(flow_node, context, final_tokens, child_process_instance_id)

      {:compensated, final_tokens} ->
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
    child_process_instance_id = UuidV7.generate()

    with {:ok, start_event_id} <- resolve_esp_start_event(flow_node.type_data),
         :ok <- ChildLifecycle.record_fresh_child(context, child_process_instance_id) do
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
  model. Called from fresh `init` and from resume `init`.

  Timers are anchored at scope activation (`started_at`), so a resumed
  scope keeps the original deadline; a cycle with a start date fires its
  first occurrence at that start. A cycle is armed as a Scheduler cycle,
  which counts its `R<n>` repetitions and skips missed occurrences. On
  resume, the ESP shell FNIs already in the scope decide what is re-armed:
  after an interrupting ESP fired, nothing is; a non-interrupting
  date/duration timer that fired stays disarmed; a cycle that fired `n`
  times re-arms on its original schedule at occurrence `n + 1` (first
  occurrence plus `n` intervals, missed occurrences skipped); a fired
  conditional start waits for the next `false → true` edge.

  A message start's correlation key, a conditional start's condition, and a
  FEEL timer expression are evaluated with `token` bound to the scope
  instance's start payload. Returns `{:error, reason, data}` when a message
  start's correlation key cannot be evaluated or a timer start's spec cannot
  be resolved to a fire time; the process instance then goes fatal with that
  reason.
  """
  @spec register_triggers(State.t()) :: {:ok, State.t()} | {:error, term(), State.t()}
  def register_triggers(data) do
    esp_nodes = Enum.filter(data.process_model.flow_nodes || [], &event_subprocess_shell?/1)
    fired_shell_times = fired_shell_times(data)

    scope_interrupted? =
      Enum.any?(esp_nodes, fn esp_node ->
        Map.has_key?(fired_shell_times, esp_node.id) and interrupting_event_subprocess?(esp_node)
      end)

    Enum.reduce_while(esp_nodes, {:ok, data}, fn esp_node, {:ok, accumulator} ->
      fired_times = Map.get(fired_shell_times, esp_node.id, [])

      case build_trigger(accumulator, esp_node, fired_times, scope_interrupted?) do
        {:ok, trigger} ->
          {:cont, {:ok, put_trigger(accumulator, esp_node.id, trigger)}}

        {:dormant, trigger_kind, is_interrupting} ->
          {:cont,
           {:ok, put_trigger_kind(accumulator, esp_node.id, trigger_kind, is_interrupting)}}

        :skip ->
          {:cont, {:ok, accumulator}}

        {:error, reason} ->
          {:halt, {:error, reason, accumulator}}
      end
    end)
  end

  defp put_trigger(data, subprocess_node_id, trigger) do
    data = put_in(data.event_subprocess_triggers[subprocess_node_id], trigger)
    put_trigger_kind(data, subprocess_node_id, trigger.trigger_kind, trigger.is_interrupting)
  end

  defp put_trigger_kind(data, subprocess_node_id, trigger_kind, is_interrupting) do
    put_in(data.event_subprocess_kinds[subprocess_node_id], {trigger_kind, is_interrupting})
  end

  @doc """
  Whether an interrupting Event Subprocess of this scope already fired: its
  shell has an FNI, which means every other flow of the scope was
  interrupted.
  """
  @spec interrupting_event_subprocess_fired?(State.t()) :: boolean()
  def interrupting_event_subprocess_fired?(data) do
    fired_shell_ids = data |> fired_shell_times() |> Map.keys()

    Enum.any?(data.process_model.flow_nodes || [], fn flow_node ->
      flow_node.id in fired_shell_ids and event_subprocess_shell?(flow_node) and
        interrupting_event_subprocess?(flow_node)
    end)
  end

  defp fired_shell_times(data) do
    data.flow_node_instance_states
    |> Map.values()
    |> Enum.filter(&(&1.flow_node_type == :sub_process))
    |> Enum.group_by(& &1.flow_node_id, & &1.token.created_at)
  end

  defp interrupting_event_subprocess?(esp_node) do
    case esp_start_event_node(esp_node) do
      {:ok, start_event} ->
        esp_start_interrupting?(start_event) or
          match?(%EventDefinition.Compensation{}, start_event.type_data.event_definition)

      :error ->
        false
    end
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
  Whether any armed trigger waits on a Scheduler timer.
  """
  @spec timer_triggers_armed?(State.t()) :: boolean()
  def timer_triggers_armed?(data) do
    Enum.any?(data.event_subprocess_triggers, fn {_node_id, trigger} ->
      trigger.armed? and trigger.timer_ref != nil
    end)
  end

  @doc """
  Re-arm the timer triggers after a Scheduler restart, which lost their
  entries. Fire times are recomputed the same way as on resume: from scope
  activation and the shell FNIs already fired. A one-shot timer that
  already fired stays disarmed.
  """
  @spec rearm_timer_triggers(State.t()) :: State.t()
  def rearm_timer_triggers(data) do
    fired_shell_times = fired_shell_times(data)

    Enum.reduce(data.event_subprocess_triggers, data, fn {subprocess_node_id, trigger},
                                                         accumulator ->
      if trigger.armed? and trigger.timer_ref != nil do
        fired_times = Map.get(fired_shell_times, subprocess_node_id, [])
        rearm_timer_trigger(accumulator, subprocess_node_id, trigger, fired_times)
      else
        accumulator
      end
    end)
  end

  defp rearm_timer_trigger(data, subprocess_node_id, trigger, fired_times) do
    with %FlowNode{} = esp_node <- FlowNodeLookup.find_flow_node(data, subprocess_node_id),
         {:ok, start_event} <- esp_start_event_node(esp_node),
         false <- one_shot_timer_fired?(start_event, fired_times),
         {:ok, rearmed_trigger} <-
           register_timer_trigger(data, trigger, start_event, trigger.timer_spec, fired_times) do
      put_in(data.event_subprocess_triggers[subprocess_node_id], rearmed_trigger)
    else
      {:error, reason} ->
        Logger.warning(
          "Event Subprocess '#{subprocess_node_id}' timer could not be re-armed after a Scheduler restart: #{inspect(reason)}"
        )

        data

      _already_fired ->
        data
    end
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
         %FlowNode{} = esp_node <- FlowNodeLookup.find_flow_node(data, subprocess_node_id) do
      build_fire_action(trigger, esp_node, payload)
    else
      _ -> :noop
    end
  end

  @spec resolve_reactive_trigger(State.t(), EventSubprocessTrigger.t(), map()) :: trigger_action()
  defp resolve_reactive_trigger(data, trigger, payload) do
    case FlowNodeLookup.find_flow_node(data, trigger.subprocess_node_id) do
      %FlowNode{} = esp_node -> build_fire_action(trigger, esp_node, payload)
      _ -> :noop
    end
  end

  @doc """
  Emit `TimerFired` (`kind: :start`) for a fire of an armed ESP timer
  start. A cycle re-arms itself in the Scheduler under the same timer ref,
  honouring its repetition count.
  """
  @spec emit_timer_fired(State.t(), String.t(), String.t()) :: :ok
  def emit_timer_fired(data, subprocess_node_id, timer_ref) do
    case Map.get(data.event_subprocess_triggers, subprocess_node_id) do
      %EventSubprocessTrigger{trigger_kind: :timer, armed?: true} = trigger ->
        EngineEventBus.publish(%Event.TimerFired{
          timer_ref: timer_ref,
          process_instance_id: data.process_instance_id,
          flow_node_instance_id: nil,
          flow_node_id: trigger.start_event_id,
          kind: :start,
          root_process_instance_id: data.root_process_instance_id,
          lane_name: resolve_esp_lane_name(data, subprocess_node_id),
          occurred_at: DateTime.utc_now()
        })

      _not_armed ->
        :ok
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
    case EventSubprocessResolver.find_matching_compensation_start(data.event_subprocess_triggers) do
      {:ok, trigger} ->
        {:ok, resolve_reactive_trigger(data, trigger, %{})}

      :none ->
        :none
    end
  end

  @doc """
  The Compensation-start Event Subprocess at the top level of
  `data.process_model`, read from the model rather than from registered
  triggers: a compensation scope instance registers none.

  Returns `{:ok, esp_node}` or `:none`.
  """
  @spec find_compensation_event_subprocess(State.t()) :: {:ok, FlowNode.t()} | :none
  def find_compensation_event_subprocess(data) do
    data.process_model.flow_nodes
    |> Enum.filter(&event_subprocess_shell?/1)
    |> Enum.find_value(:none, fn esp_node ->
      case esp_start_event_node(esp_node) do
        {:ok, %FlowNode{type_data: %{event_definition: %EventDefinition.Compensation{}}}} ->
          {:ok, esp_node}

        _other ->
          nil
      end
    end)
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

    Enum.reduce(conditional_triggers, {data, []}, fn {node_id, trigger}, {accumulator, actions} ->
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

  defp build_trigger(data, esp_node, fired_times, scope_interrupted?) do
    with {:ok, start_event} <- esp_start_event_node(esp_node),
         trigger_kind when trigger_kind != nil <-
           start_trigger_kind(start_event.type_data.event_definition) do
      is_interrupting = interrupting_event_subprocess?(esp_node)

      if scope_interrupted? or one_shot_timer_fired?(start_event, fired_times) do
        {:dormant, trigger_kind, is_interrupting}
      else
        data
        |> register_trigger_source(esp_node, start_event, fired_times)
        |> resume_condition_edge(fired_times)
      end
    else
      _not_buildable -> :skip
    end
  end

  defp start_trigger_kind(%EventDefinition.Message{}), do: :message
  defp start_trigger_kind(%EventDefinition.Signal{}), do: :signal
  defp start_trigger_kind(%EventDefinition.Timer{}), do: :timer
  defp start_trigger_kind(%EventDefinition.Error{}), do: :error
  defp start_trigger_kind(%EventDefinition.Escalation{}), do: :escalation
  defp start_trigger_kind(%EventDefinition.Conditional{}), do: :conditional
  defp start_trigger_kind(%EventDefinition.Compensation{}), do: :compensation
  defp start_trigger_kind(_event_definition), do: nil

  defp one_shot_timer_fired?(_start_event, []), do: false

  defp one_shot_timer_fired?(%FlowNode{type_data: %{event_definition: definition}}, _fired_times) do
    match?(%EventDefinition.Timer{}, definition) and definition.time_cycle in [nil, ""]
  end

  defp resume_condition_edge(
         {:ok, %EventSubprocessTrigger{trigger_kind: :conditional} = trigger},
         [
           _fired_time | _earlier_fired_times
         ]
       ) do
    {:ok, %{trigger | last_condition_value: true}}
  end

  defp resume_condition_edge(result, _fired_times), do: result

  defp esp_start_event_node(%FlowNode{type_data: %FlowNodeData.SubProcess{flow_nodes: nodes}}) do
    case Enum.filter(nodes || [], &(&1.type == :start_event)) do
      [start_event] -> {:ok, start_event}
      _ -> :error
    end
  end

  defp esp_start_event_node(_esp_node), do: :error

  defp register_trigger_source(data, esp_node, start_event, fired_times) do
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
        register_timer_trigger(data, base, start_event, timer_definition, fired_times)

      %EventDefinition.Error{} = error_definition ->
        {:ok,
         %{base | trigger_kind: :error, error_code: resolve_error_code(data, error_definition)}}

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
      {:ok, message_name} -> register_message_subscription(data, base, start_event, message_name)
      {:error, _reason} -> :skip
    end
  end

  defp register_message_subscription(data, base, start_event, message_name) do
    with {:ok, correlation} <- evaluate_correlation_value(data, base, start_event) do
      {:ok, subscription_id} =
        MessageSubscriptions.register(%{
          process_instance_id: data.process_instance_id,
          root_process_instance_id: data.root_process_instance_id,
          flow_node_instance_id: base.start_event_id,
          flow_node_id: base.subprocess_node_id,
          message_name: message_name,
          expected_correlation_value: correlation,
          kind: :event_subprocess_start,
          via_pid: self(),
          lane_name: resolve_esp_lane_name(data, base.subprocess_node_id)
        })

      {:ok,
       %{
         base
         | trigger_kind: :message,
           message_name: message_name,
           correlation_value: correlation,
           subscription_id: subscription_id
       }}
    end
  end

  defp evaluate_correlation_value(data, base, start_event) do
    context =
      InstanceHandlerDispatch.build_handler_context(data, start_event.id, start_event, self())

    case MessageEventHelper.evaluate_correlation_key(
           data.process_model,
           context,
           data.start_payload || %{}
         ) do
      {:ok, correlation} ->
        {:ok, correlation}

      {:error, {:correlation_expression_failed, reason}} ->
        {:error,
         {:event_subprocess_correlation_failed, base.subprocess_node_id,
          %{expression: data.process_model.correlation_key, reason: reason}}}
    end
  end

  defp register_signal_trigger(data, base, signal_definition) do
    case resolve_signal_name(data, signal_definition) do
      {:ok, signal_name} ->
        {:ok, subscription_id} =
          SignalSubscriptions.register(%{
            process_instance_id: data.process_instance_id,
            root_process_instance_id: data.root_process_instance_id,
            flow_node_instance_id: base.start_event_id,
            flow_node_id: base.subprocess_node_id,
            signal_name: signal_name,
            kind: :event_subprocess_start,
            via_pid: self(),
            lane_name: resolve_esp_lane_name(data, base.subprocess_node_id)
          })

        {:ok,
         %{
           base
           | trigger_kind: :signal,
             signal_name: signal_name,
             subscription_id: subscription_id
         }}

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

  defp register_timer_trigger(data, base, start_event, timer_definition, fired_times) do
    handler_context =
      InstanceHandlerDispatch.build_handler_context(data, start_event.id, start_event, self())

    feel_context = FeelContext.from_handler_context(handler_context, data.start_payload || %{})
    timer_trigger = %{base | trigger_kind: :timer, timer_spec: timer_definition}

    case timer_schedule_request(timer_definition, feel_context, data, fired_times) do
      {:ok, schedule_request} ->
        metadata = %{kind: :event_subprocess_start, subprocess_node_id: base.subprocess_node_id}

        {:ok, timer_ref} =
          Scheduler.schedule(Map.merge(schedule_request, %{target: self(), metadata: metadata}))

        {:ok, %{timer_trigger | timer_ref: timer_ref}}

      :cycle_exhausted ->
        {:ok, %{timer_trigger | armed?: false}}

      {:error, reason} ->
        {:error,
         {:event_subprocess_timer_resolution_failed, base.subprocess_node_id,
          %{expression: timer_spec_text(timer_definition), reason: reason}}}
    end
  end

  defp timer_spec_text(%EventDefinition.Timer{} = timer_definition) do
    Enum.find(
      [timer_definition.time_date, timer_definition.time_duration, timer_definition.time_cycle],
      &(is_binary(&1) and &1 != "")
    )
  end

  # -------------------------------------------------------------------
  # §B private: timer helpers
  # -------------------------------------------------------------------

  defp timer_schedule_request(
         %EventDefinition.Timer{time_date: date},
         feel_context,
         data,
         _fired_times
       )
       when is_binary(date) and date != "" do
    one_shot_schedule_request(:date, date, feel_context, scope_activation(data))
  end

  defp timer_schedule_request(
         %EventDefinition.Timer{time_duration: duration},
         feel_context,
         data,
         _fired_times
       )
       when is_binary(duration) and duration != "" do
    one_shot_schedule_request(:duration, duration, feel_context, scope_activation(data))
  end

  defp timer_schedule_request(
         %EventDefinition.Timer{time_cycle: cycle},
         feel_context,
         data,
         fired_times
       )
       when is_binary(cycle) and cycle != "" do
    with {:ok, cycle_spec} <- TimerSpecResolver.resolve_cycle(cycle, feel_context) do
      cycle_spec
      |> next_cycle_occurrence(scope_activation(data), fired_times, DateTime.utc_now())
      |> cycle_schedule_request()
    end
  end

  defp timer_schedule_request(_timer_definition, _feel_context, _data, _fired_times),
    do: {:error, :missing_timer_spec}

  defp scope_activation(data), do: data.started_at || DateTime.utc_now()

  defp one_shot_schedule_request(kind, spec_string, feel_context, reference_time) do
    with {:ok, fire_at} <-
           TimerSpecResolver.resolve_fire_at(kind, spec_string, feel_context, reference_time) do
      {:ok, %{fire_at: fire_at}}
    end
  end

  defp next_cycle_occurrence(cycle_spec, scope_activation, fired_times, now) do
    first_occurrence = ISO8601.first_fire_at(cycle_spec, scope_activation)

    with {fire_at, pending_spec} <-
           occurrence_after_fires(first_occurrence, cycle_spec, length(fired_times)) do
      ISO8601.skip_missed_occurrences(pending_spec, fire_at, now)
    end
  end

  defp occurrence_after_fires(fire_at, cycle_spec, 0), do: {fire_at, cycle_spec}

  defp occurrence_after_fires(fire_at, cycle_spec, fired_count) do
    with {next_fire_at, next_spec} <- ISO8601.next_cycle_fire(cycle_spec, fire_at) do
      occurrence_after_fires(next_fire_at, next_spec, fired_count - 1)
    end
  end

  defp cycle_schedule_request({fire_at, cycle_spec}) do
    {:ok,
     %{
       fire_at: fire_at,
       cycle_interval: cycle_spec.interval_duration,
       cycle_remaining: cycle_spec.repetitions,
       cycle_anchor: Map.get(cycle_spec, :anchor),
       cycle_occurrence: Map.get(cycle_spec, :occurrence)
     }}
  end

  defp cycle_schedule_request(nil), do: :cycle_exhausted

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
        flow_node = FlowNodeLookup.find_flow_node(data, entry.flow_node_id)

        context =
          InstanceHandlerDispatch.build_handler_context(
            data,
            flow_node_instance_id,
            flow_node,
            self()
          )

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
    with %FlowNode{} = esp_node <- FlowNodeLookup.find_flow_node(data, node_id),
         {:ok, start_event} <- esp_start_event_node(esp_node) do
      context =
        InstanceHandlerDispatch.build_handler_context(data, start_event_id, start_event, self())

      feel_context = FeelContext.from_handler_context(context, data.start_payload || %{})

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

  defp resolve_esp_lane_name(data, subprocess_node_id) do
    LaneResolution.resolve_lane_name(
      data.process_model,
      FlowNodeLookup.find_flow_node(data, subprocess_node_id)
    )
  end

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
      lane_name: resolve_esp_lane_name(data, subprocess_node_id),
      occurred_at: DateTime.utc_now()
    })

    :telemetry.execute(
      [:bfw_engine, :event_subprocess, :triggered],
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

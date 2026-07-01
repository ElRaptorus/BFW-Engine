defmodule EvilEngine.Execution.ProcessInstance do
  @moduledoc """
  The Process Instance runtime — one `:gen_statem` per running PI.

  ## States

      init → :running → :finished
                      → :fatal
                      → :aborted
                      → :error

  The PI orchestrates FNI execution: it spawns handler Tasks under a
  linked `Task.Supervisor`, receives their results, resolves outgoing
  sequence flows, and dispatches successor FNIs. When all paths
  complete (no active FNIs remain), the PI terminates.

  ## Registration

  Each PI registers itself in `EvilEngine.Execution.Registry` under
  its `process_instance_id` for lookup by the public API.

  ## Resume contract (A7)

  When a PI is rehydrated from persistence (item 15), waiting async FNIs
  emit `Event.PluginAsyncFlowNodeRehydrated` on the EngineEventBus.
  `handle_enter/3` is NOT re-dispatched — the owning plugin is expected
  to re-attach interest from its own durable state.

  ## Persistence resilience

  All persistence adapter calls are wrapped with bounded retry
  (`PersistenceRetry.with_retry/3`): exponential backoff with jitter,
  default 5 attempts, ~3.1s total worst case. This is **Layer 2**;
  **Layer 1** is `DBConnection.checkout_retries: 3` at the pool level.

  ### Fail-fast (critical creation writes)

  - `persist_pi_create` — on retry exhaustion, `init/1` returns
    `{:stop, {:persistence_failed, reason}}`. The caller receives
    `{:error, {:persistence_failed, _}}` from `start_link`.
  - `persist_fni_create` — on retry exhaustion, the FNI goes straight to
    `:fatal` via `record_fni_fatal` (handler never starts). The PI
    detects the fatal FNI and transitions to fatal itself.

  ### Fail-fast (critical mid-flight writes in FniLifecycle)

  `transition_to_waiting`, `park_async`, `transition_to_fatal/aborted/interrupted`
  return `{:error, :persistence_failed}` on retry exhaustion. Handlers
  propagate this to the PI as `{:error, :persistence_failed}`, causing
  the PI to fatal the FNI and then itself.

  ### Log-and-continue (PI terminal transitions)

  `persist_pi_finished`, `persist_pi_fatal`, `persist_pi_aborted` retry
  but log-and-continue on exhaustion. The PI is already stopping — orphan
  cleanup reconciles the stale DB row on next boot.
  """

  @behaviour :gen_statem

  require Logger

  import EvilEngine.Execution.ProcessInstance.Helpers

  alias EvilEngine.BPMN.Model.FlowNode
  alias EvilEngine.Events.EngineEventBus
  alias EvilEngine.Events.MessageSubscriptions
  alias EvilEngine.Events.SignalSubscriptions
  alias EvilEngine.Execution.BoundaryAwareHandler
  alias EvilEngine.Execution.FlowNodeResult
  alias EvilEngine.Execution.FlowNodes
  alias EvilEngine.Execution.FniLifecycle
  alias EvilEngine.Execution.HandlerDispatch
  alias EvilEngine.Execution.PayloadCap
  alias EvilEngine.Execution.Persistence, as: PersistenceAdapter
  alias EvilEngine.Execution.PersistenceRetry
  alias EvilEngine.Execution.ProcessInstance.BoundaryOrchestrator
  alias EvilEngine.Execution.ProcessInstance.EventBasedGatewayOrchestrator
  alias EvilEngine.Execution.ProcessInstance.Resumption
  alias EvilEngine.Execution.ProcessInstance.State

  alias EvilEngine.Timers.Scheduler
  alias EvilEngine.Types.Event
  alias EvilEngine.Types.FinalToken
  alias EvilEngine.Types.Token

  @pi_state_running "running"
  @pi_state_finished "finished"
  @pi_state_fatal "fatal"
  @pi_state_aborted "aborted"
  @pi_state_error "error"
  @pi_state_escalated "escalated"
  @shutdown_timeout 5_000

  @type start_opts :: %{
          required(:process_instance_id) => String.t(),
          required(:process_version_id) => String.t(),
          required(:payload) => term(),
          required(:identity) => EvilEngine.Types.Identity.t(),
          optional(:start_event_id) => String.t() | nil,
          optional(:context) => map() | nil,
          optional(:business_key) => String.t() | nil,
          optional(:parent_process_instance_id) => String.t() | nil,
          optional(:root_process_instance_id) => String.t() | nil,
          optional(:triggerer_flow_node_instance_id) => String.t() | nil,
          optional(:notify_pid) => pid() | nil,
          optional(:subprocess_node_id) => String.t() | nil
        }

  # -------------------------------------------------------------------
  # Client API
  # -------------------------------------------------------------------

  @doc false
  def child_spec(opts) do
    %{
      id: {__MODULE__, opts.process_instance_id},
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :temporary,
      shutdown: @shutdown_timeout
    }
  end

  @doc "Start a new PI as a child of the given DynamicSupervisor."
  @spec start_link(start_opts()) :: :gen_statem.start_ret()
  def start_link(opts) do
    process_instance_id = opts.process_instance_id

    :gen_statem.start_link(
      {:via, Registry, {EvilEngine.Execution.Registry, process_instance_id}},
      __MODULE__,
      opts,
      []
    )
  end

  @doc "Finish a waiting User Task / Manual Task."
  @spec finish_user_task(pid(), String.t(), term(), EvilEngine.Types.Identity.t()) ::
          :ok | {:error, term()} | {:error, :payload_too_large, map()}
  def finish_user_task(process_instance_pid, flow_node_instance_id, result, identity) do
    :gen_statem.call(
      process_instance_pid,
      {:finish_user_task, flow_node_instance_id, result, identity}
    )
  end

  @doc "Cancel a waiting User Task."
  @spec cancel_user_task(pid(), String.t(), String.t() | nil, EvilEngine.Types.Identity.t()) ::
          :ok | {:error, term()}
  def cancel_user_task(process_instance_pid, flow_node_instance_id, reason, identity) do
    :gen_statem.call(
      process_instance_pid,
      {:cancel_user_task, flow_node_instance_id, reason, identity}
    )
  end

  @doc "Manually trigger a waiting timer event FNI."
  @spec trigger_timer_event(pid(), String.t()) :: :ok | {:error, term()}
  def trigger_timer_event(process_instance_pid, flow_node_instance_id) do
    :gen_statem.call(process_instance_pid, {:trigger_timer_event, flow_node_instance_id})
  end

  @doc "Abort a running process instance."
  @spec abort(pid(), String.t() | nil, EvilEngine.Types.Identity.t() | nil) ::
          :ok | {:error, term()}
  def abort(process_instance_pid, reason, identity) do
    :gen_statem.call(process_instance_pid, {:abort, reason, identity})
  end

  @doc "Complete a waiting async Service Task FNI with a result."
  @spec finish_async_service_task(pid(), String.t(), term()) :: :ok | {:error, term()}
  def finish_async_service_task(process_instance_pid, flow_node_instance_id, result) do
    :gen_statem.call(
      process_instance_pid,
      {:finish_async_service_task, flow_node_instance_id, result}
    )
  end

  @doc "Fail a waiting async Service Task FNI."
  @spec fail_async_service_task(pid(), String.t(), String.t(), String.t()) ::
          :ok | {:error, term()}
  def fail_async_service_task(
        process_instance_pid,
        flow_node_instance_id,
        error_code,
        error_message
      ) do
    :gen_statem.call(
      process_instance_pid,
      {:fail_async_service_task, flow_node_instance_id, error_code, error_message}
    )
  end

  @doc """
  Force a running PI into fatal state (internal cascade only).

  Used by `CallActivity.handle_fatal/1` to cascade fatal to child PIs.
  """
  @spec force_fatal(pid(), map()) :: :ok | {:error, term()}
  def force_fatal(process_instance_pid, reason) do
    :gen_statem.call(process_instance_pid, {:force_fatal, reason})
  end

  @doc "Update the notify_pid for a running PI (used by Call Activity resume)."
  @spec update_notify_pid(pid(), pid()) :: :ok
  def update_notify_pid(process_instance_pid, new_pid) do
    :gen_statem.call(process_instance_pid, {:update_notify_pid, new_pid})
  end

  @spec build_final_tokens(State.t()) :: [FinalToken.t()]
  defp build_final_tokens(data) do
    data.flow_node_instance_states
    |> Enum.filter(fn {_id, entry} ->
      entry.flow_node_type == :end_event and entry.state in [:finished, :error]
    end)
    |> Enum.map(fn {_id, entry} ->
      flow_node = find_flow_node(data, entry.flow_node_id)

      %FinalToken{
        end_event_id: flow_node.id,
        end_event_name: flow_node.name,
        payload: entry.token.payload
      }
    end)
  end

  # -------------------------------------------------------------------
  # gen_statem callbacks
  # -------------------------------------------------------------------

  @impl true
  def callback_mode, do: :state_functions

  @impl true
  def init(%{resume: true} = opts) do
    data = %State{
      process_instance_id: opts.process_instance_id,
      process_version_id: opts.process_version_id,
      identity: Resumption.rebuild_identity(opts[:started_by]),
      business_key: opts[:business_key],
      parent_process_instance_id: opts[:parent_process_instance_id],
      root_process_instance_id:
        opts[:root_process_instance_id] || opts.process_instance_id,
      triggerer_flow_node_instance_id: opts[:triggerer_flow_node_instance_id],
      started_at: opts[:started_at],
      started_with_context: opts[:started_with_context],
      notify_pid: opts[:notify_pid]
    }

    with {:ok, process_model, definitions} <-
           fetch_process_model(data.process_version_id, opts[:subprocess_node_id]),
         {:ok, task_sup} <- Task.Supervisor.start_link(strategy: :one_for_one),
         {:ok, do_rows} <-
           PersistenceAdapter.adapter().list_data_objects(data.process_instance_id) do
      data = %{
        data
        | process_model: process_model,
          definitions: definitions,
          task_supervisor: task_sup
      }

      cache = Map.new(do_rows, fn row -> {row.data_object_id, row.value} end)
      data = %{data | data_object_cache: cache}

      flow_node_instance_data = opts[:fni_data] || []
      pending_arrivals = opts[:pending_arrivals] || []
      data = Resumption.resume(data, flow_node_instance_data, pending_arrivals, self())

      emit_pi_state_changed(data, nil, :running)
      {:ok, :running, data}
    else
      {:error, reason} ->
        Logger.error("PI #{data.process_instance_id} failed to resume: #{inspect(reason)}")
        {:stop, {reason, data}}
    end
  end

  def init(opts) do
    data = %State{
      process_instance_id: opts.process_instance_id,
      process_version_id: opts.process_version_id,
      identity: opts.identity,
      business_key: opts[:business_key],
      parent_process_instance_id: opts[:parent_process_instance_id],
      root_process_instance_id:
        opts[:root_process_instance_id] || opts.process_instance_id,
      triggerer_flow_node_instance_id: opts[:triggerer_flow_node_instance_id],
      notify_pid: opts[:notify_pid]
    }

    with :ok <- PayloadCap.check(opts[:payload], field: :start_payload),
         :ok <- PayloadCap.check(opts[:context], field: :start_context),
         {:ok, process_model, definitions} <-
           fetch_process_model(data.process_version_id, opts[:subprocess_node_id]),
         {:ok, start_event} <- resolve_start_event(process_model, opts[:start_event_id]),
         {:ok, task_sup} <- Task.Supervisor.start_link(strategy: :one_for_one) do
      now = DateTime.utc_now()

      data = %{
        data
        | process_model: process_model,
          definitions: definitions,
          started_at: now,
          started_with_context: opts[:context],
          task_supervisor: task_sup
      }

      case persist_pi_create(data) do
        {:ok, _} ->
          emit_pi_state_changed(data, nil, :running)

          initial_token = %Token{
            id: generate_id(),
            process_instance_id: data.process_instance_id,
            payload: opts[:payload],
            originating_flow_node_instance_id: nil,
            created_at: now
          }

          data = dispatch_flow_node_instance(data, start_event, initial_token, [])
          {:ok, :running, data, [{:next_event, :internal, :check_initial_dispatch}]}

        {:error, reason} ->
          Logger.error(
            "PI #{data.process_instance_id} creation persistence failed after retries: #{inspect(reason)}"
          )

          {:stop, {:persistence_failed, reason}}
      end
    else
      {:error, :payload_too_large, details} ->
        Logger.warning(
          "PI #{data.process_instance_id} start #{details.field} exceeds cap: #{inspect(details)}"
        )

        {:stop, {:payload_too_large, details}}

      {:error, reason} ->
        Logger.error("PI #{data.process_instance_id} failed to start: #{inspect(reason)}")
        {:stop, {reason, data}}

      {:error, reason, message} ->
        Logger.error("PI #{data.process_instance_id} failed to start: #{message}")
        {:stop, {{reason, message}, data}}
    end
  end

  # -------------------------------------------------------------------
  # :running state
  # -------------------------------------------------------------------

  # Post-init check: detect FNIs that went fatal during synchronous dispatch
  # in init/1 (e.g., FNI creation persistence exhausted). No handler Task
  # was spawned, so no {:fni_result, ...} message will arrive.
  def running(:internal, :check_initial_dispatch, data) do
    maybe_finish_or_continue(data)
  end

  # FNI completed synchronously (stale result guard is inside handle_fni_ok)
  def running(
        :info,
        {:fni_result, flow_node_instance_id, {:ok, %FlowNodeResult{} = result}},
        data
      ) do
    data = handle_fni_ok(data, flow_node_instance_id, result)
    maybe_finish_or_continue(data)
  end

  # Terminate End Event: finish the FNI normally, then interrupt all siblings
  def running(
        :info,
        {:fni_result, flow_node_instance_id, {:terminate, %FlowNodeResult{} = result}},
        data
      ) do
    data = handle_fni_terminate(data, flow_node_instance_id, result)
    maybe_finish_or_continue(data)
  end

  # Error End Event: FNI already persisted as :error by handler, interrupt
  # siblings, transition PI to :error, propagate to parent
  def running(
        :info,
        {:fni_result, flow_node_instance_id,
         {:bpmn_error, error_info, %FlowNodeResult{} = result}},
        data
      ) do
    data = handle_fni_bpmn_error(data, flow_node_instance_id, result, error_info)
    maybe_finish_or_continue(data)
  end

  # Escalation End Event: FNI persisted as :finished by handler.
  # Interrupt siblings, set escalation_info, PI will transition to :escalated.
  def running(
        :info,
        {:fni_result, flow_node_instance_id,
         {:escalation_end, escalation_info, %FlowNodeResult{} = result}},
        data
      ) do
    data = handle_fni_escalation_end(data, flow_node_instance_id, result, escalation_info)
    maybe_finish_or_continue(data)
  end

  # Escalation Intermediate Throw Event: FNI persisted as :finished, token
  # continues on outgoing flows. Propagate escalation to parent scope.
  def running(
        :info,
        {:fni_result, flow_node_instance_id,
         {:escalation_throw, escalation_info, %FlowNodeResult{} = result}},
        data
      ) do
    data = handle_fni_escalation_throw(data, flow_node_instance_id, result, escalation_info)
    maybe_finish_or_continue(data)
  end

  # CA/SP handler Task: child escalation (end) was not caught by a boundary.
  # Propagate escalation end up the scope chain.
  def running(
        :info,
        {:fni_result, flow_node_instance_id,
         {:escalation_end_propagate, escalation_info, %FlowNodeResult{} = result}},
        data
      ) do
    data = handle_fni_escalation_end_propagate(data, flow_node_instance_id, result, escalation_info)
    maybe_finish_or_continue(data)
  end

  # CA/SP handler Task: child escalation (intermediate throw) was not caught.
  # Forward the escalation passthrough to the grandparent scope.
  def running(:info, {:escalation_passthrough, escalation_info}, data) do
    if data.notify_pid do
      send(data.notify_pid, {:child_pi_escalation_passthrough, self(), escalation_info})
    else
      :telemetry.execute(
        [:evil_engine, :escalation, :uncaught],
        %{system_time: System.system_time()},
        %{process_instance_id: data.process_instance_id, escalation_info: escalation_info}
      )
    end

    {:keep_state, data}
  end

  def running(
        :info,
        {:fni_result, flow_node_instance_id, {:wait, %FlowNodeResult{} = result}},
        data
      ) do
    data = handle_fni_wait(data, flow_node_instance_id, result)
    {:keep_state, data}
  end

  # FNI handler returned async — park the FNI in :waiting with async marker.
  # Handlers may include type_properties to persist alongside the async marker.
  def running(
        :info,
        {:fni_result, flow_node_instance_id, {:async, _ref, extra_type_properties}},
        data
      )
      when is_map(extra_type_properties) do
    data = handle_fni_async(data, flow_node_instance_id, extra_type_properties)
    {:keep_state, data}
  end

  def running(:info, {:fni_result, flow_node_instance_id, {:async, _ref}}, data) do
    data = handle_fni_async(data, flow_node_instance_id, %{})
    {:keep_state, data}
  end

  def running(:info, {:fni_result, _flow_node_instance_id, :abort_cascade}, data) do
    _persist_result = persist_pi_aborted(data, "child_aborted")
    emit_pi_state_changed(data, :running, :aborted)
    notify_parent(data, :aborted)
    abort_all_fnis(data)
    {:stop, :normal, data}
  end

  def running(:info, {:fni_result, flow_node_instance_id, {:error, reason}}, data) do
    case Map.get(data.flow_node_instance_states, flow_node_instance_id) do
      %{state: state} when state in [:finished, :fatal, :aborted, :interrupted, :error] ->
        {:keep_state, data}

      nil ->
        {:keep_state, data}

      _entry ->
        data = handle_fni_fatal(data, flow_node_instance_id, reason)
        transition_to_fatal(data, reason)
    end
  end

  # Activity or subscription-model boundary handler returned a boundary
  # result. The handler carries `cancel_activity` explicitly — the PI
  # uses it directly without re-deriving from the model.
  # The optional 5th element `triggerer_fni_id` is the FNI ID of the event
  # that triggered this boundary (message/signal thrower or escalation source).
  def running(
        :info,
        {:fni_result, flow_node_instance_id,
         {:boundary, boundary_node_id, payload, cancel_activity, triggerer_fni_id}},
        data
      ) do
    case Map.get(data.flow_node_instance_states, flow_node_instance_id) do
      %{state: state} when state in [:finished, :fatal, :aborted, :interrupted, :error] ->
        {:keep_state, data}

      nil ->
        {:keep_state, data}

      _entry ->
        data =
          apply_boundary_catch_or_cycle_fire(
            data,
            flow_node_instance_id,
            boundary_node_id,
            payload,
            cancel_activity,
            triggerer_fni_id,
            :catch
          )

        maybe_finish_or_continue(data)
    end
  end

  def running(
        :info,
        {:fni_result, flow_node_instance_id,
         {:boundary, boundary_node_id, payload, cancel_activity}},
        data
      ) do
    case Map.get(data.flow_node_instance_states, flow_node_instance_id) do
      %{state: state} when state in [:finished, :fatal, :aborted, :interrupted, :error] ->
        {:keep_state, data}

      nil ->
        {:keep_state, data}

      _entry ->
        data =
          apply_boundary_catch_or_cycle_fire(
            data,
            flow_node_instance_id,
            boundary_node_id,
            payload,
            cancel_activity,
            nil,
            :catch
          )

        maybe_finish_or_continue(data)
    end
  end

  # Non-interrupting cycle boundary fired an intermediate iteration.
  # Same as {:boundary, ...} except the boundary FNI is NOT finished —
  # it stays alive in :waiting for the next cycle fire.
  def running(
        :info,
        {:fni_result, flow_node_instance_id,
         {:boundary_cycle_fire, boundary_node_id, payload, cancel_activity, triggerer_fni_id}},
        data
      ) do
    case Map.get(data.flow_node_instance_states, flow_node_instance_id) do
      %{state: state} when state in [:finished, :fatal, :aborted, :interrupted, :error] ->
        {:keep_state, data}

      nil ->
        {:keep_state, data}

      _entry ->
        data =
          apply_boundary_catch_or_cycle_fire(
            data,
            flow_node_instance_id,
            boundary_node_id,
            payload,
            cancel_activity,
            triggerer_fni_id,
            :cycle_fire
          )

        maybe_finish_or_continue(data)
    end
  end

  def running(
        :info,
        {:fni_result, flow_node_instance_id,
         {:boundary_cycle_fire, boundary_node_id, payload, cancel_activity}},
        data
      ) do
    case Map.get(data.flow_node_instance_states, flow_node_instance_id) do
      %{state: state} when state in [:finished, :fatal, :aborted, :interrupted, :error] ->
        {:keep_state, data}

      nil ->
        {:keep_state, data}

      _entry ->
        data =
          apply_boundary_catch_or_cycle_fire(
            data,
            flow_node_instance_id,
            boundary_node_id,
            payload,
            cancel_activity,
            nil,
            :cycle_fire
          )

        maybe_finish_or_continue(data)
    end
  end

  def running(
        :info,
        {:call_activity_child_started, flow_node_instance_id, child_process_instance_id,
         child_process_model_id, child_version},
        data
      ) do
    emit_call_activity_child_started(
      data,
      flow_node_instance_id,
      child_process_instance_id,
      child_process_model_id,
      child_version
    )

    {:keep_state, data}
  end

  def running(
        :info,
        {:subprocess_child_started, flow_node_instance_id, child_process_instance_id,
         subprocess_node_id, child_process_model_id, child_version},
        data
      ) do
    emit_subprocess_child_started(
      data,
      flow_node_instance_id,
      child_process_instance_id,
      subprocess_node_id,
      child_process_model_id,
      child_version
    )

    {:keep_state, data}
  end

  # FNI Task process crashed (crash isolation)
  def running(:info, {:DOWN, _ref, :process, pid, reason}, data) when reason != :normal do
    case find_fni_by_pid(data, pid) do
      {flow_node_instance_id, _entry} ->
        data = handle_fni_fatal(data, flow_node_instance_id, {:crash, reason})
        transition_to_fatal(data, {:fni_crash, flow_node_instance_id, reason})

      nil ->
        {:keep_state, data}
    end
  end

  # Ignore normal exits from completed Task processes
  def running(:info, {:DOWN, _ref, :process, _pid, :normal}, data) do
    {:keep_state, data}
  end

  def running({:call, from}, {:finish_user_task, flow_node_instance_id, result, _identity}, data) do
    case Map.get(data.flow_node_instance_states, flow_node_instance_id) do
      %{state: :waiting} = entry ->
        complete_waiting_fni(data, from, flow_node_instance_id, entry, result)

      %{state: state} ->
        {:keep_state, data, [{:reply, from, {:error, normalize_terminal_state_error(state)}}]}

      nil ->
        {:keep_state, data, [{:reply, from, {:error, :fni_not_found}}]}
    end
  end

  def running({:call, from}, {:cancel_user_task, flow_node_instance_id, reason, _identity}, data) do
    case Map.get(data.flow_node_instance_states, flow_node_instance_id) do
      %{state: :waiting} = entry ->
        cancel_waiting_fni(data, flow_node_instance_id, entry, reason)

        data = handle_fni_aborted(data, flow_node_instance_id, reason)
        persist_pi_aborted(data, reason)
        emit_pi_state_changed(data, :running, :aborted)
        notify_parent(data, :aborted)
        abort_all_fnis(data)
        {:stop_and_reply, :normal, [{:reply, from, :ok}], data}

      %{state: state} ->
        {:keep_state, data, [{:reply, from, {:error, normalize_terminal_state_error(state)}}]}

      nil ->
        {:keep_state, data, [{:reply, from, {:error, :fni_not_found}}]}
    end
  end

  def running({:call, from}, {:finish_async_service_task, flow_node_instance_id, result}, data) do
    case validate_async_fni(data, flow_node_instance_id) do
      {:ok, entry} ->
        complete_waiting_fni(data, from, flow_node_instance_id, entry, result)

      {:error, reason} ->
        {:keep_state, data, [{:reply, from, {:error, reason}}]}
    end
  end

  def running(
        {:call, from},
        {:fail_async_service_task, flow_node_instance_id, error_code, error_message},
        data
      ) do
    case validate_async_fni(data, flow_node_instance_id) do
      {:ok, _entry} ->
        reason = %{error_code: error_code, error_message: error_message}
        data = handle_fni_fatal(data, flow_node_instance_id, reason)
        transition_to_fatal_with_reply(data, reason, from)

      {:error, reason} ->
        {:keep_state, data, [{:reply, from, {:error, reason}}]}
    end
  end

  # Force-fatal call — used by CallActivity.handle_fatal/1 to cascade fatal
  # to child PIs. Mirrors the internal transition_to_fatal path but as a
  # synchronous gen_statem.call so the parent blocks until the child is dead.
  def running({:call, from}, {:force_fatal, reason}, data) do
    _persist_result = persist_pi_fatal(data, reason)
    emit_pi_state_changed(data, :running, :fatal)
    notify_parent(data, {:fatal, reason})
    fatal_all_fnis(data)
    {:stop_and_reply, :normal, [{:reply, from, :ok}], data}
  end

  def running({:call, from}, {:trigger_timer_event, flow_node_instance_id}, data) do
    case Map.get(data.flow_node_instance_states, flow_node_instance_id) do
      %{state: state, pid: pid} when state in [:active, :waiting] and pid != nil ->
        Scheduler.fire_now_for_target(pid)
        {:keep_state, data, [{:reply, from, :ok}]}

      _other ->
        {:keep_state, data, [{:reply, from, {:error, :fni_not_active_or_found}}]}
    end
  end

  def running({:call, from}, {:abort, reason, _identity}, data) do
    _persist_result = persist_pi_aborted(data, reason)
    emit_pi_state_changed(data, :running, :aborted)
    notify_parent(data, :aborted)
    abort_all_fnis(data)
    {:stop_and_reply, :normal, [{:reply, from, :ok}], data}
  end

  # UpdateNotifyPid — used by Call Activity handler to re-establish
  # parent notification after engine restart.
  def running({:call, from}, {:update_notify_pid, new_pid}, data) do
    {:keep_state, %{data | notify_pid: new_pid}, [{:reply, from, :ok}]}
  end

  # Terminal PI states (:finished, :fatal, :aborted). The PI stops
  # via :stop_and_reply when it reaches any of these. These clauses
  # exist as safety nets for messages that arrive during shutdown.

  def finished({:call, from}, _request, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :process_finished}}]}
  end

  def finished(:info, _msg, _data), do: :keep_state_and_data

  def fatal({:call, from}, _request, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :process_fatal}}]}
  end

  def fatal(:info, _msg, _data), do: :keep_state_and_data

  def aborted({:call, from}, _request, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :process_aborted}}]}
  end

  def aborted(:info, _msg, _data), do: :keep_state_and_data

  # -------------------------------------------------------------------
  # Internal: Start Event resolution
  # -------------------------------------------------------------------

  defp resolve_start_event(process_model, start_event_id) do
    case resolve_typed_start_event(process_model, start_event_id) do
      {:ok, _node} = result ->
        result

      :not_typed ->
        untyped_starts =
          Enum.filter(process_model.flow_nodes, fn node ->
            node.type == :start_event and
              match?(
                %EvilEngine.BPMN.Model.EventDefinition.None{},
                node.type_data.event_definition
              )
          end)

        do_resolve_start_event(untyped_starts, start_event_id, process_model.id)
    end
  end

  defp resolve_typed_start_event(_process_model, nil), do: :not_typed

  defp resolve_typed_start_event(process_model, start_event_id) do
    case Enum.find(process_model.flow_nodes, fn node ->
           node.type == :start_event and node.id == start_event_id and
             not match?(
               %EvilEngine.BPMN.Model.EventDefinition.None{},
               node.type_data.event_definition
             )
         end) do
      nil -> :not_typed
      typed_start -> {:ok, typed_start}
    end
  end

  defp do_resolve_start_event([], _start_event_id, process_id) do
    {:error, :no_start_event, "Process '#{process_id}' has no untyped Start Event."}
  end

  defp do_resolve_start_event([single], nil, _process_id) do
    {:ok, single}
  end

  defp do_resolve_start_event([single], id, _process_id) when id == single.id do
    {:ok, single}
  end

  defp do_resolve_start_event([single], id, process_id) do
    {:error, :start_event_not_found,
     "Start Event '#{id}' not found in process '#{process_id}'. Available: #{single.id}"}
  end

  defp do_resolve_start_event(starts, nil, process_id) when length(starts) > 1 do
    ids = Enum.map_join(starts, ", ", & &1.id)

    {:error, :ambiguous_start_event,
     "Process '#{process_id}' has #{length(starts)} start events, " <>
       "but no startEventId was provided. Available: #{ids}"}
  end

  defp do_resolve_start_event(starts, id, process_id) do
    case Enum.find(starts, &(&1.id == id)) do
      nil ->
        ids = Enum.map_join(starts, ", ", & &1.id)

        {:error, :start_event_not_found,
         "Start Event '#{id}' not found in process '#{process_id}'. Available: #{ids}"}

      found ->
        {:ok, found}
    end
  end

  # -------------------------------------------------------------------
  # Internal: FNI dispatch cycle
  # -------------------------------------------------------------------

  defp dispatch_flow_node_instance(
         data,
         %FlowNode{} = flow_node,
         %Token{} = token,
         previous_flow_node_instance_ids
       ) do
    case join_gateway_check(flow_node, data.process_model) do
      {:join, :parallel_gateway, required} ->
        dispatch_parallel_join(data, flow_node, token, previous_flow_node_instance_ids, required)

      {:join, :inclusive_gateway, _incoming_count} ->
        dispatch_inclusive_join(data, flow_node, token, previous_flow_node_instance_ids)

      :not_join ->
        dispatch_flow_node_instance_immediate(
          data,
          flow_node,
          token,
          previous_flow_node_instance_ids
        )
    end
  end

  defp join_gateway_check(%FlowNode{type: gateway_type} = flow_node, process_model)
       when gateway_type in [:parallel_gateway, :inclusive_gateway] do
    incoming_count = count_flows(flow_node.incoming, flow_node.id, :incoming, process_model)
    outgoing_count = count_flows(flow_node.outgoing, flow_node.id, :outgoing, process_model)

    if incoming_count > 1 and outgoing_count <= 1 do
      {:join, gateway_type, incoming_count}
    else
      :not_join
    end
  end

  defp join_gateway_check(_flow_node, _process_model), do: :not_join

  defp count_flows(ids, _node_id, _direction, _process_model) when is_list(ids) and ids != [] do
    length(ids)
  end

  defp count_flows(_ids, node_id, :incoming, process_model) do
    Enum.count(process_model.sequence_flows || [], &(&1.target_ref == node_id))
  end

  defp count_flows(_ids, node_id, :outgoing, process_model) do
    Enum.count(process_model.sequence_flows || [], &(&1.source_ref == node_id))
  end

  defp dispatch_parallel_join(data, flow_node, token, previous_flow_node_instance_ids, required) do
    incoming_flow_id = resolve_incoming_sequence_flow_id(data, flow_node, previous_flow_node_instance_ids)

    case Map.get(data.join_routing, flow_node.id) do
      nil ->
        dispatch_join_first_token(
          data, flow_node, token, previous_flow_node_instance_ids,
          required, :parallel_gateway, incoming_flow_id
        )

      %{fni_id: fni_id} ->
        route_token_to_join_handler(data, fni_id, flow_node, token, previous_flow_node_instance_ids, incoming_flow_id)
    end
  end

  defp dispatch_inclusive_join(data, flow_node, token, previous_flow_node_instance_ids) do
    incoming_flow_id =
      resolve_incoming_sequence_flow_id(data, flow_node, previous_flow_node_instance_ids)

    incoming_count =
      count_flows(flow_node.incoming, flow_node.id, :incoming, data.process_model)

    case Map.get(data.join_routing, flow_node.id) do
      nil ->
        dispatch_join_first_token(
          data, flow_node, token, previous_flow_node_instance_ids,
          incoming_count, :inclusive_gateway, incoming_flow_id
        )

      %{fni_id: fni_id, arrived_via_flow_ids: arrived_via} ->
        duplicate? = MapSet.member?(arrived_via, incoming_flow_id) and incoming_flow_id != "unknown"

        if duplicate? do
          record_fni_fatal(data, fni_id, flow_node, token, previous_flow_node_instance_ids, %{
            "error_code" => "duplicate_join_arrival",
            "message" =>
              "Duplicate token arrival at inclusive join '#{flow_node.id}' " <>
                "via sequence flow '#{incoming_flow_id}'"
          })
        else
          route_subsequent_inclusive_token(
            data, fni_id, flow_node, token, previous_flow_node_instance_ids, incoming_flow_id
          )
        end
    end
  end

  defp dispatch_join_first_token(data, flow_node, token, previous_flow_node_instance_ids, required, gateway_type, incoming_flow_id) do
    flow_node_instance_id = generate_id()
    lane_name = resolve_lane_name(data.process_model, flow_node)

    case persist_fni_create(
           data,
           flow_node_instance_id,
           flow_node,
           token,
           lane_name,
           previous_flow_node_instance_ids
         ) do
      {:ok, _} ->
        emit_fni_started(data, flow_node_instance_id, flow_node, previous_flow_node_instance_ids)

        source_flow_node_instance_id = List.first(previous_flow_node_instance_ids)

        join_metadata = %{
          incoming_flow_id: incoming_flow_id,
          source_flow_node_instance_id: source_flow_node_instance_id
        }

        data =
          case HandlerDispatch.handler_for(flow_node) do
            {:ok, handler_module} ->
              spawn_join_fni_task(
                data,
                flow_node_instance_id,
                flow_node,
                token,
                previous_flow_node_instance_ids,
                handler_module,
                join_metadata
              )

            {:error, _} ->
              record_fni_fatal(
                data,
                flow_node_instance_id,
                flow_node,
                token,
                previous_flow_node_instance_ids,
                %{
                  "error_code" => "unsupported_element",
                  "message" => "Unsupported element type: #{flow_node.type}"
                }
              )
          end

        routing_entry = %{
          fni_id: flow_node_instance_id,
          gateway_type: gateway_type,
          required: required,
          arrived_via_flow_ids: MapSet.new([incoming_flow_id])
        }

        put_in(data.join_routing[flow_node.id], routing_entry)

      {:error, _reason} ->
        record_fni_fatal(data, generate_id(), flow_node, token, previous_flow_node_instance_ids, %{
          "error_code" => "persistence_failed",
          "message" => "Failed to persist flow node instance"
        })
    end
  end

  defp spawn_join_fni_task(data, flow_node_instance_id, flow_node, token, previous_flow_node_instance_ids, handler_module, join_metadata) do
    process_instance_pid = self()

    handler_context =
      build_handler_context(data, flow_node_instance_id, flow_node, process_instance_pid)
      |> Map.put(:join_metadata, join_metadata)

    case Task.Supervisor.start_child(data.task_supervisor, fn ->
           result =
             BoundaryAwareHandler.wrap_enter(handler_module, flow_node, token, handler_context)

           dispatch_handler_result(process_instance_pid, flow_node_instance_id, result)
         end) do
      {:ok, task_pid} ->
        Process.monitor(task_pid)

        entry = %{
          pid: task_pid,
          flow_node_id: flow_node.id,
          flow_node_type: flow_node.type,
          event_type: nil,
          state: :active,
          token: token,
          previous_flow_node_instance_ids: previous_flow_node_instance_ids,
          type_properties: %{},
          next_flow_node_ids: []
        }

        put_in(data.flow_node_instance_states[flow_node_instance_id], entry)

      {:error, reason} ->
        Logger.error("Failed to start join FNI task for #{flow_node.id}: #{inspect(reason)}")

        record_fni_fatal(
          data,
          flow_node_instance_id,
          flow_node,
          token,
          previous_flow_node_instance_ids,
          %{
            "error_code" => "task_start_failed",
            "message" => "Failed to start task process for flow node '#{flow_node.id}'"
          }
        )
    end
  end

  defp route_subsequent_inclusive_token(data, fni_id, flow_node, token, previous_flow_node_instance_ids, incoming_flow_id) do
    data = update_in(data.join_routing[flow_node.id], fn routing ->
      %{routing | arrived_via_flow_ids: MapSet.put(routing.arrived_via_flow_ids, incoming_flow_id)}
    end)

    route_token_to_join_handler(data, fni_id, flow_node, token, previous_flow_node_instance_ids, incoming_flow_id)
  end

  defp route_token_to_join_handler(data, fni_id, _flow_node, token, previous_flow_node_instance_ids, incoming_flow_id) do
    case Map.get(data.flow_node_instance_states, fni_id) do
      %{pid: pid} when is_pid(pid) ->
        send(pid, {:join_token_arrived, token, previous_flow_node_instance_ids, incoming_flow_id})
        data

      _ ->
        data
    end
  end

  defp dispatch_flow_node_instance_immediate(
         data,
         %FlowNode{} = flow_node,
         %Token{} = token,
         previous_flow_node_instance_ids
       ) do
    flow_node_instance_id = generate_id()
    lane_name = resolve_lane_name(data.process_model, flow_node)

    case persist_fni_create(
           data,
           flow_node_instance_id,
           flow_node,
           token,
           lane_name,
           previous_flow_node_instance_ids
         ) do
      {:ok, _} ->
        emit_fni_started(data, flow_node_instance_id, flow_node, previous_flow_node_instance_ids)

        data =
          case HandlerDispatch.handler_for(flow_node) do
            {:ok, handler_module} ->
              spawn_fni_task(
                data,
                flow_node_instance_id,
                flow_node,
                token,
                previous_flow_node_instance_ids,
                handler_module
              )

            {:error, {:unsupported_event_definition, unsupported_flow_node}} ->
              record_fni_fatal(
                data,
                flow_node_instance_id,
                flow_node,
                token,
                previous_flow_node_instance_ids,
                build_unsupported_event_definition_error_info(unsupported_flow_node)
              )

            {:error, :unsupported_element} ->
              record_fni_fatal(
                data,
                flow_node_instance_id,
                flow_node,
                token,
                previous_flow_node_instance_ids,
                %{
                  "error_code" => "unsupported_element",
                  "message" => "Unsupported element type: #{flow_node.type}"
                }
              )
          end

        boundary_nodes = BoundaryOrchestrator.resolve_subscription_boundaries(data, flow_node)

        Enum.reduce(boundary_nodes, data, fn boundary_node, accumulator ->
          dispatch_boundary_fni(accumulator, boundary_node, flow_node_instance_id, token)
        end)

      {:error, _reason} ->
        record_fni_fatal(
          data,
          flow_node_instance_id,
          flow_node,
          token,
          previous_flow_node_instance_ids,
          %{
            "error_code" => "persistence_failed",
            "message" => "Failed to persist flow node instance"
          }
        )
    end
  end

  defp spawn_fni_task(
         data,
         flow_node_instance_id,
         flow_node,
         token,
         previous_flow_node_instance_ids,
         handler_module
       ) do
    process_instance_pid = self()

    handler_context =
      build_handler_context(data, flow_node_instance_id, flow_node, process_instance_pid)

    case Task.Supervisor.start_child(data.task_supervisor, fn ->
           result =
             BoundaryAwareHandler.wrap_enter(handler_module, flow_node, token, handler_context)

           dispatch_handler_result(process_instance_pid, flow_node_instance_id, result)
         end) do
      {:ok, task_pid} ->
        Process.monitor(task_pid)

        entry = %{
          pid: task_pid,
          flow_node_id: flow_node.id,
          flow_node_type: flow_node.type,
          event_type: extract_event_type(flow_node),
          state: :active,
          token: token,
          previous_flow_node_instance_ids: previous_flow_node_instance_ids,
          type_properties: %{},
          next_flow_node_ids: []
        }

        put_in(data.flow_node_instance_states[flow_node_instance_id], entry)

      {:error, reason} ->
        Logger.error("Failed to start FNI task for #{flow_node.id}: #{inspect(reason)}")

        record_fni_fatal(
          data,
          flow_node_instance_id,
          flow_node,
          token,
          previous_flow_node_instance_ids,
          %{
            "error_code" => "task_start_failed",
            "message" => "Failed to start task process for flow node '#{flow_node.id}'"
          }
        )
    end
  end

  defp record_fni_fatal(
         data,
         flow_node_instance_id,
         flow_node,
         token,
         previous_flow_node_instance_ids,
         error_details
       ) do
    _persist_result =
      FniLifecycle.transition_to_fatal(
        flow_node_instance_id,
        data.process_instance_id,
        error_details,
        flow_node,
        %{},
        resolve_lane_name(data.process_model, flow_node),
        data.root_process_instance_id
      )

    entry = %{
      pid: nil,
      flow_node_id: flow_node.id,
      flow_node_type: flow_node.type,
      event_type: extract_event_type(flow_node),
      state: :fatal,
      token: token,
      previous_flow_node_instance_ids: previous_flow_node_instance_ids,
      type_properties: %{error: true},
      next_flow_node_ids: []
    }

    put_in(data.flow_node_instance_states[flow_node_instance_id], entry)
  end

  # -------------------------------------------------------------------
  # Internal: Async FNI handling
  # -------------------------------------------------------------------

  # Async FNIs do not carry `next_flow_node_ids` at park time.
  # Routing is resolved later by the handler's `handle_complete/4`
  # when the external actor calls `finish_async_service_task`.
  #
  # `pid` is cleared to `nil` so that a late `{:DOWN, :noproc}` from
  # the handler Task (which may have exited before `Process.monitor`
  # was called) does not match in `find_fni_by_pid` and cause a
  # false fatal transition. For CallActivity continuations, the
  # Task is still alive at this point but the subsequent final result
  # will be delivered as a separate `{:fni_result, ...}` message.
  defp handle_fni_async(data, flow_node_instance_id, extra_type_properties) do
    case Map.get(data.flow_node_instance_states, flow_node_instance_id) do
      %{state: state} when state in [:finished, :fatal, :aborted, :interrupted, :error] ->
        data

      nil ->
        data

      entry ->
        do_handle_fni_async(data, flow_node_instance_id, entry, extra_type_properties)
    end
  end

  defp do_handle_fni_async(data, flow_node_instance_id, entry, extra_type_properties) do
    type_properties = Map.merge(%{async: true}, Map.delete(extra_type_properties, :persisted))

    needs_registry =
      not is_map_key(extra_type_properties, :host_flow_node_instance_id) and
        not is_map_key(extra_type_properties, :fire_at) and
        not is_map_key(extra_type_properties, :join_gateway) and
        not is_map_key(extra_type_properties, :awaiting_condition)

    _ =
      if needs_registry do
        Registry.register(
          EvilEngine.Execution.Registry,
          {:fni, flow_node_instance_id},
          :async
        )
      end

    emit_fni_state_changed(data, flow_node_instance_id, entry, :active, :waiting)

    task_alive = entry.pid != nil and Process.alive?(entry.pid)

    data =
      put_in(data.flow_node_instance_states[flow_node_instance_id], %{
        entry
        | state: :waiting,
          pid: if(task_alive, do: entry.pid, else: nil),
          type_properties: type_properties
      })

    maybe_register_conditional_waiter(data, flow_node_instance_id, entry, extra_type_properties)
  end

  defp maybe_register_conditional_waiter(data, fni_id, entry, extra_type_properties) do
    if Map.get(extra_type_properties, :awaiting_condition) do
      flow_node = find_flow_node(data, entry.flow_node_id)
      {:ok, handler_module} = HandlerDispatch.handler_for(flow_node)
      token_payload = entry.token.payload

      is_boundary = Map.has_key?(extra_type_properties, :host_flow_node_instance_id)

      opts =
        if is_boundary do
          %{
            position: :boundary,
            cancel_activity: Map.get(extra_type_properties, :cancel_activity),
            host_fni_id: Map.get(extra_type_properties, :host_flow_node_instance_id)
          }
        else
          %{position: :intermediate_catch}
        end

      data = register_conditional_waiter(data, fni_id, flow_node, handler_module, token_payload, opts)

      waiter = Map.get(data.conditional_waiters, fni_id)
      evaluate_single_conditional_waiter(data, fni_id, waiter)
    else
      data
    end
  end

  defp validate_async_fni(data, flow_node_instance_id) do
    case Map.get(data.flow_node_instance_states, flow_node_instance_id) do
      nil ->
        {:error, :flow_node_instance_not_found}

      %{state: :finished} ->
        {:error, :fni_already_finished}

      %{state: :aborted} ->
        {:error, :fni_already_aborted}

      %{state: :interrupted} ->
        {:error, :fni_already_interrupted}

      %{state: :fatal} ->
        {:error, :fni_already_fatal}

      %{state: :waiting} = entry ->
        validate_async_waiting_entry(entry)

      %{state: _other} ->
        {:error, :fni_not_waiting}
    end
  end

  defp validate_async_waiting_entry(entry) do
    type_props = Map.get(entry, :type_properties, %{})
    is_async = Map.get(type_props, :async, false) || Map.get(type_props, "async", false)

    cond do
      entry.flow_node_type != :service_task ->
        {:error, :fni_not_service_task}

      not is_async ->
        {:error, :fni_not_async}

      true ->
        {:ok, entry}
    end
  end

  defp transition_to_fatal_with_reply(data, reason, from) do
    _persist_result = persist_pi_fatal(data, reason)
    emit_pi_state_changed(data, :running, :fatal)
    notify_parent(data, {:fatal, reason})
    fatal_all_fnis(data)
    {:stop_and_reply, :normal, [{:reply, from, :ok}], data}
  end

  # -------------------------------------------------------------------
  # Internal: Error normalization
  # -------------------------------------------------------------------

  defp normalize_terminal_state_error(:finished), do: :fni_already_finished
  defp normalize_terminal_state_error(:aborted), do: :fni_already_aborted
  defp normalize_terminal_state_error(:interrupted), do: :fni_already_interrupted
  defp normalize_terminal_state_error(:fatal), do: :fni_already_fatal
  defp normalize_terminal_state_error(:error), do: :fni_already_error
  defp normalize_terminal_state_error(_other), do: :fni_not_waiting

  # -------------------------------------------------------------------
  # Internal: FNI completion handling
  # -------------------------------------------------------------------

  defp handle_fni_ok(data, flow_node_instance_id, %FlowNodeResult{} = result) do
    case Map.get(data.flow_node_instance_states, flow_node_instance_id) do
      %{state: state} when state in [:finished, :fatal, :aborted, :interrupted, :error] ->
        data

      nil ->
        data

      _entry ->
        do_handle_fni_ok(data, flow_node_instance_id, result)
    end
  end

  defp do_handle_fni_ok(data, flow_node_instance_id, %FlowNodeResult{} = result) do
    entry = Map.fetch!(data.flow_node_instance_states, flow_node_instance_id)
    output_payload = result.output_payload || entry.token.payload

    cache_updates =
      get_in(result.metadata, [:lifecycle, Access.key(:data_object_cache_updates, %{})])

    data = %{data | data_object_cache: Map.merge(data.data_object_cache, cache_updates)}
    dispatch_successors(data, flow_node_instance_id, entry, output_payload, result)
  end

  defp dispatch_successors(data, flow_node_instance_id, entry, output_payload, result) do
    data =
      EventBasedGatewayOrchestrator.cancel_sibling_catch_flow_node_instances(
        data,
        flow_node_instance_id
      )

    new_token = %Token{
      id: generate_id(),
      process_instance_id: data.process_instance_id,
      payload: output_payload,
      originating_flow_node_instance_id: flow_node_instance_id,
      created_at: DateTime.utc_now()
    }

    node_index = Map.new(data.process_model.flow_nodes, &{&1.id, &1})

    targets =
      result.next_flow_node_ids
      |> Enum.map(&Map.get(node_index, &1))
      |> Enum.reject(&is_nil/1)

    data =
      put_in(data.flow_node_instance_states[flow_node_instance_id], %{
        entry
        | state: :finished,
          pid: nil,
          token: %{entry.token | payload: output_payload}
      })

    data =
      if BoundaryOrchestrator.has_boundary_fnis?(data, flow_node_instance_id) do
        BoundaryOrchestrator.cancel_boundary_fnis_for_host(data, flow_node_instance_id)
      else
        data
      end

    Enum.reduce(targets, data, fn target_node, acc ->
      dispatch_flow_node_instance(acc, target_node, new_token, [flow_node_instance_id])
    end)
  end

  defp handle_fni_wait(data, flow_node_instance_id, %FlowNodeResult{} = result) do
    case Map.get(data.flow_node_instance_states, flow_node_instance_id) do
      %{state: state} when state in [:finished, :fatal, :aborted, :interrupted, :error] ->
        data

      nil ->
        data

      entry ->
        emit_fni_state_changed(data, flow_node_instance_id, entry, :active, :waiting)

        merged_type_properties =
          Map.merge(entry.type_properties || %{}, result.type_properties || %{})

        _persist_result =
          if result.metadata[:awaiting_condition] do
            FniLifecycle.transition_to_waiting_by_id(
              flow_node_instance_id,
              merged_type_properties
            )
          end

        data =
          put_in(data.flow_node_instance_states[flow_node_instance_id], %{
            entry
            | state: :waiting,
              pid: nil,
              type_properties: merged_type_properties,
              next_flow_node_ids: result.next_flow_node_ids
          })

        if result.metadata[:awaiting_condition] do
          maybe_register_conditional_waiter_from_wait(data, flow_node_instance_id, entry)
        else
          data
        end
    end
  end

  defp handle_fni_fatal(data, flow_node_instance_id, reason) do
    case Map.get(data.flow_node_instance_states, flow_node_instance_id) do
      nil ->
        data

      entry ->
        flow_node = find_flow_node(data, entry.flow_node_id)
        error_info = build_error_info(reason)
        lane_name = resolve_lane_name(data.process_model, flow_node)

        _persist_result =
          FniLifecycle.transition_to_fatal(
            flow_node_instance_id,
            data.process_instance_id,
            error_info,
            flow_node,
            Map.get(entry, :type_properties, %{}),
            lane_name,
            data.root_process_instance_id
          )

        data =
          put_in(data.flow_node_instance_states[flow_node_instance_id], %{
            entry
            | state: :fatal,
              pid: nil
          })

        data = unregister_conditional_waiter(data, flow_node_instance_id)

        if BoundaryOrchestrator.has_boundary_fnis?(data, flow_node_instance_id) do
          BoundaryOrchestrator.cancel_boundary_fnis_for_host(data, flow_node_instance_id)
        else
          data
        end
    end
  end

  defp handle_fni_aborted(data, flow_node_instance_id, reason) do
    entry = Map.fetch!(data.flow_node_instance_states, flow_node_instance_id)
    flow_node = find_flow_node(data, entry.flow_node_id)

    _persist_result =
      FniLifecycle.transition_to_aborted(
        flow_node_instance_id,
        data.process_instance_id,
        reason,
        flow_node,
        Map.get(entry, :type_properties, %{}),
        resolve_lane_name(data.process_model, flow_node),
        data.root_process_instance_id
      )

    data =
      put_in(data.flow_node_instance_states[flow_node_instance_id], %{
        entry
        | state: :aborted,
          pid: nil
      })

    unregister_conditional_waiter(data, flow_node_instance_id)
  end

  defp handle_fni_interrupted(data, flow_node_instance_id, reason) do
    entry = Map.fetch!(data.flow_node_instance_states, flow_node_instance_id)
    flow_node = find_flow_node(data, entry.flow_node_id)

    if entry.pid != nil, do: Process.exit(entry.pid, :kill)

    _persist_result =
      FniLifecycle.transition_to_interrupted(
        flow_node_instance_id,
        data.process_instance_id,
        reason,
        flow_node,
        Map.get(entry, :type_properties, %{}),
        resolve_lane_name(data.process_model, flow_node),
        data.root_process_instance_id
      )

    invoke_optional_callback(flow_node, :handle_aborted, [entry])

    data = unregister_conditional_waiter(data, flow_node_instance_id)

    put_in(data.flow_node_instance_states[flow_node_instance_id], %{
      entry
      | state: :interrupted,
        pid: nil
    })
  end

  defp handle_fni_terminate(data, flow_node_instance_id, %FlowNodeResult{} = result) do
    case Map.get(data.flow_node_instance_states, flow_node_instance_id) do
      %{state: state} when state in [:finished, :fatal, :aborted, :interrupted, :error] ->
        data

      nil ->
        data

      _entry ->
        data = do_handle_fni_ok(data, flow_node_instance_id, result)
        interrupt_remaining_fnis(data, flow_node_instance_id, :terminated_by_end_event)
    end
  end

  defp handle_fni_bpmn_error(data, flow_node_instance_id, %FlowNodeResult{} = result, error_info) do
    case Map.get(data.flow_node_instance_states, flow_node_instance_id) do
      %{state: state} when state in [:finished, :fatal, :aborted, :interrupted, :error] ->
        data

      nil ->
        data

      _entry ->
        data = record_fni_error(data, flow_node_instance_id, result)
        data = error_all_remaining_fnis(data, flow_node_instance_id)
        %{data | bpmn_error_info: error_info}
    end
  end

  defp handle_fni_escalation_end(data, flow_node_instance_id, %FlowNodeResult{} = result, escalation_info) do
    case Map.get(data.flow_node_instance_states, flow_node_instance_id) do
      %{state: state} when state in [:finished, :fatal, :aborted, :interrupted, :error] ->
        data

      nil ->
        data

      entry ->
        emit_escalation_raised(data, flow_node_instance_id, entry.flow_node_id, escalation_info, :end_event)
        data = do_handle_fni_ok(data, flow_node_instance_id, result)
        data = interrupt_remaining_fnis(data, flow_node_instance_id, :escalation_end_event)
        %{data | escalation_info: escalation_info}
    end
  end

  defp handle_fni_escalation_throw(data, flow_node_instance_id, %FlowNodeResult{} = result, escalation_info) do
    case Map.get(data.flow_node_instance_states, flow_node_instance_id) do
      %{state: state} when state in [:finished, :fatal, :aborted, :interrupted, :error] ->
        data

      nil ->
        data

      entry ->
        emit_escalation_raised(data, flow_node_instance_id, entry.flow_node_id, escalation_info, :intermediate_throw)
        data = do_handle_fni_ok(data, flow_node_instance_id, result)
        notify_parent(data, {:escalation_passthrough, escalation_info})
        data
    end
  end

  defp handle_fni_escalation_end_propagate(data, flow_node_instance_id, %FlowNodeResult{} = result, escalation_info) do
    case Map.get(data.flow_node_instance_states, flow_node_instance_id) do
      %{state: state} when state in [:finished, :fatal, :aborted, :interrupted, :error] ->
        data

      nil ->
        data

      _entry ->
        data = do_handle_fni_ok(data, flow_node_instance_id, result)
        data = interrupt_remaining_fnis(data, flow_node_instance_id, :escalation_end_event)
        %{data | escalation_info: escalation_info}
    end
  end

  defp record_fni_error(data, flow_node_instance_id, %FlowNodeResult{} = result) do
    entry = Map.fetch!(data.flow_node_instance_states, flow_node_instance_id)
    output_payload = result.output_payload || entry.token.payload

    cache_updates =
      get_in(result.metadata, [:lifecycle, Access.key(:data_object_cache_updates, %{})])

    data = %{data | data_object_cache: Map.merge(data.data_object_cache, cache_updates)}

    data =
      if BoundaryOrchestrator.has_boundary_fnis?(data, flow_node_instance_id) do
        BoundaryOrchestrator.cancel_boundary_fnis_for_host(data, flow_node_instance_id)
      else
        data
      end

    put_in(data.flow_node_instance_states[flow_node_instance_id], %{
      entry
      | state: :error,
        pid: nil,
        token: %{entry.token | payload: output_payload}
    })
  end

  defp interrupt_remaining_fnis(data, triggering_fni_id, reason) do
    updated_data =
      data.flow_node_instance_states
      |> Enum.filter(fn {id, entry} ->
        id != triggering_fni_id and entry.state in [:active, :waiting]
      end)
      |> Enum.reduce(data, fn {flow_node_instance_id, entry}, accumulator ->
        if entry.pid != nil, do: Process.exit(entry.pid, :kill)

        flow_node = find_flow_node(accumulator, entry.flow_node_id)
        invoke_optional_callback(flow_node, :handle_aborted, [entry])

        _persist_result =
          FniLifecycle.transition_to_interrupted(
            flow_node_instance_id,
            accumulator.process_instance_id,
            reason,
            flow_node,
            Map.get(entry, :type_properties, %{}),
            resolve_lane_name(accumulator.process_model, flow_node),
            accumulator.root_process_instance_id
          )

        accumulator = unregister_conditional_waiter(accumulator, flow_node_instance_id)

        put_in(accumulator.flow_node_instance_states[flow_node_instance_id], %{
          entry
          | state: :interrupted,
            pid: nil
        })
      end)

    MessageSubscriptions.unregister_all_for_process_instance(data.process_instance_id)
    SignalSubscriptions.unregister_all_for_process_instance(data.process_instance_id)
    updated_data
  end

  # -------------------------------------------------------------------
  # Internal: Boundary event catch handling
  # -------------------------------------------------------------------

  defp apply_boundary_catch_or_cycle_fire(
         data,
         flow_node_instance_id,
         boundary_node_id,
         payload,
         cancel_activity,
         triggerer_fni_id,
         mode
       ) do
    {data, host_fni_id, cancel_activity, dispatch_targets} =
      case mode do
        :catch ->
          BoundaryOrchestrator.handle_boundary_catch(
            data,
            flow_node_instance_id,
            boundary_node_id,
            payload,
            cancel_activity,
            triggerer_fni_id
          )

        :cycle_fire ->
          BoundaryOrchestrator.handle_boundary_cycle_fire(
            data,
            flow_node_instance_id,
            boundary_node_id,
            payload,
            cancel_activity,
            triggerer_fni_id
          )
      end

    data =
      if cancel_activity do
        handle_fni_interrupted(data, host_fni_id, :interrupted_by_boundary)
      else
        data
      end

    Enum.reduce(dispatch_targets, data, fn {target_node, token, previous_ids}, accumulator ->
      dispatch_flow_node_instance(accumulator, target_node, token, previous_ids)
    end)
  end

  defp dispatch_boundary_fni(data, boundary_node, host_fni_id, token) do
    boundary_fni_id = generate_id()
    lane_name = resolve_lane_name(data.process_model, boundary_node)

    case persist_fni_create(data, boundary_fni_id, boundary_node, token, lane_name, [
           host_fni_id
         ]) do
      {:ok, _} ->
        emit_fni_started(data, boundary_fni_id, boundary_node, [host_fni_id])

        case HandlerDispatch.handler_for(boundary_node) do
          {:ok, handler_module} ->
            spawn_boundary_fni_task(
              data,
              boundary_fni_id,
              boundary_node,
              token,
              host_fni_id,
              handler_module
            )

          {:error, {:unsupported_event_definition, unsupported_boundary_node}} ->
            record_fni_fatal(
              data,
              boundary_fni_id,
              boundary_node,
              token,
              [host_fni_id],
              build_unsupported_event_definition_error_info(unsupported_boundary_node)
            )

          {:error, :unsupported_element} ->
            record_fni_fatal(data, boundary_fni_id, boundary_node, token, [host_fni_id], %{
              "error_code" => "unsupported_element",
              "message" => "Unsupported boundary element type: #{boundary_node.type}"
            })
        end

      {:error, _reason} ->
        record_fni_fatal(data, boundary_fni_id, boundary_node, token, [host_fni_id], %{
          "error_code" => "persistence_failed",
          "message" => "Failed to persist boundary flow node instance"
        })
    end
  end

  defp spawn_boundary_fni_task(
         data,
         boundary_fni_id,
         boundary_node,
         token,
         host_fni_id,
         handler_module
       ) do
    process_instance_pid = self()

    handler_context =
      build_handler_context(data, boundary_fni_id, boundary_node, process_instance_pid)
      |> Map.put(:host_flow_node_instance_id, host_fni_id)

    case Task.Supervisor.start_child(data.task_supervisor, fn ->
           result = handler_module.handle_enter(boundary_node, token, handler_context)
           dispatch_handler_result(process_instance_pid, boundary_fni_id, result)
         end) do
      {:ok, task_pid} ->
        Process.monitor(task_pid)

        entry = %{
          pid: task_pid,
          flow_node_id: boundary_node.id,
          flow_node_type: boundary_node.type,
          event_type: extract_event_type(boundary_node),
          state: :active,
          token: token,
          previous_flow_node_instance_ids: [host_fni_id],
          type_properties: %{host_flow_node_instance_id: host_fni_id},
          next_flow_node_ids: []
        }

        put_in(data.flow_node_instance_states[boundary_fni_id], entry)

      {:error, reason} ->
        Logger.error(
          "Failed to start boundary FNI task for #{boundary_node.id}: #{inspect(reason)}"
        )

        record_fni_fatal(data, boundary_fni_id, boundary_node, token, [host_fni_id], %{
          "error_code" => "task_start_failed",
          "message" => "Failed to start boundary task process for '#{boundary_node.id}'"
        })
    end
  end

  # -------------------------------------------------------------------
  # Internal: Generic handler completion dispatch
  # -------------------------------------------------------------------

  defp complete_waiting_fni(data, from, flow_node_instance_id, entry, payload) do
    flow_node = find_flow_node(data, entry.flow_node_id)

    case HandlerDispatch.handler_for(flow_node) do
      {:ok, handler_module} ->
        context = build_handler_context(data, flow_node_instance_id, flow_node, self())

        dispatch_handle_complete(
          data,
          from,
          flow_node_instance_id,
          entry,
          flow_node,
          handler_module,
          context,
          payload
        )

      {:error, {:unsupported_event_definition, _unsupported_flow_node}} ->
        {:keep_state, data, [{:reply, from, {:error, :unsupported_element}}]}

      {:error, :unsupported_element} ->
        {:keep_state, data, [{:reply, from, {:error, :unsupported_element}}]}
    end
  end

  defp cancel_waiting_fni(data, flow_node_instance_id, entry, reason) do
    flow_node = find_flow_node(data, entry.flow_node_id)

    case HandlerDispatch.handler_for(flow_node) do
      {:ok, handler_module} ->
        if function_exported?(handler_module, :handle_cancel, 4) do
          context = build_handler_context(data, flow_node_instance_id, flow_node, self())
          handler_module.handle_cancel(flow_node, entry, reason, context)
        end

      _ ->
        :ok
    end
  end

  defp dispatch_handle_complete(
         data,
         from,
         flow_node_instance_id,
         entry,
         flow_node,
         handler_module,
         context,
         payload
       ) do
    case handler_module.handle_complete(flow_node, entry, payload, context) do
      {:ok, %FlowNodeResult{} = result} ->
        data = handle_fni_ok(data, flow_node_instance_id, result)
        maybe_finish_or_continue_with_reply(data, from)

      {:error, {:contract_violation, _violations} = reason} ->
        {:keep_state, data, [{:reply, from, {:error, reason}}]}

      {:error, reason} ->
        data = handle_fni_fatal(data, flow_node_instance_id, reason)
        do_transition_to_fatal(data, reason, [{:reply, from, {:error, reason}}])
    end
  end

  # -------------------------------------------------------------------
  # Internal: PI termination
  # -------------------------------------------------------------------

  defp maybe_finish_or_continue(data) do
    data = evaluate_parked_inclusive_joins(data)
    data = evaluate_conditional_waiters(data)

    has_fatal =
      Enum.any?(data.flow_node_instance_states, fn {_id, entry} -> entry.state == :fatal end)

    if has_fatal do
      transition_to_fatal(data, :fni_fatal)
    else
      case maybe_finish(data) do
        {:stop, data} -> {:stop, :normal, data}
        {:continue, data} -> {:keep_state, data}
      end
    end
  end

  defp maybe_finish_or_continue_with_reply(data, from) do
    data = evaluate_parked_inclusive_joins(data)
    data = evaluate_conditional_waiters(data)

    has_fatal =
      Enum.any?(data.flow_node_instance_states, fn {_id, entry} -> entry.state == :fatal end)

    if has_fatal do
      do_transition_to_fatal(data, :fni_fatal, [{:reply, from, :ok}])
    else
      case maybe_finish(data) do
        {:stop, data} -> {:stop_and_reply, :normal, [{:reply, from, :ok}], data}
        {:continue, data} -> {:keep_state, data, [{:reply, from, :ok}]}
      end
    end
  end

  defp evaluate_parked_inclusive_joins(data) do
    inclusive_joins =
      Enum.filter(data.join_routing, fn {_id, routing} ->
        routing.gateway_type == :inclusive_gateway
      end)

    Enum.each(inclusive_joins, fn {flow_node_id, routing} ->
      maybe_signal_inclusive_join_fire(data, flow_node_id, routing)
    end)

    data
  end

  defp maybe_signal_inclusive_join_fire(data, flow_node_id, routing) do
    should_fire =
      FlowNodes.InclusiveGateway.should_fire?(
        flow_node_id,
        routing.arrived_via_flow_ids,
        data.flow_node_instance_states,
        data.process_model
      )

    if should_fire do
      case Map.get(data.flow_node_instance_states, routing.fni_id) do
        %{pid: pid} when is_pid(pid) ->
          send(pid, {:fire})

        _ ->
          :ok
      end
    end
  end

  # -------------------------------------------------------------------
  # Internal: Conditional waiter evaluation
  # -------------------------------------------------------------------

  defp evaluate_conditional_waiters(%{conditional_waiters: waiters} = data)
       when map_size(waiters) == 0 do
    data
  end

  defp evaluate_conditional_waiters(data) do
    Enum.reduce(data.conditional_waiters, data, fn {fni_id, waiter}, accumulator ->
      evaluate_single_conditional_waiter(accumulator, fni_id, waiter)
    end)
  end

  defp evaluate_single_conditional_waiter(data, fni_id, %{fired: true}) do
    %{data | conditional_waiters: Map.delete(data.conditional_waiters, fni_id)}
  end

  defp evaluate_single_conditional_waiter(data, fni_id, waiter) do
    case waiter.handler_module.evaluate_condition(
           waiter.flow_node,
           waiter.token_payload,
           data
         ) do
      {:fire, true} ->
        data = %{data | conditional_waiters: Map.delete(data.conditional_waiters, fni_id)}
        fire_conditional_waiter(data, fni_id, waiter)

      {:fire, false} ->
        data
    end
  end

  defp fire_conditional_waiter(data, fni_id, %{position: :boundary} = waiter) do
    cancel_activity = waiter.cancel_activity

    apply_boundary_catch_or_cycle_fire(
      data,
      fni_id,
      waiter.flow_node.id,
      %{},
      cancel_activity,
      nil,
      :catch
    )
  end

  defp fire_conditional_waiter(data, fni_id, %{position: :intermediate_catch} = waiter) do
    handler_context = build_handler_context(data, fni_id, waiter.flow_node, self())

    case waiter.handler_module.complete_condition(
           waiter.flow_node,
           waiter.token_payload,
           handler_context
         ) do
      {:ok, %FlowNodeResult{} = result} ->
        handle_fni_ok(data, fni_id, result)

      {:error, reason} ->
        handle_fni_fatal(data, fni_id, reason)
    end
  end

  defp maybe_register_conditional_waiter_from_wait(data, fni_id, entry) do
    flow_node = find_flow_node(data, entry.flow_node_id)
    {:ok, handler_module} = HandlerDispatch.handler_for(flow_node)
    token_payload = entry.token.payload

    is_boundary = flow_node.type == :boundary_event

    opts =
      if is_boundary do
        type_data = flow_node.type_data
        host_fni_id = find_host_fni_id(data, flow_node)

        %{
          position: :boundary,
          cancel_activity: Map.get(type_data, :cancel_activity, true),
          host_fni_id: host_fni_id
        }
      else
        %{position: :intermediate_catch}
      end

    data = register_conditional_waiter(data, fni_id, flow_node, handler_module, token_payload, opts)

    waiter = Map.get(data.conditional_waiters, fni_id)
    evaluate_single_conditional_waiter(data, fni_id, waiter)
  end

  defp find_host_fni_id(data, boundary_flow_node) do
    attached_to_ref = boundary_flow_node.type_data.attached_to_ref

    Enum.find_value(data.flow_node_instance_states, fn {fni_id, entry} ->
      if entry.flow_node_id == attached_to_ref and entry.state in [:active, :waiting] do
        fni_id
      end
    end)
  end

  defp register_conditional_waiter(data, fni_id, flow_node, handler_module, token_payload, opts) do
    waiter = %{
      flow_node_id: flow_node.id,
      flow_node: flow_node,
      handler_module: handler_module,
      position: opts[:position] || :intermediate_catch,
      cancel_activity: opts[:cancel_activity],
      host_fni_id: opts[:host_fni_id],
      token_payload: token_payload,
      fired: false
    }

    %{data | conditional_waiters: Map.put(data.conditional_waiters, fni_id, waiter)}
  end

  defp unregister_conditional_waiter(data, fni_id) do
    %{data | conditional_waiters: Map.delete(data.conditional_waiters, fni_id)}
  end

  defp maybe_finish(data) do
    active_count =
      Enum.count(data.flow_node_instance_states, fn {_id, entry} ->
        entry.state in [:active, :waiting]
      end)

    cond do
      active_count == 0 and data.escalation_info != nil ->
        MessageSubscriptions.unregister_all_for_process_instance(data.process_instance_id)
        SignalSubscriptions.unregister_all_for_process_instance(data.process_instance_id)
        _persist_result = persist_pi_escalated(data, data.escalation_info)
        emit_pi_state_changed(data, :running, :escalated)

        if data.notify_pid do
          notify_parent(data, {:escalation, data.escalation_info})
        else
          emit_escalation_uncaught(data, data.escalation_info)
        end

        {:stop, data}

      active_count == 0 and data.bpmn_error_info != nil ->
        MessageSubscriptions.unregister_all_for_process_instance(data.process_instance_id)
        SignalSubscriptions.unregister_all_for_process_instance(data.process_instance_id)
        _persist_result = persist_pi_error(data, data.bpmn_error_info)
        emit_pi_state_changed(data, :running, :error)
        notify_parent(data, {:bpmn_error, data.bpmn_error_info})
        {:stop, data}

      active_count == 0 ->
        MessageSubscriptions.unregister_all_for_process_instance(data.process_instance_id)
        SignalSubscriptions.unregister_all_for_process_instance(data.process_instance_id)
        _persist_result = persist_pi_finished(data)
        emit_pi_state_changed(data, :running, :finished)
        notify_parent(data, :finished)
        {:stop, data}

      true ->
        {:continue, data}
    end
  end

  defp transition_to_fatal(data, reason) do
    do_transition_to_fatal(data, reason, [])
  end

  defp do_transition_to_fatal(data, reason, extra_actions) do
    _persist_result = persist_pi_fatal(data, reason)
    emit_pi_state_changed(data, :running, :fatal)
    notify_parent(data, {:fatal, reason})
    fatal_all_fnis(data)

    case extra_actions do
      [] -> {:stop, :normal, data}
      actions -> {:stop_and_reply, :normal, actions, data}
    end
  end

  defp fatal_all_fnis(data) do
    data.flow_node_instance_states
    |> Enum.filter(fn {_id, entry} -> entry.state in [:active, :waiting] end)
    |> Enum.each(fn {flow_node_instance_id, entry} ->
      if entry.pid != nil, do: Process.exit(entry.pid, :kill)

      flow_node = find_flow_node(data, entry.flow_node_id)

      cascade_error_info = %{
        "error_code" => "process_fatal",
        "message" => "Cascade: process instance went fatal"
      }

      _persist_result =
        FniLifecycle.transition_to_fatal(
          flow_node_instance_id,
          data.process_instance_id,
          cascade_error_info,
          flow_node,
          Map.get(entry, :type_properties, %{}),
          resolve_lane_name(data.process_model, flow_node),
          data.root_process_instance_id
        )

      invoke_optional_callback(flow_node, :handle_fatal, [entry])
    end)

    MessageSubscriptions.unregister_all_for_process_instance(data.process_instance_id)
    SignalSubscriptions.unregister_all_for_process_instance(data.process_instance_id)
  end

  defp abort_all_fnis(data) do
    data.flow_node_instance_states
    |> Enum.filter(fn {_id, entry} -> entry.state in [:active, :waiting] end)
    |> Enum.each(fn {flow_node_instance_id, entry} ->
      if entry.pid != nil, do: Process.exit(entry.pid, :kill)

      flow_node = find_flow_node(data, entry.flow_node_id)

      _persist_result =
        FniLifecycle.transition_to_aborted(
          flow_node_instance_id,
          data.process_instance_id,
          "process_aborted",
          flow_node,
          Map.get(entry, :type_properties, %{}),
          resolve_lane_name(data.process_model, flow_node),
          data.root_process_instance_id
        )

      invoke_optional_callback(flow_node, :handle_aborted, [entry])
    end)

    MessageSubscriptions.unregister_all_for_process_instance(data.process_instance_id)
    SignalSubscriptions.unregister_all_for_process_instance(data.process_instance_id)
  end

  defp error_all_remaining_fnis(data, triggering_fni_id) do
    cascade_error_info = %{
      "error_code" => "process_error",
      "message" => "Cascade: process instance received a BPMN error"
    }

    updated_data =
      data.flow_node_instance_states
      |> Enum.filter(fn {id, entry} ->
        id != triggering_fni_id and entry.state in [:active, :waiting]
      end)
      |> Enum.reduce(data, fn {flow_node_instance_id, entry}, accumulator ->
        if entry.pid != nil, do: Process.exit(entry.pid, :kill)

        flow_node = find_flow_node(accumulator, entry.flow_node_id)
        invoke_optional_callback(flow_node, :handle_aborted, [entry])

        _persist_result =
          FniLifecycle.transition_to_error(
            flow_node_instance_id,
            accumulator.process_instance_id,
            cascade_error_info,
            flow_node,
            Map.get(entry, :type_properties, %{}),
            resolve_lane_name(accumulator.process_model, flow_node),
            accumulator.root_process_instance_id
          )

        accumulator = unregister_conditional_waiter(accumulator, flow_node_instance_id)

        put_in(accumulator.flow_node_instance_states[flow_node_instance_id], %{
          entry
          | state: :error,
            pid: nil
        })
      end)

    updated_data
  end

  # -------------------------------------------------------------------
  # Persistence calls (via configured adapter)
  # -------------------------------------------------------------------

  defp persist_pi_create(data) do
    adapter = PersistenceAdapter.adapter()

    attributes = %{
      id: data.process_instance_id,
      process_version_id: data.process_version_id,
      parent_process_instance_id: data.parent_process_instance_id,
      business_key: data.business_key,
      triggerer_flow_node_instance_id: data.triggerer_flow_node_instance_id,
      state: @pi_state_running,
      started_at: data.started_at,
      started_by: identity_to_map(data.identity),
      started_with_context: data.started_with_context
    }

    PersistenceRetry.with_retry(
      fn -> adapter.create_process_instance(attributes) end,
      "PI create #{data.process_instance_id}"
    )
  end

  defp persist_pi_finished(data) do
    adapter = PersistenceAdapter.adapter()

    PersistenceRetry.with_retry(
      fn ->
        adapter.update_process_instance(data.process_instance_id, %{
          state: @pi_state_finished,
          finished_at: DateTime.utc_now()
        })
      end,
      "PI finished #{data.process_instance_id}"
    )
  end

  defp persist_pi_fatal(data, fatal_reason) do
    adapter = PersistenceAdapter.adapter()

    PersistenceRetry.with_retry(
      fn ->
        adapter.update_process_instance(data.process_instance_id, %{
          state: @pi_state_fatal,
          finished_at: DateTime.utc_now(),
          error_info: %{
            "error_code" => "process_fatal",
            "message" => "Process instance went fatal",
            "detail" => to_json_safe(fatal_reason)
          }
        })
      end,
      "PI fatal #{data.process_instance_id}"
    )
  end

  defp persist_pi_aborted(data, abort_reason) do
    adapter = PersistenceAdapter.adapter()

    case PersistenceRetry.with_retry(
           fn ->
             adapter.update_process_instance(data.process_instance_id, %{
               state: @pi_state_aborted,
               finished_at: DateTime.utc_now(),
               error_info: %{
                 "error_code" => "process_aborted",
                 "message" => "Process instance was aborted",
                 "detail" => to_json_safe(abort_reason)
               }
             })
           end,
           "PI aborted #{data.process_instance_id}"
         ) do
      :ok ->
        Logger.info("PI #{data.process_instance_id} aborted: #{inspect(abort_reason)}")

      {:error, _reason} ->
        :ok
    end
  end

  defp persist_pi_error(data, error_info) do
    adapter = PersistenceAdapter.adapter()

    PersistenceRetry.with_retry(
      fn ->
        adapter.update_process_instance(data.process_instance_id, %{
          state: @pi_state_error,
          finished_at: DateTime.utc_now(),
          error_info: %{
            "error_code" => error_info[:error_code] || "bpmn_error",
            "message" => error_info[:error_message] || "Process ended via Error End Event",
            "detail" => to_json_safe(error_info)
          }
        })
      end,
      "PI error #{data.process_instance_id}"
    )
  end

  defp persist_pi_escalated(data, escalation_info) do
    adapter = PersistenceAdapter.adapter()

    PersistenceRetry.with_retry(
      fn ->
        adapter.update_process_instance(data.process_instance_id, %{
          state: @pi_state_escalated,
          finished_at: DateTime.utc_now(),
          error_info: %{
            "error_code" => escalation_info[:escalation_code] || "escalation",
            "message" =>
              "Process ended via Escalation End Event — escalation: #{escalation_info[:escalation_name] || "unnamed"}",
            "detail" => to_json_safe(escalation_info)
          }
        })
      end,
      "PI escalated #{data.process_instance_id}"
    )
  end

  defp persist_fni_create(
         data,
         flow_node_instance_id,
         flow_node,
         token,
         lane_name,
         previous_flow_node_instance_ids
       ) do
    adapter = PersistenceAdapter.adapter()

    attributes = %{
      id: flow_node_instance_id,
      process_instance_id: data.process_instance_id,
      flow_node_id: flow_node.id,
      flow_node_type: Atom.to_string(flow_node.type),
      event_type: extract_event_type(flow_node),
      lane_name: lane_name,
      state: "active",
      started_at: DateTime.utc_now(),
      input_token: token.payload,
      previous_flow_node_instance_ids: previous_flow_node_instance_ids
    }

    PersistenceRetry.with_retry(
      fn -> adapter.create_flow_node_instance(attributes) end,
      "FNI create #{flow_node_instance_id}"
    )
  end

  defp resolve_incoming_sequence_flow_id(data, flow_node, [source_fni_id | _]) when is_binary(source_fni_id) do
    resolve_incoming_sequence_flow_id(data, flow_node, source_fni_id)
  end

  defp resolve_incoming_sequence_flow_id(data, flow_node, source_fni_id) when is_binary(source_fni_id) do
    source_entry = Map.get(data.flow_node_instance_states, source_fni_id)
    source_flow_node_id = if source_entry, do: source_entry.flow_node_id

    find_sequence_flow_id(data.process_model, source_flow_node_id, flow_node.id) || "unknown"
  end

  defp resolve_incoming_sequence_flow_id(_data, _flow_node, _source_fni_id), do: "unknown"

  defp find_sequence_flow_id(_process_model, nil, _target_id), do: nil

  defp find_sequence_flow_id(process_model, source_node_id, target_node_id) do
    Enum.find_value(process_model.sequence_flows || [], fn sequence_flow ->
      if sequence_flow.source_ref == source_node_id and sequence_flow.target_ref == target_node_id,
        do: sequence_flow.id
    end)
  end

  # -------------------------------------------------------------------
  # Event emission
  # -------------------------------------------------------------------

  defp emit_pi_state_changed(data, old_state, new_state) do
    EngineEventBus.publish(%Event.ProcessInstanceStateChanged{
      process_instance_id: data.process_instance_id,
      process_model_id: data.process_model.id,
      version: data.process_model.version,
      parent_process_instance_id: data.parent_process_instance_id,
      root_process_instance_id: data.root_process_instance_id,
      triggerer_flow_node_instance_id: data.triggerer_flow_node_instance_id,
      old_state: old_state,
      new_state: new_state,
      occurred_at: DateTime.utc_now()
    })

    :telemetry.execute(
      [:evil_engine, :process_instance, :state_change],
      %{system_time: System.system_time()},
      %{
        process_instance_id: data.process_instance_id,
        parent_process_instance_id: data.parent_process_instance_id,
        old_state: old_state,
        new_state: new_state
      }
    )
  end

  defp notify_parent(data, :finished) do
    case data.notify_pid do
      nil ->
        :ok

      pid when is_pid(pid) ->
        process_instance_pid = self()
        final_tokens = build_final_tokens(data)
        send(pid, {:child_pi_finished, process_instance_pid, final_tokens})
    end
  end

  defp notify_parent(data, {:fatal, reason}) do
    case data.notify_pid do
      nil ->
        :ok

      pid when is_pid(pid) ->
        process_instance_pid = self()
        send(pid, {:child_pi_fatal, process_instance_pid, reason})
    end
  end

  defp notify_parent(data, {:bpmn_error, error_info}) do
    case data.notify_pid do
      nil ->
        :ok

      pid when is_pid(pid) ->
        process_instance_pid = self()
        final_tokens = build_final_tokens(data)
        send(pid, {:child_pi_bpmn_error, process_instance_pid, error_info, final_tokens})
    end
  end

  defp notify_parent(data, :aborted) do
    case data.notify_pid do
      nil ->
        :ok

      pid when is_pid(pid) ->
        process_instance_pid = self()
        send(pid, {:child_pi_aborted, process_instance_pid})
    end
  end

  defp notify_parent(data, {:escalation, escalation_info}) do
    case data.notify_pid do
      nil ->
        :ok

      pid when is_pid(pid) ->
        process_instance_pid = self()
        final_tokens = build_final_tokens(data)
        send(pid, {:child_pi_escalation, process_instance_pid, escalation_info, final_tokens})
    end
  end

  defp notify_parent(data, {:escalation_passthrough, escalation_info}) do
    case data.notify_pid do
      nil ->
        :ok

      pid when is_pid(pid) ->
        process_instance_pid = self()
        send(pid, {:child_pi_escalation_passthrough, process_instance_pid, escalation_info})
    end
  end

  defp emit_fni_started(data, flow_node_instance_id, flow_node, previous_flow_node_instance_ids) do
    EngineEventBus.publish(%Event.FlowNodeInstanceStarted{
      flow_node_instance_id: flow_node_instance_id,
      process_instance_id: data.process_instance_id,
      root_process_instance_id: data.root_process_instance_id,
      flow_node_id: flow_node.id,
      flow_node_type: flow_node.type,
      event_type: extract_event_type(flow_node),
      lane_name: resolve_lane_name(data.process_model, flow_node),
      triggerer_flow_node_instance_id: nil,
      occurred_at: DateTime.utc_now()
    })

    :telemetry.execute(
      [:evil_engine, :flow_node_instance, :started],
      %{system_time: System.system_time()},
      %{
        flow_node_instance_id: flow_node_instance_id,
        flow_node_type: flow_node.type,
        previous_flow_node_instance_ids: previous_flow_node_instance_ids
      }
    )
  end

  defp emit_fni_state_changed(data, flow_node_instance_id, entry, old_state, new_state) do
    flow_node = find_flow_node(data, entry.flow_node_id)

    EngineEventBus.publish(%Event.FlowNodeInstanceStateChanged{
      flow_node_instance_id: flow_node_instance_id,
      process_instance_id: data.process_instance_id,
      root_process_instance_id: data.root_process_instance_id,
      flow_node_id: entry.flow_node_id,
      flow_node_type: entry.flow_node_type,
      event_type:
        if(flow_node, do: extract_event_type(flow_node), else: Map.get(entry, :event_type)),
      lane_name: if(flow_node, do: resolve_lane_name(data.process_model, flow_node)),
      old_state: old_state,
      new_state: new_state,
      occurred_at: DateTime.utc_now()
    })

    :telemetry.execute(
      [:evil_engine, :flow_node_instance, :state_change],
      %{system_time: System.system_time()},
      %{
        flow_node_instance_id: flow_node_instance_id,
        process_instance_id: data.process_instance_id,
        flow_node_type: entry.flow_node_type,
        old_state: old_state,
        new_state: new_state
      }
    )
  end

  defp emit_call_activity_child_started(
         data,
         flow_node_instance_id,
         child_process_instance_id,
         child_process_model_id,
         child_version
       ) do
    EngineEventBus.publish(%Event.CallActivityChildStarted{
      call_activity_flow_node_instance_id: flow_node_instance_id,
      parent_process_instance_id: data.process_instance_id,
      child_process_instance_id: child_process_instance_id,
      child_process_model_id: child_process_model_id,
      child_version: child_version,
      occurred_at: DateTime.utc_now()
    })

    :telemetry.execute(
      [:evil_engine, :call_activity, :child_started],
      %{system_time: System.system_time()},
      %{
        call_activity_flow_node_instance_id: flow_node_instance_id,
        parent_process_instance_id: data.process_instance_id,
        child_process_instance_id: child_process_instance_id,
        child_process_model_id: child_process_model_id,
        child_version: child_version
      }
    )
  end

  defp emit_subprocess_child_started(
         data,
         flow_node_instance_id,
         child_process_instance_id,
         subprocess_node_id,
         child_process_model_id,
         child_version
       ) do
    EngineEventBus.publish(%Event.SubProcessChildStarted{
      subprocess_flow_node_instance_id: flow_node_instance_id,
      parent_process_instance_id: data.process_instance_id,
      child_process_instance_id: child_process_instance_id,
      subprocess_node_id: subprocess_node_id,
      child_process_model_id: child_process_model_id,
      child_version: child_version,
      occurred_at: DateTime.utc_now()
    })

    :telemetry.execute(
      [:evil_engine, :subprocess, :child_started],
      %{system_time: System.system_time()},
      %{
        subprocess_flow_node_instance_id: flow_node_instance_id,
        parent_process_instance_id: data.process_instance_id,
        child_process_instance_id: child_process_instance_id,
        subprocess_node_id: subprocess_node_id,
        child_process_model_id: child_process_model_id,
        child_version: child_version
      }
    )
  end

  defp emit_escalation_raised(data, flow_node_instance_id, flow_node_id, escalation_info, throw_type) do
    EngineEventBus.publish(%Event.EscalationRaised{
      escalation_code: escalation_info[:escalation_code],
      escalation_name: escalation_info[:escalation_name],
      process_instance_id: data.process_instance_id,
      root_process_instance_id: data.root_process_instance_id,
      flow_node_instance_id: flow_node_instance_id,
      flow_node_id: flow_node_id,
      throw_type: throw_type,
      occurred_at: DateTime.utc_now()
    })

    :telemetry.execute(
      [:evil_engine, :escalation, :raised],
      %{system_time: System.system_time()},
      %{
        escalation_code: escalation_info[:escalation_code],
        flow_node_instance_id: flow_node_instance_id,
        process_instance_id: data.process_instance_id,
        throw_type: throw_type
      }
    )
  end

  defp emit_escalation_uncaught(data, escalation_info) do
    :telemetry.execute(
      [:evil_engine, :escalation, :uncaught],
      %{system_time: System.system_time()},
      %{
        escalation_code: escalation_info[:escalation_code],
        process_instance_id: data.process_instance_id
      }
    )

    Logger.warning(
      "Uncaught escalation reached root process instance " <>
        "#{data.process_instance_id}: #{inspect(escalation_info[:escalation_code])}"
    )
  end

  defp identity_to_map(nil), do: nil

  defp identity_to_map(%{id: id, roles: roles, groups: groups}),
    do: %{"id" => id, "roles" => roles, "groups" => groups}
end

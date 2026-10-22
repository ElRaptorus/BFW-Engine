defmodule BfwEngine.Execution.ProcessInstance do
  @moduledoc """
  The Process Instance runtime — one `:gen_statem` per running PI.

  ## States

      init → :running → :finished
                      → :fatal
                      → :aborted
                      → :error
                      → :escalated
                      → :compensated
                      → :cancelled

  The PI orchestrates FNI execution: it spawns handler Tasks under a
  linked `Task.Supervisor`, receives their results, resolves outgoing
  sequence flows, and dispatches successor FNIs. When all paths
  complete (no active FNIs remain), the PI terminates.

  ## Registration

  Each PI registers itself in `BfwEngine.Execution.Registry` under
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

  alias BfwEngine.Execution.ProcessInstance.ErrorInfo
  alias BfwEngine.Execution.ProcessInstance.FlowNodeLookup
  alias BfwEngine.Execution.ProcessInstance.HandlerDispatch, as: InstanceHandlerDispatch
  alias BfwEngine.Execution.ProcessInstance.JsonSafe
  alias BfwEngine.Execution.ProcessInstance.LaneResolution
  alias BfwEngine.Execution.UuidV7

  alias BfwEngine.BPMN.ComplexRegionAnalysis
  alias BfwEngine.BPMN.InclusiveJoinAnalysis
  alias BfwEngine.BPMN.Model.EventDefinition
  alias BfwEngine.BPMN.Model.FlowNode
  alias BfwEngine.BPMN.ModelCache
  alias BfwEngine.Events.EngineEventBus
  alias BfwEngine.Events.MessageSubscriptions
  alias BfwEngine.Events.SignalSubscriptions
  alias BfwEngine.Execution.BoundaryAwareHandler
  alias BfwEngine.Execution.CalledElementResolver
  alias BfwEngine.Execution.ComplexJoinEvaluator
  alias BfwEngine.Execution.FlowNodeResult
  alias BfwEngine.Execution.FlowNodes
  alias BfwEngine.Execution.FlowNodes.ChildLifecycle
  alias BfwEngine.Execution.FlowNodes.EventSubprocess, as: EspScope
  alias BfwEngine.Execution.FniLifecycle
  alias BfwEngine.Execution.HandlerDispatch
  alias BfwEngine.Execution.PayloadCap
  alias BfwEngine.Execution.Persistence, as: PersistenceAdapter
  alias BfwEngine.Execution.PersistenceRetry
  alias BfwEngine.Execution.ProcessInstance.AdHocMode
  alias BfwEngine.Execution.ProcessInstance.BoundaryOrchestrator
  alias BfwEngine.Execution.ProcessInstance.CompensationOrchestrator
  alias BfwEngine.Execution.ProcessInstance.EscalationTrigger
  alias BfwEngine.Execution.ProcessInstance.EventBasedGatewayOrchestrator
  alias BfwEngine.Execution.ProcessInstance.Resumption
  alias BfwEngine.Execution.ProcessInstance.StandardMode
  alias BfwEngine.Execution.ProcessInstance.State
  alias BfwEngine.Execution.TaskInboxEvents
  alias BfwEngine.Timers.Scheduler
  alias BfwEngine.Types.Event
  alias BfwEngine.Types.FinalToken
  alias BfwEngine.Types.Token

  @pi_state_running "running"
  @pi_state_finished "finished"
  @pi_state_fatal "fatal"
  @pi_state_aborted "aborted"
  @pi_state_error "error"
  @pi_state_escalated "escalated"
  @pi_state_compensated "compensated"
  @pi_state_cancelled "cancelled"
  @early_completion_caller :early_async_completion
  @shutdown_timeout 5_000

  # Iteration Tasks trap exits but no handler continuation reacts to
  # `{:EXIT, _, :shutdown}`; the grace only lets an in-flight finish write
  # commit. All live iterations of a shell share one grace window.
  @iteration_shutdown_grace_ms 200
  @iteration_kill_wait_ms 1_000
  @scheduler_restart_wait_initial_ms 50
  @scheduler_restart_wait_max_ms 1_000

  # A parked compensation handler must keep naming its target and throw
  # event, or its completion never resumes the Compensate Throw.
  @compensation_link_keys [
    :compensation_for,
    :compensation_throw_fni_id,
    "compensation_for",
    "compensation_throw_fni_id"
  ]

  @type start_opts :: %{
          required(:process_instance_id) => String.t(),
          required(:process_version_id) => String.t(),
          required(:payload) => term(),
          required(:identity) => BfwEngine.Types.Identity.t(),
          optional(:start_event_id) => String.t() | nil,
          optional(:context) => map() | nil,
          optional(:business_key) => String.t() | nil,
          optional(:parent_process_instance_id) => String.t() | nil,
          optional(:root_process_instance_id) => String.t() | nil,
          optional(:triggerer_flow_node_instance_id) => String.t() | nil,
          optional(:notify_pid) => pid() | nil,
          optional(:subprocess_node_id) => String.t() | nil,
          optional(:esp_start_passthrough) => boolean(),
          optional(:mode) => module(),
          optional(:adhoc_completion_condition) => String.t() | nil,
          optional(:adhoc_completion_condition_compiled) => reference() | nil,
          optional(:adhoc_cancel_remaining_instances) => boolean(),
          optional(:adhoc_ordering) => :parallel | :sequential
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
      {:via, Registry, {BfwEngine.Execution.Registry, process_instance_id}},
      __MODULE__,
      opts,
      []
    )
  end

  @doc """
  Finish a waiting User Task.

  `values` is the field-value map. `opts` accepts `action_id:` (`nil` or a string).
  """
  @spec finish_user_task(pid(), String.t(), term(), BfwEngine.Types.Identity.t(), keyword()) ::
          :ok | {:error, term()} | {:error, :payload_too_large, map()}
  def finish_user_task(process_instance_pid, flow_node_instance_id, values, identity, opts \\ []) do
    :gen_statem.call(
      process_instance_pid,
      {:finish_user_task, flow_node_instance_id, values, Keyword.get(opts, :action_id), identity}
    )
  end

  @doc "Confirm a waiting Manual Task; the token it entered with continues unchanged."
  @spec confirm_manual_task(pid(), String.t(), BfwEngine.Types.Identity.t()) ::
          :ok | {:error, term()}
  def confirm_manual_task(process_instance_pid, flow_node_instance_id, identity) do
    :gen_statem.call(
      process_instance_pid,
      {:confirm_manual_task, flow_node_instance_id, identity}
    )
  end

  @doc "Cancel a waiting User Task or confirming Manual Task and abort the process instance tree."
  @spec cancel_inbox_task(pid(), String.t(), String.t() | nil, BfwEngine.Types.Identity.t()) ::
          :ok | {:error, term()}
  def cancel_inbox_task(process_instance_pid, flow_node_instance_id, reason, identity) do
    :gen_statem.call(
      process_instance_pid,
      {:cancel_inbox_task, flow_node_instance_id, reason, identity}
    )
  end

  @doc """
  Manually trigger a waiting timer event FNI. Returns
  `{:error, :timer_not_armed}` when the FNI's handler holds no armed timer,
  so nothing fired.
  """
  @spec trigger_timer_event(pid(), String.t()) :: :ok | {:error, term()}
  def trigger_timer_event(process_instance_pid, flow_node_instance_id) do
    :gen_statem.call(process_instance_pid, {:trigger_timer_event, flow_node_instance_id})
  end

  @doc """
  Inject an escalation into waiting catchers in this process instance.

  Delivers to a matching Event Subprocess start and to waiting Escalation
  Boundary FNIs. Does not walk the parent chain and does not transition
  the PI to `:escalated` when nothing matched.
  """
  @spec trigger_escalation(pid(), map()) :: {:ok, [map()]} | {:error, term()}
  def trigger_escalation(process_instance_pid, escalation_info) do
    :gen_statem.call(process_instance_pid, {:trigger_escalation, escalation_info})
  end

  @doc "Abort a running process instance."
  @spec abort(pid(), String.t() | nil, BfwEngine.Types.Identity.t() | nil) ::
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

  @doc """
  Revive the finished subprocess child instance `child_process_instance_id`
  only to compensate its completed inner activities, in its own scope.

  The revived instance writes no process instance state. It replies
  `{:compensation_scope_finished, child_process_instance_id,
  scope_target_id, handler_count}`, `{:compensation_scope_failed,
  child_process_instance_id, scope_target_id, error_info}`, or
  `{:compensation_scope_aborted, child_process_instance_id,
  scope_target_id, reason}` to `request.reply_to`, then stops; it also
  stops when `request.reply_to` goes down. Returns `{:busy, pid}` when the
  instance is already running.
  """
  @spec start_compensation_scope(String.t(), State.compensation_scope_request()) ::
          {:ok, pid()} | {:busy, pid()} | {:error, term()}
  def start_compensation_scope(child_process_instance_id, request) do
    adapter = PersistenceAdapter.adapter()

    with {:ok, child_data} <- ChildLifecycle.fetch_persisted_child(child_process_instance_id),
         {:ok, child_flow_node_instances} <-
           adapter.list_all_flow_node_instances(child_process_instance_id) do
      opts = %{
        resume: true,
        compensation_scope: request,
        process_instance_id: child_process_instance_id,
        process_version_id: child_data.process_version_id,
        business_key: child_data.business_key,
        parent_process_instance_id: child_data.parent_process_instance_id,
        root_process_instance_id: request.root_process_instance_id,
        triggerer_flow_node_instance_id: child_data.triggerer_flow_node_instance_id,
        started_at: child_data.started_at,
        started_by: child_data.started_by,
        started_with_context: child_data.started_with_context,
        fni_data: child_flow_node_instances
      }

      case DynamicSupervisor.start_child(BfwEngine.Execution.Supervisor, {__MODULE__, opts}) do
        {:ok, pid} -> {:ok, pid}
        {:error, {:already_started, pid}} -> {:busy, pid}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Wait until a resumed PI has re-registered every message and signal
  subscription and re-attached every child PI. Returns `{:ok, resumed?}` once
  settled, where `resumed?` tells whether the PI was started from persisted
  state; a fresh PI settles at once with `false`, a stopped PI answers
  `{:ok, false}`. Returns `{:error, :timeout}` when `timeout` milliseconds pass
  first.
  """
  @spec await_resume_settled(pid(), timeout()) :: {:ok, boolean()} | {:error, :timeout}
  def await_resume_settled(process_instance_pid, timeout) do
    {:settled, resumed?} = :gen_statem.call(process_instance_pid, :await_resume_settled, timeout)
    {:ok, resumed?}
  catch
    :exit, {:timeout, _call} -> {:error, :timeout}
    :exit, _stopped -> {:ok, false}
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
      flow_node = FlowNodeLookup.find_flow_node(data, entry.flow_node_id)

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
  def init(%{resume: true, compensation_scope: request} = opts) do
    Process.flag(:trap_exit, true)
    Process.monitor(request.reply_to)

    data = %State{
      process_instance_id: opts.process_instance_id,
      process_version_id: opts.process_version_id,
      identity: Resumption.rebuild_identity(opts.started_by),
      business_key: opts.business_key,
      parent_process_instance_id: opts.parent_process_instance_id,
      root_process_instance_id: opts.root_process_instance_id,
      triggerer_flow_node_instance_id: opts.triggerer_flow_node_instance_id,
      started_at: opts.started_at,
      started_with_context: opts.started_with_context,
      start_payload: Resumption.start_payload(opts.fni_data),
      compensation_scope: %{request: request, children: %{}},
      resume: %{resumed: true, pending: MapSet.new(), waiters: []}
    }

    with {:ok, process_model, definitions} <-
           fetch_process_model(data.process_version_id, request.subprocess_node_id),
         {:ok, task_supervisor} <- Task.Supervisor.start_link(strategy: :one_for_one),
         {:ok, data_object_rows} <-
           PersistenceAdapter.adapter().list_data_objects(data.process_instance_id) do
      data =
        %{
          data
          | process_model: process_model,
            definitions: definitions,
            task_supervisor: task_supervisor,
            data_object_cache: Map.new(data_object_rows, &{&1.data_object_id, &1.value})
        }
        |> Resumption.rebuild_flow_node_instance_states(opts.fni_data)
        |> drop_fatal_flow_node_instances()
        |> Resumption.rebuild_compensation_registry()
        |> Resumption.reactivate_fnis(self())
        |> start_compensation_scope_run()

      {:ok, :running, data, [{:next_event, :internal, :check_initial_dispatch}]}
    else
      {:error, reason} ->
        Logger.error(
          "PI #{data.process_instance_id} failed to start its compensation scope: #{inspect(reason)}"
        )

        {:stop, reason}
    end
  end

  def init(%{resume: true} = opts) do
    Process.flag(:trap_exit, true)
    mode = opts[:mode] || StandardMode

    data = %State{
      process_instance_id: opts.process_instance_id,
      process_version_id: opts.process_version_id,
      mode: mode,
      identity: Resumption.rebuild_identity(opts[:started_by]),
      business_key: opts[:business_key],
      parent_process_instance_id: opts[:parent_process_instance_id],
      root_process_instance_id: opts[:root_process_instance_id] || opts.process_instance_id,
      triggerer_flow_node_instance_id: opts[:triggerer_flow_node_instance_id],
      started_at: opts[:started_at],
      started_with_context: opts[:started_with_context],
      start_payload: Resumption.start_payload(opts[:fni_data] || []),
      notify_pid: opts[:notify_pid],
      adhoc_completion_condition: opts[:adhoc_completion_condition],
      adhoc_completion_condition_compiled: opts[:adhoc_completion_condition_compiled],
      adhoc_cancel_remaining_instances: Map.get(opts, :adhoc_cancel_remaining_instances, true),
      adhoc_ordering: opts[:adhoc_ordering] || :parallel,
      adhoc_natural_drain_enabled:
        Map.get(opts, :adhoc_natural_drain_enabled, false) and (opts[:fni_data] || []) != [],
      resume: %{resumed: true, pending: MapSet.new(), waiters: []}
    }

    resume_from_persisted_state(data, opts)
  end

  def init(opts) do
    Process.flag(:trap_exit, true)
    mode = opts[:mode] || StandardMode

    data = %State{
      process_instance_id: opts.process_instance_id,
      process_version_id: opts.process_version_id,
      mode: mode,
      identity: opts.identity,
      business_key: opts[:business_key],
      parent_process_instance_id: opts[:parent_process_instance_id],
      root_process_instance_id: opts[:root_process_instance_id] || opts.process_instance_id,
      triggerer_flow_node_instance_id: opts[:triggerer_flow_node_instance_id],
      notify_pid: opts[:notify_pid],
      adhoc_completion_condition: opts[:adhoc_completion_condition],
      adhoc_completion_condition_compiled: opts[:adhoc_completion_condition_compiled],
      adhoc_cancel_remaining_instances: Map.get(opts, :adhoc_cancel_remaining_instances, true),
      adhoc_ordering: opts[:adhoc_ordering] || :parallel
    }

    with :ok <- PayloadCap.check(opts[:payload], field: :start_payload),
         :ok <- PayloadCap.check(opts[:context], field: :start_context),
         {:ok, process_model, definitions} <-
           fetch_process_model(data.process_version_id, opts[:subprocess_node_id]),
         {:ok, start_event} <-
           mode.resolve_initial_state(process_model, opts[:start_event_id], process_model.id),
         {:ok, task_supervisor} <- Task.Supervisor.start_link(strategy: :one_for_one) do
      now = DateTime.utc_now()

      data = %{
        data
        | process_model: process_model,
          definitions: definitions,
          started_at: now,
          started_with_context: opts[:context],
          start_payload: opts[:payload],
          task_supervisor: task_supervisor
      }

      case persist_pi_create(data) do
        {:ok, _} ->
          emit_pi_state_changed(data, nil, :running)
          init_after_persist(data, start_event, opts, now)

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

  defp resume_from_persisted_state(data, opts) do
    case fetch_process_model(data.process_version_id, opts[:subprocess_node_id]) do
      {:ok, process_model, definitions} ->
        resume_with_process_model(
          %{data | process_model: process_model, definitions: definitions},
          opts
        )

      {:error, reason} ->
        fail_resume(data, reason)
    end
  catch
    kind, reason ->
      fail_resume(data, {:resume_crashed, Exception.format(kind, reason, __STACKTRACE__)})
  end

  defp resume_with_process_model(data, opts) do
    flow_node_instance_data = opts[:fni_data] || []

    with :ok <- require_recorded_start(data.mode, flow_node_instance_data),
         {:ok, task_supervisor} <- Task.Supervisor.start_link(strategy: :one_for_one),
         {:ok, data_object_rows} <-
           PersistenceAdapter.adapter().list_data_objects(data.process_instance_id) do
      cache = Map.new(data_object_rows, fn row -> {row.data_object_id, row.value} end)
      data = %{data | task_supervisor: task_supervisor, data_object_cache: cache}

      pending_arrivals = opts[:pending_arrivals] || []
      data = Resumption.resume(data, flow_node_instance_data, pending_arrivals, self())
      data = resume_stalled_compensation_runs(data)

      {data, trigger_actions} = register_event_subprocess_triggers(data)
      data = evaluate_parked_inclusive_joins(data)
      data = evaluate_parked_complex_joins(data)
      {data, repair_actions} = redispatch_lost_successors(data)
      data = repair_resumed_adhoc_progress(data)

      {:ok, :running, data,
       trigger_actions ++ repair_actions ++ [{:next_event, :internal, :check_initial_dispatch}]}
    else
      {:error, reason} -> fail_resume(data, reason)
    end
  catch
    kind, reason ->
      fail_resume(data, {:resume_crashed, Exception.format(kind, reason, __STACKTRACE__)})
  end

  # Fatal handler rows of an earlier failed scope run must not fail this one;
  # their targets stay unclaimed, so this run compensates them again.
  defp drop_fatal_flow_node_instances(data) do
    states =
      data.flow_node_instance_states
      |> Enum.reject(fn {_id, entry} -> entry.state == :fatal end)
      |> Map.new()

    %{data | flow_node_instance_states: states}
  end

  # An ad-hoc child has no Start Event; it legitimately resumes without rows.
  defp require_recorded_start(StandardMode, []), do: {:error, :start_event_never_recorded}
  defp require_recorded_start(_mode, _flow_node_instance_data), do: :ok

  defp fail_resume(data, reason) do
    Logger.error("PI #{data.process_instance_id} failed to resume: #{inspect(reason)}")
    _persist_result = persist_pi_resume_failed(data, reason)
    if data.process_model, do: emit_pi_state_changed(data, :running, :fatal)
    {:stop, {reason, data}}
  end

  defp settle_resumed_flow_node_instance(data, flow_node_instance_id) do
    reply_resume_waiters(
      update_in(data.resume.pending, &MapSet.delete(&1, flow_node_instance_id))
    )
  end

  defp reply_resume_waiters(%{resume: %{waiters: []}} = data), do: data

  defp reply_resume_waiters(data) do
    still_pending =
      Enum.any?(data.resume.pending, fn flow_node_instance_id ->
        match?(
          %{state: state} when state in [:active, :waiting],
          Map.get(data.flow_node_instance_states, flow_node_instance_id)
        )
      end)

    if still_pending do
      data
    else
      Enum.each(data.resume.waiters, &:gen_statem.reply(&1, {:settled, data.resume.resumed}))
      %{data | resume: %{data.resume | pending: MapSet.new(), waiters: []}}
    end
  end

  defp resume_stalled_compensation_runs(data) do
    data
    |> Resumption.stalled_compensation_runs()
    |> Enum.reduce(data, fn throw_fni_id, accumulator ->
      CompensationOrchestrator.resume_run(accumulator, throw_fni_id, compensation_runtime())
    end)
  end

  defp redispatch_lost_successors(data) do
    {failures, dispatches} =
      data
      |> Resumption.lost_successor_dispatches(self())
      |> Enum.split_with(&match?({:error, _reason}, &1))

    data =
      Enum.reduce(dispatches, data, fn {flow_node_instance_id, output_payload, next_flow_node_ids},
                                       accumulator ->
        dispatch_successor_targets(
          accumulator,
          flow_node_instance_id,
          output_payload,
          next_flow_node_ids
        )
      end)

    case failures do
      [] ->
        {data, []}

      [{:error, reason} | _more] ->
        {data, [{:next_event, :internal, {:resume_repair_failed, reason}}]}
    end
  end

  defp repair_resumed_adhoc_progress(%{flow_node_instance_states: states} = data)
       when map_size(states) == 0,
       do: data

  defp repair_resumed_adhoc_progress(data) do
    data
    |> maybe_evaluate_adhoc_completion_condition()
    |> maybe_cancel_remaining_for_adhoc()
    |> maybe_auto_chain_sequential_adhoc()
  end

  defp init_after_persist(data, nil, _opts, _now) do
    {data, trigger_actions} = register_event_subprocess_triggers(data)
    {:ok, :running, data, trigger_actions}
  end

  defp init_after_persist(data, start_event, opts, now) do
    initial_token = %Token{
      id: UuidV7.generate(),
      process_instance_id: data.process_instance_id,
      payload: opts[:payload],
      originating_flow_node_instance_id: nil,
      created_at: now
    }

    dispatch_start_event =
      EspScope.passthrough_start_event(start_event, opts[:esp_start_passthrough])

    data = dispatch_flow_node_instance(data, dispatch_start_event, initial_token, [])
    {data, trigger_actions} = register_event_subprocess_triggers(data)

    {:ok, :running, data, trigger_actions ++ [{:next_event, :internal, :check_initial_dispatch}]}
  end

  defp register_event_subprocess_triggers(data) do
    case EspScope.register_triggers(data) do
      {:ok, data} ->
        {monitor_scheduler_for_timer_triggers(data), []}

      {:error, reason, data} ->
        {data, [{:next_event, :internal, {:event_subprocess_registration_failed, reason}}]}
    end
  end

  defp monitor_scheduler_for_timer_triggers(data) do
    if data.scheduler_monitor_reference == nil and EspScope.timer_triggers_armed?(data) do
      %{data | scheduler_monitor_reference: Process.monitor(Scheduler)}
    else
      data
    end
  end

  defp retry_event_subprocess_timer_rearm(wait_ms) do
    next_wait_ms = min(wait_ms * 2, @scheduler_restart_wait_max_ms)

    {:keep_state_and_data,
     [{{:timeout, :rearm_event_subprocess_timers}, next_wait_ms, next_wait_ms}]}
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

  def running(:internal, {:event_subprocess_registration_failed, reason}, data) do
    transition_to_fatal(data, reason)
  end

  def running(:internal, {:resume_repair_failed, reason}, data) do
    transition_to_fatal(data, reason)
  end

  # FNI completed synchronously (stale result guard is inside handle_fni_ok)
  def running(
        :info,
        {:fni_result, flow_node_instance_id, {:ok, %FlowNodeResult{} = result}},
        data
      ) do
    case Map.get(data.mi_shell_tasks, flow_node_instance_id) do
      nil ->
        data = handle_fni_ok(data, flow_node_instance_id, result)
        data = maybe_evaluate_adhoc_completion_condition(data)
        data = maybe_cancel_remaining_for_adhoc(data)
        data = maybe_auto_chain_sequential_adhoc(data)
        maybe_finish_or_continue(data)

      {_shell_fni_id, shell_task_pid} ->
        data = handle_mi_iteration_ok(data, flow_node_instance_id, result, shell_task_pid)
        {data, release_actions} = release_early_async_completions(data)
        {:keep_state, data, release_actions}
    end
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

  # Cancel End Event: finish FNI, interrupt siblings, run LIFO compensation,
  # then transition child PI to :cancelled.
  def running(
        :info,
        {:fni_result, flow_node_instance_id, {:cancel, %FlowNodeResult{} = result}},
        data
      ) do
    data = handle_fni_cancel(data, flow_node_instance_id, result)
    maybe_finish_or_continue(data)
  end

  # Compensate Throw/End Event: park throw FNI, resolve targets, begin
  # sequential LIFO compensation run.
  def running(
        :info,
        {:fni_result, flow_node_instance_id, {:compensate, run_spec, %FlowNodeResult{} = result}},
        data
      ) do
    data = handle_fni_compensate(data, flow_node_instance_id, result, run_spec)
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
    data =
      handle_fni_escalation_end_propagate(data, flow_node_instance_id, result, escalation_info)

    maybe_finish_or_continue(data)
  end

  def running(:info, {:escalation_passthrough, escalation_info}, data) do
    case EspScope.resolve_escalation_catch(data, escalation_info) do
      {:ok, action} ->
        data = execute_esp_action(data, action)
        maybe_finish_or_continue(data)

      :none ->
        forward_escalation_passthrough(data, escalation_info)
        {:keep_state, data}
    end
  end

  def running(
        :info,
        {:fni_result, flow_node_instance_id, {:wait, %FlowNodeResult{} = result}},
        data
      ) do
    data = handle_fni_wait(data, flow_node_instance_id, result)
    maybe_finish_or_continue(data)
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
    maybe_finish_or_continue(data)
  end

  def running(:info, {:fni_result, flow_node_instance_id, {:async, _ref}}, data) do
    data = handle_fni_async(data, flow_node_instance_id, %{})
    maybe_finish_or_continue(data)
  end

  def running(
        :info,
        {:fni_merge_type_properties, flow_node_instance_id, extra_type_properties},
        data
      )
      when is_map(extra_type_properties) do
    data = merge_fni_type_properties(data, flow_node_instance_id, extra_type_properties)
    {:keep_state, data}
  end

  def running(:info, {:fni_result, _flow_node_instance_id, :abort_cascade}, data) do
    abort_process_instance(data, "child_aborted")
    {:stop, :normal, data}
  end

  def running(:info, {:fni_result, flow_node_instance_id, {:error, reason}}, data) do
    case Map.get(data.mi_shell_tasks, flow_node_instance_id) do
      nil ->
        handle_fni_error_result(data, flow_node_instance_id, reason)

      {_shell_fni_id, shell_task_pid} ->
        data = handle_mi_iteration_error(data, flow_node_instance_id, reason, shell_task_pid)
        {data, release_actions} = release_early_async_completions(data)
        {:keep_state, data, release_actions}
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

  # -------------------------------------------------------------------
  # Multi-Instance iteration dispatch (called by MI shell Task)
  # -------------------------------------------------------------------

  def running(
        {:call, from},
        {:mi_dispatch_iteration, shell_fni_id, index, item, %Token{} = token, loop_overlay,
         %FlowNode{} = flow_node},
        data
      ) do
    data =
      dispatch_mi_iteration_fni(
        data,
        from,
        shell_fni_id,
        index,
        item,
        token,
        loop_overlay,
        flow_node
      )

    {:keep_state, data}
  end

  # MI shell reattaches existing iteration FNIs after crash-resume (does not re-dispatch).
  def running({:call, from}, {:mi_reattach_iterations, shell_fni_id}, data) do
    {shell_task_pid, _from_tag} = from
    {data, snapshot} = reattach_iteration_shell(data, shell_fni_id, shell_task_pid)
    :gen_statem.reply(from, {:ok, snapshot})
    {:keep_state, settle_resumed_flow_node_instance(data, shell_fni_id)}
  end

  def running({:call, from}, :await_resume_settled, data) do
    data = update_in(data.resume.waiters, &[from | &1])
    {:keep_state, reply_resume_waiters(data)}
  end

  def running(:info, {:resume_settled, flow_node_instance_id}, data) do
    {:keep_state, settle_resumed_flow_node_instance(data, flow_node_instance_id)}
  end

  # MI shell requests to interrupt all remaining iterations (completion condition met, error, etc.)
  def running(:cast, {:mi_interrupt_remaining, shell_fni_id}, data) do
    data = interrupt_iterations_for_shell(data, shell_fni_id)
    {:keep_state, data}
  end

  def running({:call, from}, {:mi_interrupt_remaining, shell_fni_id}, data) do
    data = interrupt_iterations_for_shell(data, shell_fni_id)
    :gen_statem.reply(from, :ok)
    {:keep_state, data}
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
         subprocess_node_id, child_process_model_id, child_version, is_event_subprocess},
        data
      ) do
    emit_subprocess_child_started(
      data,
      flow_node_instance_id,
      child_process_instance_id,
      subprocess_node_id,
      child_process_model_id,
      child_version,
      is_event_subprocess,
      false
    )

    EspScope.maybe_emit_triggered(
      data,
      subprocess_node_id,
      child_process_instance_id,
      is_event_subprocess
    )

    {:keep_state, data}
  end

  def running(
        :info,
        {:subprocess_child_started, flow_node_instance_id, child_process_instance_id,
         subprocess_node_id, child_process_model_id, child_version, is_event_subprocess,
         is_ad_hoc_subprocess},
        data
      ) do
    emit_subprocess_child_started(
      data,
      flow_node_instance_id,
      child_process_instance_id,
      subprocess_node_id,
      child_process_model_id,
      child_version,
      is_event_subprocess,
      is_ad_hoc_subprocess
    )

    EspScope.maybe_emit_triggered(
      data,
      subprocess_node_id,
      child_process_instance_id,
      is_event_subprocess
    )

    {:keep_state, data}
  end

  def running(:info, {:event_subprocess_message, subprocess_node_id, payload}, data) do
    data = execute_esp_action(data, EspScope.resolve_trigger(data, subprocess_node_id, payload))
    maybe_finish_or_continue(data)
  end

  def running(:info, {:event_subprocess_signal, subprocess_node_id}, data) do
    data = execute_esp_action(data, EspScope.resolve_trigger(data, subprocess_node_id, %{}))
    maybe_finish_or_continue(data)
  end

  def running(
        :info,
        {:timer_fired, timer_ref,
         %{kind: :event_subprocess_start, subprocess_node_id: subprocess_node_id}},
        data
      ) do
    :ok = EspScope.emit_timer_fired(data, subprocess_node_id, timer_ref)
    data = execute_esp_action(data, EspScope.resolve_trigger(data, subprocess_node_id, %{}))
    maybe_finish_or_continue(data)
  end

  # Ad-hoc mode: activate an inner activity on demand from the parent handler
  def running(
        :cast,
        {:activate_adhoc_activity, flow_node_id, %Token{} = activation_token, reply_to},
        data
      ) do
    case Enum.find(data.process_model.flow_nodes, &(&1.id == flow_node_id)) do
      nil ->
        send(reply_to, {:adhoc_activation_result, flow_node_id, {:error, :activity_not_found}})
        {:keep_state, data}

      flow_node ->
        old_fni_ids = MapSet.new(Map.keys(data.flow_node_instance_states))
        data = dispatch_flow_node_instance(data, flow_node, activation_token, [])

        new_fni_ids =
          data.flow_node_instance_states
          |> Map.keys()
          |> Enum.reject(&MapSet.member?(old_fni_ids, &1))

        case new_fni_ids do
          [fni_id] ->
            emit_adhoc_activity_activated(data, flow_node_id, fni_id, "engine")

          _ ->
            :ok
        end

        send(reply_to, {:adhoc_activation_result, flow_node_id, :ok})
        {:keep_state, data}
    end
  end

  # Ad-hoc mode: parent handler signals that all initial activities have been
  # dispatched and no FEEL completion condition exists. The PI can finish
  # when all FNIs drain naturally. This does NOT set adhoc_completion_signaled
  # (which is reserved for FEEL conditions and explicit REST/plugin signals)
  # and does NOT trigger cancelRemainingInstances.
  def running(:cast, :adhoc_natural_drain_enabled, data) do
    data = %{data | adhoc_natural_drain_enabled: true}
    maybe_finish_or_continue(data)
  end

  # Ad-hoc mode: synchronous activity activation (REST/plugin facade)
  def running(
        {:call, from},
        {:activate_adhoc_activity_sync, flow_node_id},
        %{mode: AdHocMode} = data
      ) do
    result = do_activate_adhoc_activity(data, flow_node_id)
    {:keep_state, elem(result, 1), [{:reply, from, elem(result, 0)}]}
  end

  # Non-ad-hoc PI: reject ad-hoc operations
  def running({:call, from}, {:activate_adhoc_activity_sync, _flow_node_id}, data) do
    {:keep_state, data, [{:reply, from, {:error, :not_adhoc_subprocess}}]}
  end

  # Ad-hoc mode: synchronous completion signal (REST/plugin facade)
  def running({:call, from}, :signal_adhoc_completion_sync, %{mode: AdHocMode} = data) do
    if data.adhoc_completion_signaled do
      {:keep_state, data, [{:reply, from, {:error, :adhoc_already_completing}}]}
    else
      data = %{data | adhoc_completion_signaled: true}
      data = maybe_cancel_remaining_for_adhoc(data)
      maybe_finish_or_continue_with_reply(data, from)
    end
  end

  def running({:call, from}, :signal_adhoc_completion_sync, data) do
    {:keep_state, data, [{:reply, from, {:error, :not_adhoc_subprocess}}]}
  end

  # Ad-hoc mode: query inner activities with their enabled/performed status
  def running({:call, from}, :get_adhoc_enabled_activities, %{mode: AdHocMode} = data) do
    activities = build_adhoc_activities_list(data)
    {:keep_state, data, [{:reply, from, {:ok, activities}}]}
  end

  def running({:call, from}, :get_adhoc_enabled_activities, data) do
    {:keep_state, data, [{:reply, from, {:error, :not_adhoc_subprocess}}]}
  end

  # Ad-hoc mode: query current ad-hoc subprocess status
  def running({:call, from}, :get_adhoc_status, %{mode: AdHocMode} = data) do
    status = build_adhoc_status(data)
    {:keep_state, data, [{:reply, from, {:ok, status}}]}
  end

  def running({:call, from}, :get_adhoc_status, data) do
    {:keep_state, data, [{:reply, from, {:error, :not_adhoc_subprocess}}]}
  end

  def running(:info, {:compensation_scope_dispatch, run_key, target}, data) do
    data
    |> CompensationOrchestrator.start_scope_target(run_key, target, compensation_runtime())
    |> maybe_finish_or_continue()
  end

  def running(
        :info,
        {:compensation_scope_finished, _child_process_instance_id, scope_target_id,
         handler_count},
        data
      ) do
    case CompensationOrchestrator.take_scope_child(data, scope_target_id) do
      {nil, data} ->
        {:keep_state, data}

      {scope_child, data} ->
        data
        |> CompensationOrchestrator.finish_scope_target(
          scope_child,
          handler_count,
          compensation_runtime()
        )
        |> maybe_finish_or_continue()
    end
  end

  def running(
        :info,
        {:compensation_scope_failed, child_process_instance_id, scope_target_id, error_info},
        data
      ) do
    case CompensationOrchestrator.take_scope_child(data, scope_target_id) do
      {nil, data} ->
        {:keep_state, data}

      {scope_child, data} ->
        transition_to_fatal(
          data,
          {:compensation_scope_failed,
           %{
             subprocess_flow_node_id: scope_child.target.flow_node_id,
             child_process_instance_id: child_process_instance_id,
             reason: error_info
           }}
        )
    end
  end

  def running(
        :info,
        {:compensation_scope_aborted, _child_process_instance_id, scope_target_id, reason},
        data
      ) do
    case CompensationOrchestrator.take_scope_child(data, scope_target_id) do
      {nil, data} ->
        {:keep_state, data}

      {_scope_child, data} ->
        abort_process_instance(data, reason)
        {:stop, :normal, data}
    end
  end

  def running(
        :info,
        {:compensation_handler_dispatch_failed, run_key, handler_activity_id, reason},
        data
      ) do
    fatal_reason =
      {:compensation_handler_dispatch_failed,
       %{handler_activity_id: handler_activity_id, reason: reason}}

    data
    |> handle_fni_fatal(run_key, fatal_reason)
    |> transition_to_fatal(fatal_reason)
  end

  def running(:info, {:compensation_scope_start_failed, target, reason}, data) do
    transition_to_fatal(
      data,
      {:compensation_scope_start_failed,
       %{
         subprocess_flow_node_id: target.flow_node_id,
         child_process_instance_id: target.child_process_instance_id,
         reason: reason
       }}
    )
  end

  # A busy scope instance stopped: start it again for this requester. An
  # engine shutdown leaves the rows for resume; any other stop without a
  # reply failed the compensation.
  def running(
        :info,
        {:DOWN, _ref, :process, pid, reason},
        %{compensation_scope: %{children: scope_children}} = data
      )
      when is_map_key(scope_children, pid) do
    scope_child = Map.fetch!(scope_children, pid)
    data = put_in(data.compensation_scope.children, Map.delete(scope_children, pid))

    cond do
      scope_child.busy ->
        data
        |> CompensationOrchestrator.retry_scope_target(scope_child, compensation_runtime())
        |> maybe_finish_or_continue()

      engine_shutdown?(reason) ->
        {:stop, :shutdown, data}

      true ->
        transition_to_fatal(
          data,
          {:compensation_scope_failed,
           %{
             subprocess_flow_node_id: scope_child.target.flow_node_id,
             child_process_instance_id: scope_child.target.child_process_instance_id,
             reason: %{
               "error_code" => "compensation_scope_crashed",
               "message" =>
                 "The instance stopped before it reported the result of its compensation.",
               "detail" => JsonSafe.convert(reason)
             }
           }}
        )
    end
  end

  # The requester of a compensation scope instance went down: stop without
  # touching the rows, so the requester's resume compensates again.
  def running(
        :info,
        {:DOWN, _ref, :process, reply_to, _reason},
        %{compensation_scope: %{request: %{reply_to: reply_to}}} = data
      ) do
    MessageSubscriptions.unregister_all_for_process_instance(data.process_instance_id)
    SignalSubscriptions.unregister_all_for_process_instance(data.process_instance_id)
    {:stop, :shutdown, data}
  end

  # The Scheduler's ETS entries died with it; re-arm the ESP timer triggers
  # once it is back.
  def running(
        :info,
        {:DOWN, monitor_reference, :process, _object, _reason},
        %State{scheduler_monitor_reference: monitor_reference} = data
      ) do
    {:keep_state, %{data | scheduler_monitor_reference: nil},
     [
       {{:timeout, :rearm_event_subprocess_timers}, @scheduler_restart_wait_initial_ms,
        @scheduler_restart_wait_initial_ms}
     ]}
  end

  def running({:timeout, :rearm_event_subprocess_timers}, wait_ms, data) do
    if Process.whereis(Scheduler) do
      data = data |> EspScope.rearm_timer_triggers() |> monitor_scheduler_for_timer_triggers()
      {:keep_state, data}
    else
      retry_event_subprocess_timer_rearm(wait_ms)
    end
  catch
    # The Scheduler can die again between `whereis` and a `schedule` call.
    :exit, _reason -> retry_event_subprocess_timer_rearm(wait_ms)
  end

  # FNI Task process crashed (crash isolation)
  def running(:info, {:DOWN, _ref, :process, pid, reason}, data) when reason != :normal do
    case find_fni_by_pid(data, pid) do
      {flow_node_instance_id, %{state: state}} when state in [:active, :waiting] ->
        data = handle_fni_fatal(data, flow_node_instance_id, {:crash, reason})
        transition_to_fatal(data, {:fni_crash, flow_node_instance_id, reason})

      _ended_or_unknown ->
        {:keep_state, data}
    end
  end

  # Ignore normal exits from completed Task processes
  def running(:info, {:DOWN, _ref, :process, _pid, :normal}, data) do
    {:keep_state, data}
  end

  def running(
        {:call, from},
        {:finish_user_task, flow_node_instance_id, values, action_id, _identity},
        data
      ) do
    reply_inbox_completion(data, from, flow_node_instance_id, :user_task, :not_a_user_task, fn ->
      complete_waiting_inbox_task(data, from, flow_node_instance_id, values, action_id)
    end)
  end

  def running({:call, from}, {:confirm_manual_task, flow_node_instance_id, _identity}, data) do
    reply_inbox_completion(
      data,
      from,
      flow_node_instance_id,
      :manual_task,
      :not_a_manual_task,
      fn ->
        complete_waiting_inbox_task(data, from, flow_node_instance_id, nil)
      end
    )
  end

  def running({:call, from}, {:cancel_inbox_task, flow_node_instance_id, reason, _identity}, data) do
    case Map.get(data.flow_node_instance_states, flow_node_instance_id) do
      %{state: :waiting} = entry ->
        cancel_waiting_fni(data, flow_node_instance_id, entry, reason)

        data = handle_fni_aborted(data, flow_node_instance_id, reason)
        abort_process_instance(data, reason)
        {:stop_and_reply, :normal, [{:reply, from, :ok}], data}

      %{state: state} ->
        {:keep_state, data, [{:reply, from, {:error, normalize_terminal_state_error(state)}}]}

      nil ->
        {:keep_state, data, [{:reply, from, {:error, :fni_not_found}}]}
    end
  end

  def running(
        {:call, from},
        {:finish_async_service_task, flow_node_instance_id, result} = request,
        data
      ) do
    case validate_async_fni(data, flow_node_instance_id) do
      {:ok, entry} ->
        complete_waiting_fni(data, from, flow_node_instance_id, entry, result)

      {:error, :fni_not_parked_yet} ->
        store_early_async_completion(data, from, flow_node_instance_id, request)

      {:error, reason} ->
        {:keep_state, data, [{:reply, from, {:error, reason}}]}
    end
  end

  def running(
        {:call, from},
        {:fail_async_service_task, flow_node_instance_id, error_code, error_message} = request,
        data
      ) do
    case validate_async_fni(data, flow_node_instance_id) do
      {:ok, _entry} ->
        reason = %{error_code: error_code, error_message: error_message}

        apply_error_boundary_or_fatal(
          data,
          from,
          flow_node_instance_id,
          reason,
          :ok
        )

      {:error, :fni_not_parked_yet} ->
        store_early_async_completion(data, from, flow_node_instance_id, request)

      {:error, reason} ->
        {:keep_state, data, [{:reply, from, {:error, reason}}]}
    end
  end

  def running(:internal, {:apply_early_async_completion, flow_node_instance_id}, data) do
    case Map.pop(data.early_async_completions, flow_node_instance_id) do
      {nil, _stored} ->
        :keep_state_and_data

      {request, stored} ->
        {:call, @early_completion_caller}
        |> running(request, %{data | early_async_completions: stored})
        |> fail_rejected_early_completion(flow_node_instance_id)
        |> without_early_completion_replies(flow_node_instance_id)
    end
  end

  # Force-fatal call — used by CallActivity.handle_fatal/1 to cascade fatal
  # to child PIs. Mirrors the internal transition_to_fatal path but as a
  # synchronous gen_statem.call so the parent blocks until the child is dead.
  def running({:call, from}, {:force_fatal, reason}, data) do
    do_transition_to_fatal(data, reason, [{:reply, from, :ok}])
  end

  def running({:call, from}, {:trigger_timer_event, flow_node_instance_id}, data) do
    case Map.get(data.flow_node_instance_states, flow_node_instance_id) do
      %{state: state, pid: pid} when state in [:active, :waiting] and pid != nil ->
        reply =
          if Scheduler.fire_now_for_target(pid) > 0, do: :ok, else: {:error, :timer_not_armed}

        {:keep_state, data, [{:reply, from, reply}]}

      _other ->
        {:keep_state, data, [{:reply, from, {:error, :fni_not_active_or_found}}]}
    end
  end

  def running({:call, from}, {:trigger_escalation, escalation_info}, data) do
    {data, deliveries} = deliver_api_escalation(data, escalation_info)
    reply_api_escalation_trigger(data, from, deliveries)
  end

  def running({:call, from}, {:abort, reason, _identity}, data) do
    abort_process_instance(data, reason)
    {:stop_and_reply, :normal, [{:reply, from, :ok}], data}
  end

  # UpdateNotifyPid — used by Call Activity handler to re-establish
  # parent notification after engine restart.
  def running({:call, from}, {:update_notify_pid, new_pid}, data) do
    {:keep_state, %{data | notify_pid: new_pid}, [{:reply, from, :ok}]}
  end

  def running(:info, {:EXIT, task_supervisor, reason}, %{task_supervisor: task_supervisor} = data) do
    {:stop, reason, data}
  end

  def running(:info, {:EXIT, _pid, :normal}, data), do: {:keep_state, data}

  def running(:info, message, data) do
    Logger.warning(
      "PI #{data.process_instance_id} ignored an unexpected message: #{inspect(message, limit: 10)}"
    )

    {:keep_state, data}
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
  # Terminate callback — clean up linked Task.Supervisor
  # -------------------------------------------------------------------

  # On an engine shutdown rows are left as they are so that resume can pick the
  # instance up again, and handler Tasks are killed rather than shut down:
  # iteration Tasks trap exits and would otherwise hold the supervisor shutdown
  # past @shutdown_timeout. Any other stop lets them finish their writes.
  # Stored early completions are dropped with a warning. A running instance that stops with any other
  # abnormal reason goes through the fatal cascade first; otherwise its rows
  # would stay `running` until the next boot resumed it. When its supervisor
  # died, the instance went down with it and its rows stay `running` on purpose.
  @impl :gen_statem
  def terminate(reason, state, %{early_async_completions: stored} = data)
      when map_size(stored) > 0 do
    Enum.each(stored, fn {flow_node_instance_id, _request} ->
      warn_dropped_early_completion(flow_node_instance_id, "the process instance stopped")
    end)

    terminate(reason, state, %{data | early_async_completions: %{}})
  end

  def terminate(reason, state, data) do
    if state == :running and reason != :normal and not engine_shutdown?(reason) and
         supervisor_alive?() do
      record_crash(data, reason)
    end

    stop_task_supervisor(reason, data)
    if engine_shutdown?(reason), do: unregister_killed_handler_subscriptions(data)
    :ok
  end

  defp supervisor_alive? do
    case Process.info(self(), :parent) do
      {:parent, supervisor} when is_pid(supervisor) -> Process.alive?(supervisor)
      _no_parent -> true
    end
  end

  # A failure here must not replace the original exit reason.
  defp record_crash(data, reason) do
    Logger.error(
      "PI #{data.process_instance_id} crashed and is set to fatal: #{inspect(reason, limit: 10)}"
    )

    _stop =
      do_transition_to_fatal(
        data,
        ErrorInfo.process_instance_crashed(data.process_instance_id, reason),
        []
      )

    :ok
  rescue
    exception ->
      Logger.error(
        "PI #{data.process_instance_id} could not record its crash: #{Exception.message(exception)}"
      )
  catch
    :exit, _reason -> :ok
  end

  defp stop_task_supervisor(reason, %{task_supervisor: task_supervisor})
       when is_pid(task_supervisor) do
    if Process.alive?(task_supervisor) do
      Process.unlink(task_supervisor)

      if engine_shutdown?(reason) do
        task_supervisor
        |> Task.Supervisor.children()
        |> Enum.each(&Process.exit(&1, :kill))
      end

      Supervisor.stop(task_supervisor, :shutdown, @shutdown_timeout)
    end

    :ok
  catch
    :exit, _reason -> :ok
  end

  defp stop_task_supervisor(_reason, _data), do: :ok

  # Runs after the Task.Supervisor has stopped, so no killed handler can
  # register again; the resumed instance registers afresh.
  defp unregister_killed_handler_subscriptions(data) do
    data.flow_node_instance_states
    |> Enum.filter(fn {_id, entry} -> entry.state in [:active, :waiting] end)
    |> Enum.each(fn {flow_node_instance_id, _entry} ->
      MessageSubscriptions.unregister_all_for_flow_node_instance(flow_node_instance_id)
      SignalSubscriptions.unregister_all_for_flow_node_instance(flow_node_instance_id)
    end)
  rescue
    ArgumentError -> :ok
  end

  defp engine_shutdown?(:shutdown), do: true
  defp engine_shutdown?({:shutdown, _detail}), do: true
  defp engine_shutdown?(_reason), do: false

  # -------------------------------------------------------------------
  # Internal: FNI dispatch cycle
  # -------------------------------------------------------------------

  defp dispatch_flow_node_instance(
         data,
         %FlowNode{} = flow_node,
         %Token{} = token,
         previous_flow_node_instance_ids,
         incoming_flow_id \\ nil
       ) do
    case join_gateway_check(flow_node, data.process_model) do
      {:join, gateway_type, required} ->
        incoming_flow_id =
          incoming_flow_id ||
            resolve_incoming_sequence_flow_id(data, flow_node, previous_flow_node_instance_ids)

        dispatch_join(
          gateway_type,
          data,
          flow_node,
          token,
          previous_flow_node_instance_ids,
          required,
          incoming_flow_id
        )

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
       when gateway_type in [:parallel_gateway, :inclusive_gateway, :complex_gateway] do
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

  defp dispatch_join(
         gateway_type,
         data,
         flow_node,
         token,
         previous_flow_node_instance_ids,
         required,
         incoming_flow_id
       ) do
    case live_join_routing(data, flow_node.id) do
      nil ->
        data
        |> dispatch_join_first_token(
          flow_node,
          token,
          previous_flow_node_instance_ids,
          required,
          gateway_type,
          incoming_flow_id
        )
        |> augment_complex_join_routing(flow_node, token.payload)

      %{fired: true} ->
        # A straggler from a branch that finished just before the region was
        # cancelled; the join outcome is already decided.
        Logger.debug(
          "ProcessInstance: dropping straggler token at already-fired complex join " <>
            "'#{flow_node.id}' (arrived via '#{incoming_flow_id}')"
        )

        data

      %{fni_id: fni_id, arrived_via_flow_ids: arrived_via} = routing ->
        if MapSet.member?(arrived_via, incoming_flow_id) and incoming_flow_id != "unknown" do
          error_info =
            ErrorInfo.build(
              {:duplicate_join_arrival,
               %{flow_node_id: flow_node.id, incoming_flow_id: incoming_flow_id}}
            )

          record_fni_fatal(
            data,
            fni_id,
            flow_node,
            token,
            previous_flow_node_instance_ids,
            error_info
          )
        else
          route_subsequent_join_token(
            data,
            routing,
            flow_node,
            token,
            previous_flow_node_instance_ids,
            incoming_flow_id
          )
        end
    end
  end

  # A routing entry whose join FNI already ended belongs to an earlier pass
  # through the join (loop re-entry); the next arrival starts a new join FNI.
  defp live_join_routing(data, flow_node_id) do
    with %{fni_id: fni_id} = routing <- Map.get(data.join_routing, flow_node_id),
         %{state: state} when state in [:active, :waiting] <-
           Map.get(data.flow_node_instance_states, fni_id) do
      routing
    else
      _missing_or_ended -> nil
    end
  end

  defp augment_complex_join_routing(data, %FlowNode{type: :complex_gateway} = flow_node, payload) do
    case Map.get(data.join_routing, flow_node.id) do
      nil ->
        data

      routing ->
        augmented =
          Map.merge(routing, %{
            activation_condition: complex_activation_condition(flow_node),
            merged_payload: payload || %{},
            fired: false
          })

        put_in(data.join_routing[flow_node.id], augmented)
    end
  end

  defp augment_complex_join_routing(data, _flow_node, _payload), do: data

  defp route_subsequent_join_token(
         data,
         routing,
         flow_node,
         token,
         previous_flow_node_instance_ids,
         incoming_flow_id
       ) do
    routing = record_join_arrival(routing, incoming_flow_id, token.payload)

    data
    |> store_join_routing(flow_node.id, routing)
    |> route_token_to_join_handler(
      routing.fni_id,
      flow_node,
      token,
      previous_flow_node_instance_ids,
      incoming_flow_id
    )
  end

  defp record_join_arrival(%{gateway_type: :complex_gateway} = routing, incoming_flow_id, payload) do
    routing
    |> Map.put(:arrived_via_flow_ids, MapSet.put(routing.arrived_via_flow_ids, incoming_flow_id))
    |> Map.put(
      :merged_payload,
      Map.merge(Map.get(routing, :merged_payload) || %{}, payload || %{})
    )
  end

  defp record_join_arrival(routing, incoming_flow_id, _payload) do
    %{routing | arrived_via_flow_ids: MapSet.put(routing.arrived_via_flow_ids, incoming_flow_id)}
  end

  # The parallel join handler fires on its last arrival; dropping the entry
  # then lets a token of the next pass start a new join FNI.
  defp store_join_routing(data, flow_node_id, %{gateway_type: :parallel_gateway} = routing) do
    if MapSet.size(routing.arrived_via_flow_ids) >= routing.required do
      %{data | join_routing: Map.delete(data.join_routing, flow_node_id)}
    else
      put_in(data.join_routing[flow_node_id], routing)
    end
  end

  defp store_join_routing(data, flow_node_id, routing) do
    put_in(data.join_routing[flow_node_id], routing)
  end

  defp complex_activation_condition(%FlowNode{type_data: %{activation_condition: condition}}),
    do: condition

  defp complex_activation_condition(_flow_node), do: nil

  defp dispatch_join_first_token(
         data,
         flow_node,
         token,
         previous_flow_node_instance_ids,
         required,
         gateway_type,
         incoming_flow_id
       ) do
    flow_node_instance_id = UuidV7.generate()
    lane_name = LaneResolution.resolve_lane_name(data.process_model, flow_node)

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
        record_fni_fatal(
          data,
          UuidV7.generate(),
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

  defp spawn_join_fni_task(
         data,
         flow_node_instance_id,
         flow_node,
         token,
         previous_flow_node_instance_ids,
         handler_module,
         join_metadata
       ) do
    process_instance_pid = self()

    handler_context =
      InstanceHandlerDispatch.build_handler_context(
        data,
        flow_node_instance_id,
        flow_node,
        process_instance_pid
      )
      |> Map.put(:join_metadata, join_metadata)

    case Task.Supervisor.start_child(data.task_supervisor, fn ->
           result =
             BoundaryAwareHandler.wrap_enter(handler_module, flow_node, token, handler_context)

           InstanceHandlerDispatch.dispatch_handler_result(
             process_instance_pid,
             flow_node_instance_id,
             result
           )
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

  defp route_token_to_join_handler(
         data,
         fni_id,
         _flow_node,
         token,
         previous_flow_node_instance_ids,
         incoming_flow_id
       ) do
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
    flow_node_instance_id = UuidV7.generate()
    lane_name = LaneResolution.resolve_lane_name(data.process_model, flow_node)

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
      InstanceHandlerDispatch.build_handler_context(
        data,
        flow_node_instance_id,
        flow_node,
        process_instance_pid
      )

    :ok =
      InstanceHandlerDispatch.register_service_task_completion_route(
        flow_node,
        flow_node_instance_id,
        nil
      )

    case Task.Supervisor.start_child(data.task_supervisor, fn ->
           result =
             BoundaryAwareHandler.wrap_enter(handler_module, flow_node, token, handler_context)

           InstanceHandlerDispatch.dispatch_handler_result(
             process_instance_pid,
             flow_node_instance_id,
             result
           )
         end) do
      {:ok, task_pid} ->
        Process.monitor(task_pid)

        entry = %{
          pid: task_pid,
          flow_node_id: flow_node.id,
          flow_node_type: flow_node.type,
          event_type: FlowNodeLookup.extract_event_type(flow_node),
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
    existing_entry = Map.get(data.flow_node_instance_states, flow_node_instance_id)

    _persist_result =
      FniLifecycle.transition_to_fatal(
        flow_node_instance_id,
        data.process_instance_id,
        error_details,
        flow_node,
        %{},
        LaneResolution.resolve_lane_name(data.process_model, flow_node),
        data.root_process_instance_id,
        was_waiting: false,
        multi_instance_id: if(existing_entry, do: Map.get(existing_entry, :multi_instance_id)),
        iteration_index: if(existing_entry, do: Map.get(existing_entry, :iteration_index))
      )

    entry = %{
      pid: nil,
      flow_node_id: flow_node.id,
      flow_node_type: flow_node.type,
      event_type: FlowNodeLookup.extract_event_type(flow_node),
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
      %{state: state} = entry when state in [:finished, :fatal, :aborted, :interrupted, :error] ->
        release_late_handler(data, flow_node_instance_id, entry)

      nil ->
        data

      %{interrupt_requested: true} = entry ->
        finish_interrupted_iteration(data, flow_node_instance_id, entry)

      entry ->
        if EventBasedGatewayOrchestrator.pending_cancel?(entry) do
          send_async_gate(entry.pid, :cancel)

          data
          |> EventBasedGatewayOrchestrator.interrupt_pending_loser(flow_node_instance_id)
          |> flush_event_based_gateway_deferred_dispatch()
        else
          do_handle_fni_async(data, flow_node_instance_id, entry, extra_type_properties)
        end
    end
  end

  # A boundary handler left alive while `:active` (BoundaryOrchestrator) may
  # have registered a subscription or armed a timer after its FNI ended.
  defp release_late_handler(data, flow_node_instance_id, %{pid: pid} = entry) when is_pid(pid) do
    flow_node = FlowNodeLookup.find_flow_node(data, entry.flow_node_id)

    InstanceHandlerDispatch.release_handler(
      flow_node,
      flow_node_instance_id,
      :handle_aborted,
      entry
    )

    send_async_gate(pid, :cancel)
    put_in(data.flow_node_instance_states[flow_node_instance_id], %{entry | pid: nil})
  end

  defp release_late_handler(data, _flow_node_instance_id, _entry), do: data

  defp merge_fni_type_properties(data, flow_node_instance_id, extra_type_properties) do
    case Map.get(data.flow_node_instance_states, flow_node_instance_id) do
      nil ->
        data

      entry ->
        merged_type_properties = Map.merge(entry.type_properties || %{}, extra_type_properties)

        put_in(
          data.flow_node_instance_states[flow_node_instance_id],
          %{entry | type_properties: merged_type_properties}
        )
    end
  end

  defp parked_type_properties(nil, extra_type_properties),
    do: parked_type_properties(%{}, extra_type_properties)

  defp parked_type_properties(current_type_properties, extra_type_properties) do
    current_type_properties
    |> Map.take(@compensation_link_keys)
    |> Map.put(:async, true)
    |> Map.merge(Map.delete(extra_type_properties, :persisted))
  end

  defp do_handle_fni_async(data, flow_node_instance_id, entry, extra_type_properties) do
    type_properties = parked_type_properties(entry.type_properties, extra_type_properties)

    needs_registry =
      not is_map_key(extra_type_properties, :host_flow_node_instance_id) and
        not is_map_key(extra_type_properties, :fire_at) and
        not is_map_key(extra_type_properties, :join_gateway) and
        not is_map_key(extra_type_properties, :awaiting_condition) and
        not is_map_key(extra_type_properties, :mi_shell)

    _ =
      if needs_registry do
        Registry.register(
          BfwEngine.Execution.Registry,
          {:fni, flow_node_instance_id},
          :async
        )
      end

    _ =
      if is_map_key(extra_type_properties, :join_gateway) do
        FniLifecycle.transition_to_waiting_by_id(flow_node_instance_id, type_properties)
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

    send_async_gate(entry.pid, :continue)

    maybe_register_conditional_waiter(data, flow_node_instance_id, entry, extra_type_properties)
  end

  defp maybe_register_conditional_waiter(data, fni_id, entry, extra_type_properties) do
    if Map.get(extra_type_properties, :awaiting_condition) do
      flow_node = FlowNodeLookup.find_flow_node(data, entry.flow_node_id)
      {:ok, handler_module} = HandlerDispatch.handler_for(flow_node)
      token_payload = entry.token.payload

      is_boundary = Map.has_key?(extra_type_properties, :host_flow_node_instance_id)

      opts =
        if is_boundary do
          %{
            position: :boundary,
            cancel_activity: Map.get(extra_type_properties, :cancel_activity)
          }
        else
          %{position: :intermediate_catch}
        end

      data =
        register_conditional_waiter(data, fni_id, flow_node, handler_module, token_payload, opts)

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

      %{state: state} = entry when state in [:active, :waiting] ->
        validate_async_live_entry(data, entry)

      %{state: _other} ->
        {:error, :fni_not_waiting}
    end
  end

  defp validate_async_live_entry(data, entry) do
    flow_node = FlowNodeLookup.find_flow_node(data, entry.flow_node_id)

    cond do
      multi_instance_shell?(flow_node, entry) -> {:error, :fni_is_multi_instance_shell}
      entry.state == :waiting -> validate_async_waiting_entry(entry)
      entry.flow_node_type == :service_task -> {:error, :fni_not_parked_yet}
      true -> {:error, :fni_not_waiting}
    end
  end

  # A plugin may complete its Service Task before `handle_enter/3` returned
  # `{:async, …}`. The call is answered at once and its request is kept in
  # memory only; once the flow node instance leaves `:active` the request is
  # replayed, and dropped with a warning unless the instance is `:waiting`.
  defp store_early_async_completion(data, from, flow_node_instance_id, request) do
    if Map.has_key?(data.early_async_completions, flow_node_instance_id) do
      {:keep_state, data, [{:reply, from, {:error, :fni_not_waiting}}]}
    else
      {:keep_state, put_in(data.early_async_completions[flow_node_instance_id], request),
       [{:reply, from, :ok}]}
    end
  end

  defp release_early_async_completions(%{early_async_completions: stored} = data)
       when map_size(stored) == 0,
       do: {data, []}

  # Released requests stay stored until their event applies them, so a stop
  # caused by an earlier one still warns about the rest in `terminate/3`.
  defp release_early_async_completions(data) do
    actions =
      for {flow_node_instance_id, _request} <- data.early_async_completions,
          not match?(
            %{state: :active},
            Map.get(data.flow_node_instance_states, flow_node_instance_id)
          ) do
        {:next_event, :internal, {:apply_early_async_completion, flow_node_instance_id}}
      end

    {data, actions}
  end

  # A live caller can retry a rejected result; a replayed one cannot, so the
  # waiting task fails instead of waiting forever.
  defp fail_rejected_early_completion(
         {:keep_state, data, actions} = result,
         flow_node_instance_id
       ) do
    reason =
      Enum.find_value(actions, fn
        {:reply, @early_completion_caller, {:error, {:contract_violation, _} = violation}} ->
          violation

        {:reply, @early_completion_caller, {:error, :payload_too_large, details}} ->
          {:payload_too_large, details}

        _action ->
          nil
      end)

    if reason != nil and
         match?(%{state: :waiting}, data.flow_node_instance_states[flow_node_instance_id]) do
      apply_error_boundary_or_fatal(
        data,
        @early_completion_caller,
        flow_node_instance_id,
        reason,
        :ok
      )
    else
      result
    end
  end

  defp fail_rejected_early_completion(result, _flow_node_instance_id), do: result

  # The replayed request has no caller; its replies are dropped, an error reply
  # with a warning.
  defp without_early_completion_replies({:keep_state, data, actions}, flow_node_instance_id),
    do: {:keep_state, data, drop_early_completion_replies(actions, flow_node_instance_id)}

  defp without_early_completion_replies(
         {:stop_and_reply, reason, replies, data},
         flow_node_instance_id
       ) do
    case drop_early_completion_replies(replies, flow_node_instance_id) do
      [] -> {:stop, reason, data}
      remaining -> {:stop_and_reply, reason, remaining, data}
    end
  end

  defp without_early_completion_replies(result, _flow_node_instance_id), do: result

  defp drop_early_completion_replies(actions, flow_node_instance_id) do
    Enum.reject(actions, fn
      {:reply, @early_completion_caller, :ok} ->
        true

      {:reply, @early_completion_caller, error} ->
        warn_dropped_early_completion(
          flow_node_instance_id,
          "applying it answered #{inspect(error)}"
        )

        true

      _action ->
        false
    end)
  end

  defp warn_dropped_early_completion(flow_node_instance_id, cause) do
    Logger.warning(
      "Dropped the early async completion of flow node instance #{flow_node_instance_id}: #{cause}"
    )
  end

  # Gates plugin `finish_async_service_task` / `fail_async_service_task` only.
  # Catch events, timers, joins, Call Activity, and MI/loop shells also park
  # in `:waiting` via `{:async, id, continuation}` and stamp `async: true` —
  # that flag is the async return shape, not permission for the plugin
  # callback API. MI/loop shells are refused before this check. Only
  # ServiceTask implements `handle_complete/4` for that path.
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
    do_transition_to_fatal(data, reason, [{:reply, from, :ok}])
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

      entry ->
        throw_fni_id = compensation_throw_fni_id(entry)
        esp_throw_fni_id = compensation_esp_throw_fni_id(data, entry)

        cond do
          # An iteration whose shell has not re-attached yet after a resume:
          # the shell reads it from the snapshot as a finished iteration.
          is_binary(Map.get(entry, :multi_instance_id)) ->
            finish_iteration_entry(data, flow_node_instance_id, result)

          throw_fni_id != nil ->
            handle_compensation_handler_finished(
              data,
              flow_node_instance_id,
              result,
              throw_fni_id
            )

          esp_throw_fni_id != nil ->
            handle_compensation_esp_finished(
              data,
              flow_node_instance_id,
              result,
              esp_throw_fni_id
            )

          EventBasedGatewayOrchestrator.pending_cancel?(entry) ->
            data
            |> EventBasedGatewayOrchestrator.interrupt_pending_loser(flow_node_instance_id)
            |> flush_event_based_gateway_deferred_dispatch()

          true ->
            do_handle_fni_ok(data, flow_node_instance_id, result)
        end
    end
  end

  defp compensation_throw_fni_id(entry) do
    type_properties = entry.type_properties || %{}

    Map.get(type_properties, :compensation_throw_fni_id) ||
      Map.get(type_properties, "compensation_throw_fni_id")
  end

  defp compensation_esp_throw_fni_id(data, entry) do
    Map.get(data.compensation_esp_throw_map, entry.flow_node_id)
  end

  defp handle_compensation_handler_finished(data, flow_node_instance_id, result, throw_fni_id) do
    entry = Map.fetch!(data.flow_node_instance_states, flow_node_instance_id)
    output_payload = result.output_payload || entry.token.payload

    cache_updates =
      extract_cache_updates(result.metadata)

    data = %{data | data_object_cache: Map.merge(data.data_object_cache, cache_updates)}

    data =
      put_in(data.flow_node_instance_states[flow_node_instance_id], %{
        entry
        | state: :finished,
          pid: nil,
          token: %{entry.token | payload: output_payload}
      })

    emit_activity_compensated(data, flow_node_instance_id, entry, throw_fni_id)

    # A handler resumed from an earlier scope run belongs to this run now.
    case data.compensation_scope.request do
      %{anchor_flow_node_instance_id: anchor_flow_node_instance_id} ->
        advance_compensation_run(data, anchor_flow_node_instance_id)

      nil ->
        advance_compensation_run(data, throw_fni_id)
    end
  end

  defp handle_compensation_esp_finished(data, flow_node_instance_id, result, throw_fni_id) do
    entry = Map.fetch!(data.flow_node_instance_states, flow_node_instance_id)
    output_payload = result.output_payload || entry.token.payload

    cache_updates =
      extract_cache_updates(result.metadata)

    data = %{data | data_object_cache: Map.merge(data.data_object_cache, cache_updates)}

    data =
      put_in(data.flow_node_instance_states[flow_node_instance_id], %{
        entry
        | state: :finished,
          pid: nil,
          token: %{entry.token | payload: output_payload}
      })

    data = %{
      data
      | compensation_esp_throw_map:
          Map.delete(data.compensation_esp_throw_map, entry.flow_node_id)
    }

    CompensationOrchestrator.finish_run(
      data,
      throw_fni_id,
      Map.fetch!(data.compensation_runs, throw_fni_id),
      compensation_runtime()
    )
  end

  defp do_handle_fni_ok(data, flow_node_instance_id, %FlowNodeResult{} = result) do
    entry = Map.fetch!(data.flow_node_instance_states, flow_node_instance_id)
    output_payload = result.output_payload || entry.token.payload

    cache_updates =
      extract_cache_updates(result.metadata)

    data = %{data | data_object_cache: Map.merge(data.data_object_cache, cache_updates)}
    dispatch_successors(data, flow_node_instance_id, entry, output_payload, result)
  end

  defp dispatch_successors(data, flow_node_instance_id, entry, output_payload, result) do
    data =
      EventBasedGatewayOrchestrator.cancel_sibling_catch_flow_node_instances(
        data,
        flow_node_instance_id
      )

    data =
      put_in(data.flow_node_instance_states[flow_node_instance_id], %{
        entry
        | state: :finished,
          pid: nil,
          token: %{entry.token | payload: output_payload}
      })

    data = maybe_push_compensation_registry(data, flow_node_instance_id)

    data =
      if BoundaryOrchestrator.has_boundary_fnis?(data, flow_node_instance_id) do
        BoundaryOrchestrator.cancel_boundary_fnis_for_host(data, flow_node_instance_id)
      else
        data
      end

    if EventBasedGatewayOrchestrator.has_active_pending_cancel_siblings?(data) do
      EventBasedGatewayOrchestrator.defer_successor_dispatch(
        data,
        flow_node_instance_id,
        output_payload,
        result.next_flow_node_ids,
        result.taken_sequence_flow_ids
      )
    else
      dispatch_successor_targets(
        data,
        flow_node_instance_id,
        output_payload,
        result.next_flow_node_ids,
        result.taken_sequence_flow_ids
      )
    end
  end

  defp flush_event_based_gateway_deferred_dispatch(data) do
    {data, deferred} = EventBasedGatewayOrchestrator.take_ready_deferred_dispatch(data)

    case deferred do
      nil ->
        data

      %{
        winning_flow_node_instance_id: winning_flow_node_instance_id,
        output_payload: output_payload,
        next_flow_node_ids: next_flow_node_ids
      } = deferred_dispatch ->
        dispatch_successor_targets(
          data,
          winning_flow_node_instance_id,
          output_payload,
          next_flow_node_ids,
          Map.get(deferred_dispatch, :taken_sequence_flow_ids)
        )
    end
  end

  defp dispatch_successor_targets(
         data,
         originating_flow_node_instance_id,
         output_payload,
         next_flow_node_ids,
         taken_sequence_flow_ids \\ nil
       ) do
    new_token = %Token{
      id: UuidV7.generate(),
      process_instance_id: data.process_instance_id,
      payload: output_payload,
      originating_flow_node_instance_id: originating_flow_node_instance_id,
      created_at: DateTime.utc_now()
    }

    node_index = Map.new(data.process_model.flow_nodes, &{&1.id, &1})

    source_flow_node_id =
      get_in(data.flow_node_instance_states, [originating_flow_node_instance_id, :flow_node_id])

    {_dispatched_counts, data} =
      next_flow_node_ids
      |> Enum.zip(taken_flow_ids_per_target(next_flow_node_ids, taken_sequence_flow_ids))
      |> Enum.map(fn {target_node_id, taken_flow_id} ->
        {Map.get(node_index, target_node_id), taken_flow_id}
      end)
      |> Enum.reject(fn {target_node, _taken_flow_id} -> is_nil(target_node) end)
      |> Enum.reduce({%{}, data}, fn {target_node, taken_flow_id},
                                     {dispatched_counts, accumulator} ->
        occurrence = Map.get(dispatched_counts, target_node.id, 0)

        incoming_flow_id =
          taken_flow_id ||
            nth_sequence_flow_id(
              data.process_model,
              source_flow_node_id,
              target_node.id,
              occurrence
            )

        accumulator =
          dispatch_flow_node_instance(
            accumulator,
            target_node,
            new_token,
            [originating_flow_node_instance_id],
            incoming_flow_id
          )

        {Map.put(dispatched_counts, target_node.id, occurrence + 1), accumulator}
      end)

    data
  end

  defp taken_flow_ids_per_target(next_flow_node_ids, taken_sequence_flow_ids)
       when is_list(taken_sequence_flow_ids) and
              length(taken_sequence_flow_ids) == length(next_flow_node_ids),
       do: taken_sequence_flow_ids

  defp taken_flow_ids_per_target(next_flow_node_ids, _taken_sequence_flow_ids),
    do: List.duplicate(nil, length(next_flow_node_ids))

  # Two sequence flows from one source to the same target yield the target
  # twice in `next_flow_node_ids`; each occurrence travels its own flow.
  defp nth_sequence_flow_id(_process_model, nil, _target_node_id, _occurrence), do: nil

  defp nth_sequence_flow_id(process_model, source_flow_node_id, target_node_id, occurrence) do
    process_model.sequence_flows
    |> Enum.filter(&(&1.source_ref == source_flow_node_id and &1.target_ref == target_node_id))
    |> Enum.at(occurrence)
    |> case do
      nil -> nil
      sequence_flow -> sequence_flow.id
    end
  end

  defp handle_fni_wait(data, flow_node_instance_id, %FlowNodeResult{} = result) do
    case Map.get(data.flow_node_instance_states, flow_node_instance_id) do
      %{state: state} when state in [:finished, :fatal, :aborted, :interrupted, :error] ->
        data

      nil ->
        data

      %{interrupt_requested: true} = entry ->
        finish_interrupted_iteration(data, flow_node_instance_id, entry)

      entry ->
        if EventBasedGatewayOrchestrator.pending_cancel?(entry) do
          data
          |> EventBasedGatewayOrchestrator.interrupt_pending_loser(flow_node_instance_id)
          |> flush_event_based_gateway_deferred_dispatch()
        else
          park_waiting_fni(data, flow_node_instance_id, entry, result)
        end
    end
  end

  defp park_waiting_fni(data, flow_node_instance_id, entry, result) do
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

    :ok = publish_inbox_task_created(data, flow_node_instance_id, entry, merged_type_properties)

    if result.metadata[:awaiting_condition] do
      maybe_register_conditional_waiter_from_wait(data, flow_node_instance_id, entry)
    else
      data
    end
  end

  # Published only after the entry is `:waiting`, so a finish call sent in
  # reaction to the event is never answered `fni_not_waiting`.
  defp publish_inbox_task_created(data, flow_node_instance_id, entry, type_properties) do
    flow_node = FlowNodeLookup.find_flow_node(data, entry.flow_node_id)

    if TaskInboxEvents.inbox_task?(flow_node) do
      context =
        InstanceHandlerDispatch.build_handler_context(
          data,
          flow_node_instance_id,
          flow_node,
          self()
        )

      TaskInboxEvents.publish_created(
        context,
        flow_node,
        Map.get(type_properties, :assignees, [])
      )
    else
      :ok
    end
  end

  defp handle_fni_error_result(data, flow_node_instance_id, reason) do
    case Map.get(data.flow_node_instance_states, flow_node_instance_id) do
      %{state: state} when state in [:finished, :fatal, :aborted, :interrupted, :error] ->
        {:keep_state, data}

      nil ->
        {:keep_state, data}

      entry ->
        if EventBasedGatewayOrchestrator.pending_cancel?(entry) do
          data =
            data
            |> EventBasedGatewayOrchestrator.interrupt_pending_loser(flow_node_instance_id)
            |> flush_event_based_gateway_deferred_dispatch()

          maybe_finish_or_continue(data)
        else
          resolve_or_fatal_flow_node_error(data, flow_node_instance_id, reason)
        end
    end
  end

  defp resolve_or_fatal_flow_node_error(data, flow_node_instance_id, reason) do
    case shell_error_boundary(data, flow_node_instance_id, reason) do
      {:boundary, boundary_node_id, payload, cancel_activity} ->
        data
        |> apply_boundary_catch_or_cycle_fire(
          flow_node_instance_id,
          boundary_node_id,
          payload,
          cancel_activity,
          nil,
          :catch
        )
        |> maybe_finish_or_continue()

      :none ->
        resolve_esp_or_fatal_flow_node_error(data, flow_node_instance_id, reason)
    end
  end

  # An MI or Standard Loop shell reports its errors from its continuation,
  # outside `BoundaryAwareHandler.wrap_enter/4`.
  defp shell_error_boundary(data, flow_node_instance_id, reason) do
    entry = Map.fetch!(data.flow_node_instance_states, flow_node_instance_id)
    flow_node = FlowNodeLookup.find_flow_node(data, entry.flow_node_id)

    with true <- multi_instance_shell?(flow_node, entry),
         context =
           InstanceHandlerDispatch.build_handler_context(
             data,
             flow_node_instance_id,
             flow_node,
             self()
           ),
         {:boundary, _node_id, _payload, _cancel_activity} = boundary <-
           BoundaryAwareHandler.attempt_error_boundary_catch(flow_node, context, reason) do
      boundary
    else
      _not_caught -> :none
    end
  end

  defp multi_instance_shell?(%FlowNode{} = flow_node, entry) do
    (flow_node.multi_instance != nil or flow_node.standard_loop != nil) and
      is_nil(Map.get(entry, :multi_instance_id))
  end

  defp multi_instance_shell?(_flow_node, _entry), do: false

  defp resolve_esp_or_fatal_flow_node_error(data, flow_node_instance_id, reason) do
    case EspScope.resolve_error_catch(data, flow_node_instance_id, reason) do
      {:caught, data, action} ->
        data = execute_esp_action(data, action)
        maybe_finish_or_continue(data)

      :not_caught ->
        data = handle_fni_fatal(data, flow_node_instance_id, reason)
        transition_to_fatal(data, reason)
    end
  end

  defp handle_fni_fatal(data, flow_node_instance_id, reason) do
    case Map.get(data.flow_node_instance_states, flow_node_instance_id) do
      nil ->
        data

      entry ->
        flow_node = FlowNodeLookup.find_flow_node(data, entry.flow_node_id)
        error_info = ErrorInfo.build(reason)
        lane_name = LaneResolution.resolve_lane_name(data.process_model, flow_node)

        _persist_result =
          FniLifecycle.transition_to_fatal(
            flow_node_instance_id,
            data.process_instance_id,
            error_info,
            flow_node,
            Map.get(entry, :type_properties, %{}),
            lane_name,
            data.root_process_instance_id,
            multi_instance_id: Map.get(entry, :multi_instance_id),
            iteration_index: Map.get(entry, :iteration_index),
            was_waiting: entry.state == :waiting
          )

        # `fatal_all_fnis/1` skips this entry once it is `:fatal`; a child
        # instance spawned by its handler is cascaded here or never.
        _cascade =
          flow_node &&
            InstanceHandlerDispatch.invoke_optional_callback(flow_node, :handle_fatal, [entry])

        data =
          put_in(
            data.flow_node_instance_states[flow_node_instance_id],
            entry |> Map.put(:error_info, error_info) |> Map.merge(%{state: :fatal, pid: nil})
          )

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
    flow_node = FlowNodeLookup.find_flow_node(data, entry.flow_node_id)

    _persist_result =
      FniLifecycle.transition_to_aborted(
        flow_node_instance_id,
        data.process_instance_id,
        reason,
        flow_node,
        Map.get(entry, :type_properties, %{}),
        LaneResolution.resolve_lane_name(data.process_model, flow_node),
        data.root_process_instance_id,
        multi_instance_id: Map.get(entry, :multi_instance_id),
        iteration_index: Map.get(entry, :iteration_index),
        was_waiting: entry.state == :waiting
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
    flow_node = FlowNodeLookup.find_flow_node(data, entry.flow_node_id)

    InstanceHandlerDispatch.kill_handler_task(entry.pid)

    _persist_result =
      FniLifecycle.transition_to_interrupted(
        flow_node_instance_id,
        data.process_instance_id,
        reason,
        flow_node,
        Map.get(entry, :type_properties, %{}),
        LaneResolution.resolve_lane_name(data.process_model, flow_node),
        data.root_process_instance_id,
        multi_instance_id: Map.get(entry, :multi_instance_id),
        iteration_index: Map.get(entry, :iteration_index),
        was_waiting: entry.state == :waiting
      )

    InstanceHandlerDispatch.release_handler(
      flow_node,
      flow_node_instance_id,
      :handle_aborted,
      entry
    )

    data = unregister_conditional_waiter(data, flow_node_instance_id)

    data =
      put_in(data.flow_node_instance_states[flow_node_instance_id], %{
        entry
        | state: :interrupted,
          pid: nil
      })

    interrupt_iterations_for_shell(data, flow_node_instance_id)
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

  # Cancel End Event: (1) finish the FNI, (2) interrupt all remaining FNIs
  # in the scope, (3) run LIFO compensation for all completed activities,
  # (4) set cancel_reached for the quiesce check.
  # Idempotency: if cancel is already in progress, the FNI is already
  # finished/interrupted — do nothing.
  defp handle_fni_cancel(data, flow_node_instance_id, %FlowNodeResult{} = result) do
    if data.cancel_reached do
      data
    else
      case Map.get(data.flow_node_instance_states, flow_node_instance_id) do
        %{state: state} when state in [:finished, :fatal, :aborted, :interrupted, :error] ->
          data

        nil ->
          data

        _entry ->
          data = do_handle_fni_ok(data, flow_node_instance_id, result)
          data = interrupt_remaining_fnis(data, flow_node_instance_id, :cancelled_by_cancel_end)
          start_cancel_compensation_run(data, flow_node_instance_id)
      end
    end
  end

  defp start_cancel_compensation_run(data, cancel_fni_id) do
    CompensationOrchestrator.start_cancel_run(data, cancel_fni_id, compensation_runtime())
  end

  defp compensation_runtime do
    %{
      emit_fni_started: &emit_fni_started/4,
      emit_fni_state_changed: &emit_fni_state_changed/5,
      emit_compensation_triggered: &emit_compensation_triggered/4,
      dispatch_flow_node_instance: &dispatch_flow_node_instance/4
    }
  end

  defp handle_fni_bpmn_error(data, flow_node_instance_id, %FlowNodeResult{} = result, error_info) do
    case Map.get(data.flow_node_instance_states, flow_node_instance_id) do
      %{state: state} when state in [:finished, :fatal, :aborted, :interrupted, :error] ->
        data

      nil ->
        data

      _entry ->
        data = record_fni_error(data, flow_node_instance_id, result)

        case EspScope.resolve_bpmn_error_catch(data, error_info) do
          {:ok, action} ->
            execute_esp_action(data, action)

          :none ->
            data = error_all_remaining_fnis(data, flow_node_instance_id)
            %{data | bpmn_error_info: error_info}
        end
    end
  end

  defp handle_fni_escalation_end(
         data,
         flow_node_instance_id,
         %FlowNodeResult{} = result,
         escalation_info
       ) do
    case Map.get(data.flow_node_instance_states, flow_node_instance_id) do
      %{state: state} when state in [:finished, :fatal, :aborted, :interrupted, :error] ->
        data

      nil ->
        data

      entry ->
        emit_escalation_raised(
          data,
          flow_node_instance_id,
          entry.flow_node_id,
          escalation_info,
          :end_event
        )

        data = do_handle_fni_ok(data, flow_node_instance_id, result)

        case EspScope.resolve_escalation_catch(data, escalation_info) do
          {:ok, action} ->
            execute_esp_action(data, action)

          :none ->
            data = interrupt_remaining_fnis(data, flow_node_instance_id, :escalation_end_event)
            %{data | escalation_info: escalation_info}
        end
    end
  end

  defp handle_fni_escalation_throw(
         data,
         flow_node_instance_id,
         %FlowNodeResult{} = result,
         escalation_info
       ) do
    case Map.get(data.flow_node_instance_states, flow_node_instance_id) do
      %{state: state} when state in [:finished, :fatal, :aborted, :interrupted, :error] ->
        data

      nil ->
        data

      entry ->
        emit_escalation_raised(
          data,
          flow_node_instance_id,
          entry.flow_node_id,
          escalation_info,
          :intermediate_throw
        )

        data = do_handle_fni_ok(data, flow_node_instance_id, result)

        case EspScope.resolve_escalation_catch(data, escalation_info) do
          {:ok, action} ->
            execute_esp_action(data, action)

          :none ->
            notify_parent(data, {:escalation_passthrough, escalation_info})
            data
        end
    end
  end

  defp handle_fni_escalation_end_propagate(
         data,
         flow_node_instance_id,
         %FlowNodeResult{} = result,
         escalation_info
       ) do
    case Map.get(data.flow_node_instance_states, flow_node_instance_id) do
      %{state: state} when state in [:finished, :fatal, :aborted, :interrupted, :error] ->
        data

      nil ->
        data

      _entry ->
        data = do_handle_fni_ok(data, flow_node_instance_id, result)

        case EspScope.resolve_escalation_catch(data, escalation_info) do
          {:ok, action} ->
            execute_esp_action(data, action)

          :none ->
            data = interrupt_remaining_fnis(data, flow_node_instance_id, :escalation_end_event)
            %{data | escalation_info: escalation_info}
        end
    end
  end

  # -- Compensation orchestration ------------------------------------------------

  defp handle_fni_compensate(data, flow_node_instance_id, %FlowNodeResult{} = result, run_spec) do
    case Map.get(data.flow_node_instance_states, flow_node_instance_id) do
      %{state: state} when state in [:finished, :fatal, :aborted, :interrupted, :error] ->
        data

      nil ->
        data

      entry ->
        event_definition = run_spec.event_definition

        case maybe_fire_compensation_esp(data, event_definition) do
          {:ok, action} ->
            handle_compensation_esp_fire(
              data,
              flow_node_instance_id,
              result,
              run_spec,
              entry,
              action
            )

          :none ->
            resolve_compensation_boundary_targets(
              data,
              flow_node_instance_id,
              result,
              run_spec,
              entry,
              event_definition
            )
        end
    end
  end

  defp maybe_fire_compensation_esp(data, %EventDefinition.Compensation{activity_ref: ref})
       when ref in [nil, ""] do
    EspScope.resolve_compensation_esp_catch(data)
  end

  defp maybe_fire_compensation_esp(_data, _event_definition), do: :none

  defp handle_compensation_esp_fire(
         data,
         flow_node_instance_id,
         result,
         run_spec,
         entry,
         action
       ) do
    output_payload = result.output_payload || entry.token.payload

    type_properties = %{
      compensation_run: true,
      throw_type: Atom.to_string(run_spec.throw_type),
      target_count: 0,
      cursor: 0,
      delegated_to_esp: true
    }

    _persist_result =
      FniLifecycle.transition_to_waiting_by_id(flow_node_instance_id, type_properties)

    data =
      put_in(data.flow_node_instance_states[flow_node_instance_id], %{
        entry
        | state: :waiting,
          pid: nil,
          token: %{entry.token | payload: output_payload},
          type_properties: type_properties
      })

    data =
      put_in(data.compensation_runs[flow_node_instance_id], %{
        queue: [],
        cursor: 0,
        mode: :esp,
        throw_type: run_spec.throw_type,
        outgoing_flow_node_ids: run_spec.outgoing_flow_node_ids,
        token_payload: output_payload,
        handler_count: 0
      })

    emit_fni_state_changed(data, flow_node_instance_id, entry, :active, :waiting)
    emit_compensation_triggered(data, flow_node_instance_id, run_spec, 0)
    fire_esp_action(data, action, flow_node_instance_id)
  end

  defp fire_esp_action(data, {:fire_interrupting, esp_node, payload}, throw_fni_id) do
    data = EspScope.teardown_triggers(data)
    data = interrupt_remaining_fnis(data, throw_fni_id, :compensation_esp_interrupting)

    data = %{
      data
      | compensation_esp_throw_map:
          Map.put(data.compensation_esp_throw_map, esp_node.id, throw_fni_id)
    }

    dispatch_esp_shell(data, esp_node, payload)
  end

  defp fire_esp_action(data, {:fire_non_interrupting, esp_node, payload}, throw_fni_id) do
    data = %{
      data
      | compensation_esp_throw_map:
          Map.put(data.compensation_esp_throw_map, esp_node.id, throw_fni_id)
    }

    dispatch_esp_shell(data, esp_node, payload)
  end

  defp fire_esp_action(data, :noop, _throw_fni_id), do: data

  defp start_compensation_scope_run(data) do
    case EspScope.find_compensation_event_subprocess(data) do
      {:ok, esp_node} -> delegate_compensation_scope_to_event_subprocess(data, esp_node)
      :none -> CompensationOrchestrator.start_scope_run(data, compensation_runtime())
    end
  end

  # The ESP compensates the scope in place of its inner activities. An ESP
  # shell that already finished (the scope compensated itself, or an earlier
  # scope run) leaves nothing to do; a live one belongs to this run now.
  defp delegate_compensation_scope_to_event_subprocess(data, esp_node) do
    anchor_flow_node_instance_id = data.compensation_scope.request.anchor_flow_node_instance_id

    run = %{
      queue: [],
      cursor: 0,
      mode: :esp,
      throw_type: :scope,
      outgoing_flow_node_ids: [],
      token_payload: %{},
      handler_count: 0
    }

    data = put_in(data.compensation_runs[anchor_flow_node_instance_id], run)

    event_subprocess_shell_states =
      for {_flow_node_instance_id, %{flow_node_id: flow_node_id, state: state}} <-
            data.flow_node_instance_states,
          flow_node_id == esp_node.id,
          do: state

    cond do
      :finished in event_subprocess_shell_states ->
        CompensationOrchestrator.finish_run(
          data,
          anchor_flow_node_instance_id,
          run,
          compensation_runtime()
        )

      Enum.any?(event_subprocess_shell_states, &(&1 in [:active, :waiting])) ->
        put_in(data.compensation_esp_throw_map[esp_node.id], anchor_flow_node_instance_id)

      true ->
        fire_esp_action(
          data,
          {:fire_non_interrupting, esp_node, %{}},
          anchor_flow_node_instance_id
        )
    end
  end

  defp resolve_compensation_boundary_targets(
         data,
         flow_node_instance_id,
         result,
         run_spec,
         entry,
         event_definition
       ) do
    targets = CompensationOrchestrator.resolve_targets(data, event_definition)

    if targets == [] do
      handle_compensation_no_targets(
        data,
        flow_node_instance_id,
        result,
        run_spec,
        entry
      )
    else
      start_compensation_run(
        data,
        flow_node_instance_id,
        result,
        run_spec,
        entry,
        targets
      )
    end
  end

  defp handle_compensation_no_targets(data, flow_node_instance_id, result, run_spec, entry) do
    emit_compensation_triggered(data, flow_node_instance_id, run_spec, 0)

    case run_spec.throw_type do
      :throw ->
        _retry_result = persist_compensation_throw_no_targets(data, flow_node_instance_id)
        do_handle_fni_ok(data, flow_node_instance_id, result)

      :end ->
        output_payload = result.output_payload || entry.token.payload

        _retry_result = persist_compensation_throw_no_targets(data, flow_node_instance_id)

        data =
          put_in(data.flow_node_instance_states[flow_node_instance_id], %{
            entry
            | state: :finished,
              pid: nil,
              token: %{entry.token | payload: output_payload}
          })

        %{data | compensation_end_reached: true}
    end
  end

  defp persist_compensation_throw_no_targets(data, flow_node_instance_id) do
    entry = Map.get(data.flow_node_instance_states, flow_node_instance_id)

    output_token =
      case entry do
        %{token: %{payload: payload}} -> JsonSafe.convert(payload) || %{}
        _ -> %{}
      end

    adapter = PersistenceAdapter.adapter()

    persist_result =
      PersistenceRetry.with_retry(
        fn ->
          adapter.update_flow_node_instance(flow_node_instance_id, :update_finished, %{
            state: "finished",
            finished_at: DateTime.utc_now(),
            output_token: output_token
          })
        end,
        "FNI comp throw no-targets #{flow_node_instance_id}"
      )

    if entry do
      flow_node = FlowNodeLookup.find_flow_node(data, entry.flow_node_id)

      TaskInboxEvents.publish_committed_finish(
        persist_result,
        %Event.FlowNodeInstanceFinished{
          flow_node_instance_id: flow_node_instance_id,
          process_instance_id: data.process_instance_id,
          root_process_instance_id: data.root_process_instance_id,
          flow_node_id: entry.flow_node_id,
          flow_node_type: entry.flow_node_type,
          event_type: if(flow_node, do: FlowNodeLookup.extract_event_type(flow_node)),
          lane_name:
            if(flow_node, do: LaneResolution.resolve_lane_name(data.process_model, flow_node)),
          terminal_state: :finished,
          triggerer_flow_node_instance_id: nil,
          type_properties: Map.get(entry, :type_properties) || %{},
          error_info: nil,
          multi_instance_id: Map.get(entry, :multi_instance_id),
          iteration_index: Map.get(entry, :iteration_index),
          occurred_at: DateTime.utc_now()
        },
        flow_node
      )
    end
  end

  defp start_compensation_run(data, flow_node_instance_id, result, run_spec, entry, targets) do
    CompensationOrchestrator.start_run(
      data,
      flow_node_instance_id,
      result,
      run_spec,
      entry,
      targets,
      compensation_runtime()
    )
  end

  defp advance_compensation_run(data, throw_fni_id) do
    CompensationOrchestrator.advance_run(data, throw_fni_id, 1, compensation_runtime())
  end

  # -- End Compensation orchestration -------------------------------------------

  defp record_fni_error(data, flow_node_instance_id, %FlowNodeResult{} = result) do
    entry = Map.fetch!(data.flow_node_instance_states, flow_node_instance_id)
    output_payload = result.output_payload || entry.token.payload

    cache_updates =
      extract_cache_updates(result.metadata)

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
    data = interrupt_all_iterations(data)

    updated_data =
      data
      |> live_entries_outside_iterations()
      |> Enum.filter(fn {id, _entry} -> id != triggering_fni_id end)
      |> Enum.reduce(data, fn {flow_node_instance_id, entry}, accumulator ->
        interrupt_live_flow_node_instance(accumulator, flow_node_instance_id, entry, reason)
      end)

    MessageSubscriptions.unregister_all_for_process_instance(data.process_instance_id)
    SignalSubscriptions.unregister_all_for_process_instance(data.process_instance_id)
    end_compensation_runs_of_ended_throws(updated_data)
  end

  # The PI's subscriptions outside the region must stay. Iterations must be shut
  # down through their shell: killing one mid-write breaks its connection.
  defp interrupt_region_fnis(data, join_flow_node_id, join_fni_id) do
    region = complex_region_node_ids(data, join_flow_node_id)

    region_fni_ids =
      data.flow_node_instance_states
      |> Enum.filter(fn {id, entry} ->
        id != join_fni_id and entry.state in [:active, :waiting] and
          MapSet.member?(region, entry.flow_node_id)
      end)
      |> Enum.map(fn {flow_node_instance_id, _entry} -> flow_node_instance_id end)

    data = Enum.reduce(region_fni_ids, data, &interrupt_iterations_for_shell(&2, &1))

    Enum.reduce(region_fni_ids, data, fn flow_node_instance_id, accumulator ->
      accumulator
      |> interrupt_single_region_fni(flow_node_instance_id)
      |> BoundaryOrchestrator.cancel_boundary_fnis_for_host(flow_node_instance_id)
    end)
    |> end_compensation_runs_of_ended_throws()
  end

  defp interrupt_single_region_fni(data, flow_node_instance_id) do
    case Map.get(data.flow_node_instance_states, flow_node_instance_id) do
      %{state: state} = entry when state in [:active, :waiting] ->
        interrupt_live_flow_node_instance(
          data,
          flow_node_instance_id,
          entry,
          :cancelled_by_complex_join
        )

      _already_ended ->
        data
    end
  end

  # A row that already ended (its handler committed first) keeps its
  # persisted state, and its handler is not released.
  defp interrupt_live_flow_node_instance(accumulator, flow_node_instance_id, entry, reason) do
    InstanceHandlerDispatch.kill_handler_task(entry.pid)

    flow_node = FlowNodeLookup.find_flow_node(accumulator, entry.flow_node_id)

    persist_result =
      FniLifecycle.transition_to_interrupted(
        flow_node_instance_id,
        accumulator.process_instance_id,
        reason,
        flow_node,
        Map.get(entry, :type_properties, %{}),
        LaneResolution.resolve_lane_name(accumulator.process_model, flow_node),
        accumulator.root_process_instance_id,
        multi_instance_id: Map.get(entry, :multi_instance_id),
        iteration_index: Map.get(entry, :iteration_index),
        was_waiting: entry.state == :waiting
      )

    ended_state =
      case persist_result do
        {:ok, :already_terminal} ->
          persisted_flow_node_instance_state(flow_node_instance_id)

        _interrupted ->
          InstanceHandlerDispatch.release_handler(
            flow_node,
            flow_node_instance_id,
            :handle_aborted,
            entry
          )

          :interrupted
      end

    accumulator = unregister_conditional_waiter(accumulator, flow_node_instance_id)

    put_in(accumulator.flow_node_instance_states[flow_node_instance_id], %{
      entry
      | state: ended_state,
        pid: nil
    })
  end

  defp complex_region_node_ids(data, join_flow_node_id) do
    case Map.get(data.process_model.complex_region_analyses || %{}, join_flow_node_id) do
      %ComplexRegionAnalysis{region_node_ids: region} -> region
      _ -> MapSet.new()
    end
  end

  # -------------------------------------------------------------------
  # Internal: Boundary event catch handling
  # -------------------------------------------------------------------

  # An MI iteration runs with the MI node's boundary set, but the boundary is
  # attached to the shell: the shell is the host, and the iteration ends here.
  defp apply_boundary_catch_or_cycle_fire(
         data,
         flow_node_instance_id,
         boundary_node_id,
         payload,
         cancel_activity,
         triggerer_fni_id,
         mode
       ) do
    case iteration_shell_fni_id(data, flow_node_instance_id) do
      shell_fni_id when is_binary(shell_fni_id) ->
        data =
          if cancel_activity do
            entry = Map.fetch!(data.flow_node_instance_states, flow_node_instance_id)

            finish_interrupted_iteration(
              data,
              flow_node_instance_id,
              entry,
              :interrupted_by_boundary
            )
          else
            data
          end

        apply_host_boundary_if_live(
          data,
          shell_fni_id,
          boundary_node_id,
          payload,
          cancel_activity,
          triggerer_fni_id,
          mode
        )

      nil ->
        host_fni_id = BoundaryOrchestrator.resolve_host_fni_id(data, flow_node_instance_id)

        if host_fni_id == flow_node_instance_id or flow_node_instance_live?(data, host_fni_id) do
          apply_host_boundary(
            data,
            flow_node_instance_id,
            boundary_node_id,
            payload,
            cancel_activity,
            triggerer_fni_id,
            mode
          )
        else
          BoundaryOrchestrator.cancel_boundary_fnis_for_host(data, host_fni_id)
        end
    end
  end

  # A resumed iteration is not in `mi_shell_tasks` until its shell reattaches.
  defp iteration_shell_fni_id(data, flow_node_instance_id) do
    case Map.get(data.mi_shell_tasks, flow_node_instance_id) do
      {shell_fni_id, _shell_task_pid} ->
        shell_fni_id

      nil ->
        data.flow_node_instance_states
        |> Map.get(flow_node_instance_id, %{})
        |> Map.get(:multi_instance_id)
    end
  end

  # After a resume a boundary FNI can outlive its host when the host-completed
  # interrupt write was lost; it must not fire for a host that already ended.
  defp flow_node_instance_live?(data, flow_node_instance_id) do
    match?(
      %{state: state} when state in [:active, :waiting],
      Map.get(data.flow_node_instance_states, flow_node_instance_id)
    )
  end

  defp apply_host_boundary_if_live(
         data,
         shell_fni_id,
         boundary_node_id,
         payload,
         cancel_activity,
         triggerer_fni_id,
         mode
       ) do
    case Map.get(data.flow_node_instance_states, shell_fni_id) do
      %{state: state} when state in [:active, :waiting] ->
        apply_host_boundary(
          data,
          shell_fni_id,
          boundary_node_id,
          payload,
          cancel_activity,
          triggerer_fni_id,
          mode
        )

      _ended ->
        data
    end
  end

  defp apply_host_boundary(
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
    boundary_fni_id = UuidV7.generate()
    lane_name = LaneResolution.resolve_lane_name(data.process_model, boundary_node)

    case persist_fni_create(
           data,
           boundary_fni_id,
           boundary_node,
           token,
           lane_name,
           [host_fni_id],
           %{"host_flow_node_instance_id" => host_fni_id}
         ) do
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
      InstanceHandlerDispatch.build_handler_context(
        data,
        boundary_fni_id,
        boundary_node,
        process_instance_pid
      )
      |> Map.put(:host_flow_node_instance_id, host_fni_id)

    case Task.Supervisor.start_child(data.task_supervisor, fn ->
           result = handler_module.handle_enter(boundary_node, token, handler_context)

           InstanceHandlerDispatch.dispatch_handler_result(
             process_instance_pid,
             boundary_fni_id,
             result
           )
         end) do
      {:ok, task_pid} ->
        Process.monitor(task_pid)

        entry = %{
          pid: task_pid,
          flow_node_id: boundary_node.id,
          flow_node_type: boundary_node.type,
          event_type: FlowNodeLookup.extract_event_type(boundary_node),
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

  defp reply_inbox_completion(
         data,
         from,
         flow_node_instance_id,
         expected_type,
         mismatch_error,
         continue
       ) do
    case Map.get(data.flow_node_instance_states, flow_node_instance_id) do
      nil ->
        {:keep_state, data, [{:reply, from, {:error, :fni_not_found}}]}

      _entry ->
        if flow_node_type(data, flow_node_instance_id) == expected_type do
          continue.()
        else
          {:keep_state, data, [{:reply, from, {:error, mismatch_error}}]}
        end
    end
  end

  defp flow_node_type(data, flow_node_instance_id) do
    case Map.get(data.flow_node_instance_states, flow_node_instance_id) do
      %{flow_node_id: flow_node_id} ->
        case FlowNodeLookup.find_flow_node(data, flow_node_id) do
          %{type: type} -> type
          _other -> nil
        end

      _missing ->
        nil
    end
  end

  defp complete_waiting_inbox_task(
         data,
         from,
         flow_node_instance_id,
         payload,
         user_task_action_id \\ nil
       ) do
    case Map.get(data.flow_node_instance_states, flow_node_instance_id) do
      %{state: :waiting} = entry ->
        complete_waiting_fni(
          data,
          from,
          flow_node_instance_id,
          entry,
          payload,
          user_task_action_id
        )

      %{state: state} ->
        {:keep_state, data, [{:reply, from, {:error, normalize_terminal_state_error(state)}}]}

      nil ->
        {:keep_state, data, [{:reply, from, {:error, :fni_not_found}}]}
    end
  end

  defp complete_waiting_fni(
         data,
         from,
         flow_node_instance_id,
         entry,
         payload,
         user_task_action_id \\ nil
       ) do
    flow_node = FlowNodeLookup.find_flow_node(data, entry.flow_node_id)

    handler_lookup =
      cond do
        multi_instance_shell?(flow_node, entry) -> {:error, :fni_is_multi_instance_shell}
        Map.get(entry, :multi_instance_id) -> HandlerDispatch.inner_handler_for(flow_node)
        true -> HandlerDispatch.handler_for(flow_node)
      end

    case handler_lookup do
      {:ok, handler_module} ->
        context =
          %{
            InstanceHandlerDispatch.build_handler_context(
              data,
              flow_node_instance_id,
              flow_node,
              self()
            )
            | user_task_action_id: user_task_action_id
          }

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

      {:error, reason} when reason in [:unsupported_element, :fni_is_multi_instance_shell] ->
        {:keep_state, data, [{:reply, from, {:error, reason}}]}
    end
  end

  defp cancel_waiting_fni(data, flow_node_instance_id, entry, reason) do
    flow_node = FlowNodeLookup.find_flow_node(data, entry.flow_node_id)

    case HandlerDispatch.handler_for(flow_node) do
      {:ok, handler_module} ->
        if function_exported?(handler_module, :handle_cancel, 4) do
          context =
            InstanceHandlerDispatch.build_handler_context(
              data,
              flow_node_instance_id,
              flow_node,
              self()
            )

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
        case Map.get(data.mi_shell_tasks, flow_node_instance_id) do
          nil ->
            data = handle_fni_ok(data, flow_node_instance_id, result)
            data = maybe_evaluate_adhoc_completion_condition(data)
            data = maybe_cancel_remaining_for_adhoc(data)
            data = maybe_auto_chain_sequential_adhoc(data)
            maybe_finish_or_continue_with_reply(data, from)

          {_shell_fni_id, shell_task_pid} ->
            data = handle_mi_iteration_ok(data, flow_node_instance_id, result, shell_task_pid)
            {:keep_state, data, [{:reply, from, :ok}]}
        end

      {:error, {:contract_violation, _violations} = reason} ->
        {:keep_state, data, [{:reply, from, {:error, reason}}]}

      {:error, :payload_too_large, details} ->
        {:keep_state, data, [{:reply, from, {:error, :payload_too_large, details}}]}

      {:error, reason} ->
        apply_error_boundary_or_fatal(
          data,
          from,
          flow_node_instance_id,
          reason,
          {:error, reason}
        )
    end
  end

  # -------------------------------------------------------------------
  # Internal: PI termination
  # -------------------------------------------------------------------

  defp apply_error_boundary_or_fatal(
         data,
         from,
         flow_node_instance_id,
         reason,
         uncaught_reply
       ) do
    entry = Map.fetch!(data.flow_node_instance_states, flow_node_instance_id)
    flow_node = FlowNodeLookup.find_flow_node(data, entry.flow_node_id)

    context =
      InstanceHandlerDispatch.build_handler_context(
        data,
        flow_node_instance_id,
        flow_node,
        self()
      )

    case BoundaryAwareHandler.attempt_error_boundary_catch(flow_node, context, reason) do
      {:boundary, boundary_node_id, payload, cancel_activity} ->
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

        maybe_finish_or_continue_with_reply(data, from)

      {:error, _} ->
        fatal_uncaught_async_or_complete_error(
          data,
          from,
          flow_node_instance_id,
          reason,
          uncaught_reply
        )
    end
  end

  defp fatal_uncaught_async_or_complete_error(
         data,
         from,
         flow_node_instance_id,
         reason,
         uncaught_reply
       ) do
    case Map.get(data.mi_shell_tasks, flow_node_instance_id) do
      nil ->
        resolve_esp_or_fatal_completion_error(
          data,
          from,
          flow_node_instance_id,
          reason,
          uncaught_reply
        )

      {_shell_fni_id, shell_task_pid} ->
        data = handle_mi_iteration_error(data, flow_node_instance_id, reason, shell_task_pid)
        {:keep_state, data, [{:reply, from, {:error, reason}}]}
    end
  end

  defp resolve_esp_or_fatal_completion_error(
         data,
         from,
         flow_node_instance_id,
         reason,
         uncaught_reply
       ) do
    case EspScope.resolve_error_catch(data, flow_node_instance_id, reason) do
      {:caught, data, action} ->
        data
        |> execute_esp_action(action)
        |> maybe_finish_or_continue_with_reply(from)

      :not_caught ->
        data = handle_fni_fatal(data, flow_node_instance_id, reason)
        reply_uncaught_fatal(data, from, reason, uncaught_reply)
    end
  end

  defp reply_uncaught_fatal(data, from, reason, :ok) do
    transition_to_fatal_with_reply(data, reason, from)
  end

  defp reply_uncaught_fatal(data, from, reason, {:error, _} = error_reply) do
    do_transition_to_fatal(data, reason, [{:reply, from, error_reply}])
  end

  defp maybe_finish_or_continue(data) do
    data = evaluate_parked_inclusive_joins(data)
    data = evaluate_parked_complex_joins(data)
    data = evaluate_conditional_waiters(data)
    data = execute_esp_conditionals(data)

    has_fatal =
      Enum.any?(data.flow_node_instance_states, fn {_id, entry} -> entry.state == :fatal end)

    if has_fatal do
      transition_to_fatal(data, :fni_fatal)
    else
      case maybe_finish(data) do
        {:stop, data} ->
          {:stop, :normal, data}

        {:continue, data} ->
          {data, release_actions} = release_early_async_completions(data)
          {:keep_state, data, release_actions}
      end
    end
  end

  defp maybe_finish_or_continue_with_reply(data, from) do
    data = evaluate_parked_inclusive_joins(data)
    data = evaluate_parked_complex_joins(data)
    data = evaluate_conditional_waiters(data)
    data = execute_esp_conditionals(data)

    has_fatal =
      Enum.any?(data.flow_node_instance_states, fn {_id, entry} -> entry.state == :fatal end)

    if has_fatal do
      do_transition_to_fatal(data, :fni_fatal, [{:reply, from, :ok}])
    else
      case maybe_finish(data) do
        {:stop, data} ->
          {:stop_and_reply, :normal, [{:reply, from, :ok}], data}

        {:continue, data} ->
          {data, release_actions} = release_early_async_completions(data)
          {:keep_state, data, [{:reply, from, :ok} | release_actions]}
      end
    end
  end

  defp evaluate_parked_inclusive_joins(data) do
    data
    |> parked_joins(:inclusive_gateway)
    |> Enum.reduce(data, fn {flow_node_id, routing}, accumulator ->
      maybe_signal_inclusive_join_fire(accumulator, flow_node_id, routing)
    end)
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
        %{pid: pid} when is_pid(pid) -> send(pid, {:fire})
        _ -> :ok
      end

      %{data | join_routing: Map.delete(data.join_routing, flow_node_id)}
    else
      data
    end
  end

  defp evaluate_parked_complex_joins(data) do
    data
    |> parked_joins(:complex_gateway)
    |> Enum.reject(fn {_flow_node_id, routing} -> Map.get(routing, :fired, false) end)
    |> Enum.reduce(data, fn {flow_node_id, routing}, accumulator ->
      evaluate_single_complex_join(accumulator, flow_node_id, routing)
    end)
  end

  # While an Event-Based Gateway winner's successors are deferred, its token
  # is in no FNI, so dead-path evaluation would see its branch as dead.
  defp parked_joins(data, gateway_type) do
    if Map.get(data, :event_based_gateway_deferred_dispatch) == nil do
      Enum.filter(data.join_routing, fn {flow_node_id, routing} ->
        routing.gateway_type == gateway_type and live_join_routing(data, flow_node_id) != nil
      end)
    else
      []
    end
  end

  defp evaluate_single_complex_join(data, flow_node_id, routing) do
    flow_node = FlowNodeLookup.find_flow_node(data, flow_node_id)

    case ComplexJoinEvaluator.evaluate(flow_node, routing, data) do
      :fire ->
        data
        |> signal_complex_join(flow_node_id, routing, {:fire})
        |> interrupt_region_fnis(flow_node_id, routing.fni_id)

      {:error, error_info} ->
        signal_complex_join(data, flow_node_id, routing, {:complex_join_error, error_info})

      :wait ->
        data
    end
  end

  defp signal_complex_join(data, flow_node_id, routing, message) do
    case Map.get(data.flow_node_instance_states, routing.fni_id) do
      %{pid: pid} when is_pid(pid) ->
        send(pid, message)

      _ ->
        :ok
    end

    update_in(data.join_routing[flow_node_id], fn
      nil -> nil
      entry -> Map.put(entry, :fired, true)
    end)
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
    handler_context =
      InstanceHandlerDispatch.build_handler_context(data, fni_id, waiter.flow_node, self())

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
    flow_node = FlowNodeLookup.find_flow_node(data, entry.flow_node_id)
    {:ok, handler_module} = HandlerDispatch.handler_for(flow_node)
    token_payload = entry.token.payload

    is_boundary = flow_node.type == :boundary_event

    opts =
      if is_boundary do
        %{
          position: :boundary,
          cancel_activity: Map.get(flow_node.type_data, :cancel_activity, true)
        }
      else
        %{position: :intermediate_catch}
      end

    data =
      register_conditional_waiter(data, fni_id, flow_node, handler_module, token_payload, opts)

    waiter = Map.get(data.conditional_waiters, fni_id)
    evaluate_single_conditional_waiter(data, fni_id, waiter)
  end

  defp register_conditional_waiter(data, fni_id, flow_node, handler_module, token_payload, opts) do
    waiter = %{
      flow_node_id: flow_node.id,
      flow_node: flow_node,
      handler_module: handler_module,
      position: opts[:position] || :intermediate_catch,
      cancel_activity: opts[:cancel_activity],
      token_payload: token_payload,
      fired: false
    }

    %{data | conditional_waiters: Map.put(data.conditional_waiters, fni_id, waiter)}
  end

  defp unregister_conditional_waiter(data, fni_id) do
    %{data | conditional_waiters: Map.delete(data.conditional_waiters, fni_id)}
  end

  defp extract_cache_updates(metadata) do
    case metadata[:lifecycle] do
      nil -> %{}
      lifecycle -> Map.get(lifecycle, :data_object_cache_updates, %{})
    end
  end

  defp maybe_push_compensation_registry(data, flow_node_instance_id) do
    order = length(data.compensation_registry)
    entry = Map.fetch!(data.flow_node_instance_states, flow_node_instance_id)

    case CompensationOrchestrator.registry_entry(data, flow_node_instance_id, entry, order) do
      nil ->
        data

      registry_entry ->
        %{data | compensation_registry: [registry_entry | data.compensation_registry]}
    end
  end

  # A compensation scope instance writes no process instance state: it stops
  # once its run replied and nothing it started is still running. An uncaught
  # Error or Escalation End ended every path of the run, so it can never reply.
  defp maybe_finish(%{compensation_scope: %{request: %{} = request}} = data) do
    quiet =
      data.compensation_scope.children == %{} and
        not Enum.any?(data.flow_node_instance_states, fn {_id, entry} ->
          entry.state in [:active, :waiting]
        end)

    uncaught_end = uncaught_compensation_scope_end(data)

    cond do
      not quiet ->
        {:continue, data}

      data.compensation_runs == %{} ->
        stop_compensation_scope_instance(data)

      uncaught_end != nil ->
        send(
          request.reply_to,
          {:compensation_scope_failed, data.process_instance_id, request.scope_target_id,
           ErrorInfo.build(uncaught_end)}
        )

        stop_compensation_scope_instance(data)

      true ->
        {:continue, data}
    end
  end

  # A cancel run waiting on a compensation scope instance has no live flow
  # node instance, yet the scope has not ended.
  defp maybe_finish(data) do
    cancel_running =
      Enum.any?(data.compensation_runs, fn {_id, run} -> run.throw_type == :cancel end)

    if data.compensation_scope.children == %{} and not cancel_running and
         data.mode.should_complete?(data) do
      finish_quiesced_pi(data)
    else
      {:continue, data}
    end
  end

  defp stop_compensation_scope_instance(data) do
    MessageSubscriptions.unregister_all_for_process_instance(data.process_instance_id)
    SignalSubscriptions.unregister_all_for_process_instance(data.process_instance_id)
    {:stop, data}
  end

  defp uncaught_compensation_scope_end(%{bpmn_error_info: %{} = error_info}),
    do: {:compensation_handler_uncaught_error, error_info}

  defp uncaught_compensation_scope_end(%{escalation_info: %{} = escalation_info}),
    do: {:compensation_handler_uncaught_escalation, escalation_info}

  defp uncaught_compensation_scope_end(_data), do: nil

  defp finish_quiesced_pi(data) do
    data = abort_compensation_scope_children(data)
    MessageSubscriptions.unregister_all_for_process_instance(data.process_instance_id)
    SignalSubscriptions.unregister_all_for_process_instance(data.process_instance_id)

    cond do
      data.escalation_info != nil ->
        _persist_result = persist_pi_escalated(data, data.escalation_info)
        emit_pi_state_changed(data, :running, :escalated)

        if data.notify_pid do
          notify_parent(data, {:escalation, data.escalation_info})
        else
          emit_escalation_uncaught(data, data.escalation_info)
        end

      data.bpmn_error_info != nil ->
        _persist_result = persist_pi_error(data, data.bpmn_error_info)
        emit_pi_state_changed(data, :running, :error)
        notify_parent(data, {:bpmn_error, data.bpmn_error_info})

      data.cancel_reached ->
        _persist_result = persist_pi_cancelled(data)
        emit_pi_state_changed(data, :running, :cancelled)
        emit_transaction_cancelled(data)
        notify_parent(data, :cancelled)

      data.compensation_end_reached ->
        _persist_result = persist_pi_compensated(data)
        emit_pi_state_changed(data, :running, :compensated)
        notify_parent(data, :compensated)

      true ->
        _persist_result = persist_pi_finished(data)
        emit_pi_state_changed(data, :running, :finished)
        notify_parent(data, :finished)
    end

    {:stop, data}
  end

  defp transition_to_fatal(data, reason) do
    do_transition_to_fatal(data, reason, [])
  end

  defp do_transition_to_fatal(
         %{compensation_scope: %{request: %{} = request}} = data,
         reason,
         extra_actions
       ) do
    data = abort_compensation_scope_children(data)
    fatal_all_fnis(data)

    send(
      request.reply_to,
      {:compensation_scope_failed, data.process_instance_id, request.scope_target_id,
       compensation_scope_error_info(data, reason)}
    )

    case extra_actions do
      [] -> {:stop, :normal, data}
      actions -> {:stop_and_reply, :normal, actions, data}
    end
  end

  defp do_transition_to_fatal(data, reason, extra_actions) do
    data = abort_compensation_scope_children(data)
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
    data = interrupt_all_iterations(data)

    data.flow_node_instance_states
    |> Enum.filter(fn {_id, entry} -> entry.state in [:active, :waiting] end)
    |> Enum.each(fn {flow_node_instance_id, entry} ->
      InstanceHandlerDispatch.kill_handler_task(entry.pid)

      flow_node = FlowNodeLookup.find_flow_node(data, entry.flow_node_id)

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
          LaneResolution.resolve_lane_name(data.process_model, flow_node),
          data.root_process_instance_id,
          multi_instance_id: Map.get(entry, :multi_instance_id),
          iteration_index: Map.get(entry, :iteration_index),
          was_waiting: entry.state == :waiting
        )

      InstanceHandlerDispatch.invoke_optional_callback(flow_node, :handle_fatal, [entry])
    end)

    MessageSubscriptions.unregister_all_for_process_instance(data.process_instance_id)
    SignalSubscriptions.unregister_all_for_process_instance(data.process_instance_id)
  end

  # A compensation scope instance writes no process instance state; its
  # requester aborts the tree.
  defp abort_process_instance(%{compensation_scope: %{request: %{} = request}} = data, reason) do
    data = abort_compensation_scope_children(data)
    abort_all_fnis(data)

    send(
      request.reply_to,
      {:compensation_scope_aborted, data.process_instance_id, request.scope_target_id, reason}
    )
  end

  defp abort_process_instance(data, reason) do
    data = abort_compensation_scope_children(data)
    _persist_result = persist_pi_aborted(data, reason)
    emit_pi_state_changed(data, :running, :aborted)
    notify_parent(data, :aborted)
    abort_all_fnis(data)
  end

  # Aborts the scope children of `run_keys` (all when nil) and stops tracking
  # them, so their `compensation_scope_aborted` reply is ignored.
  defp abort_compensation_scope_children(data, run_keys \\ nil) do
    {aborted_children, remaining_children} =
      Map.split_with(data.compensation_scope.children, fn {_pid, scope_child} ->
        run_keys == nil or scope_child.run_key in run_keys
      end)

    # A busy pid belongs to another requester; this one only waited for it.
    Enum.each(aborted_children, fn {pid, scope_child} ->
      Process.demonitor(scope_child.monitor_ref, [:flush])

      if not scope_child.busy do
        try do
          abort(pid, "process_aborted", nil)
        catch
          :exit, _already_stopped -> :ok
        end
      end
    end)

    put_in(data.compensation_scope.children, remaining_children)
  end

  # A run ends with its throw FNI. A scope run's key belongs to another
  # instance and a Cancel End's run outlives its finished FNI, so neither
  # matches here.
  defp end_compensation_runs_of_ended_throws(data) do
    ended_run_keys =
      for {run_key, _run} <- data.compensation_runs,
          match?(
            %{state: state} when state in [:interrupted, :error],
            Map.get(data.flow_node_instance_states, run_key)
          ),
          do: run_key

    %{data | compensation_runs: Map.drop(data.compensation_runs, ended_run_keys)}
    |> abort_compensation_scope_children(ended_run_keys)
  end

  defp compensation_scope_error_info(data, :fni_fatal) do
    case Enum.find(data.flow_node_instance_states, fn {_id, entry} -> entry.state == :fatal end) do
      {_id, entry} -> ErrorInfo.build({:compensation_handler_fatal, entry.flow_node_id})
      nil -> ErrorInfo.build(:fni_fatal)
    end
  end

  defp compensation_scope_error_info(_data, reason), do: ErrorInfo.build(reason)

  defp abort_all_fnis(data) do
    data = interrupt_all_iterations(data)

    data.flow_node_instance_states
    |> Enum.filter(fn {_id, entry} -> entry.state in [:active, :waiting] end)
    |> Enum.each(fn {flow_node_instance_id, entry} ->
      InstanceHandlerDispatch.kill_handler_task(entry.pid)

      flow_node = FlowNodeLookup.find_flow_node(data, entry.flow_node_id)

      _persist_result =
        FniLifecycle.transition_to_aborted(
          flow_node_instance_id,
          data.process_instance_id,
          "process_aborted",
          flow_node,
          Map.get(entry, :type_properties, %{}),
          LaneResolution.resolve_lane_name(data.process_model, flow_node),
          data.root_process_instance_id,
          multi_instance_id: Map.get(entry, :multi_instance_id),
          iteration_index: Map.get(entry, :iteration_index),
          was_waiting: entry.state == :waiting
        )

      InstanceHandlerDispatch.invoke_optional_callback(flow_node, :handle_aborted, [entry])
    end)

    MessageSubscriptions.unregister_all_for_process_instance(data.process_instance_id)
    SignalSubscriptions.unregister_all_for_process_instance(data.process_instance_id)
  end

  defp error_all_remaining_fnis(data, triggering_fni_id) do
    cascade_error_info = %{
      "error_code" => "process_error",
      "message" => "Cascade: process instance received a BPMN error"
    }

    data = interrupt_all_iterations(data)

    updated_data =
      data
      |> live_entries_outside_iterations()
      |> Enum.filter(fn {id, _entry} -> id != triggering_fni_id end)
      |> Enum.reduce(data, fn {flow_node_instance_id, entry}, accumulator ->
        InstanceHandlerDispatch.kill_handler_task(entry.pid)

        flow_node = FlowNodeLookup.find_flow_node(accumulator, entry.flow_node_id)

        InstanceHandlerDispatch.release_handler(
          flow_node,
          flow_node_instance_id,
          :handle_aborted,
          entry
        )

        _persist_result =
          FniLifecycle.transition_to_error(
            flow_node_instance_id,
            accumulator.process_instance_id,
            cascade_error_info,
            flow_node,
            Map.get(entry, :type_properties, %{}),
            LaneResolution.resolve_lane_name(accumulator.process_model, flow_node),
            accumulator.root_process_instance_id,
            multi_instance_id: Map.get(entry, :multi_instance_id),
            iteration_index: Map.get(entry, :iteration_index),
            was_waiting: entry.state == :waiting
          )

        accumulator = unregister_conditional_waiter(accumulator, flow_node_instance_id)

        put_in(accumulator.flow_node_instance_states[flow_node_instance_id], %{
          entry
          | state: :error,
            pid: nil
        })
      end)

    end_compensation_runs_of_ended_throws(updated_data)
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
          error_info: process_instance_fatal_error_info(data, fatal_reason)
        })
      end,
      "PI fatal #{data.process_instance_id}"
    )
  end

  # A fatal flow node instance makes the process instance fatal: the process
  # error names that cause and the failing flow node and flow node instance.
  defp process_instance_fatal_error_info(data, :fni_fatal) do
    case find_fatal_entry(data, fn _error_info -> true end) do
      {flow_node_instance_id, entry} ->
        process_fatal_error_info(entry.error_info, entry.flow_node_id, flow_node_instance_id)

      nil ->
        process_fatal_error_info(ErrorInfo.build(:fni_fatal), nil, nil)
    end
  end

  defp process_instance_fatal_error_info(data, {:fni_crash, flow_node_instance_id, reason}) do
    case Map.get(data.flow_node_instance_states, flow_node_instance_id) do
      %{error_info: error_info, flow_node_id: flow_node_id} ->
        process_fatal_error_info(error_info, flow_node_id, flow_node_instance_id)

      _entry ->
        process_fatal_error_info(ErrorInfo.build({:crash, reason}), nil, flow_node_instance_id)
    end
  end

  # An uncaught handler error reaches here with its own reason; the flow node
  # instance that failed with it carries the same error info.
  defp process_instance_fatal_error_info(data, fatal_reason) do
    case process_instance_fatal_error_info(fatal_reason) do
      %{"error_code" => "process_fatal", "detail" => %{"cause" => cause}} = error_info ->
        case find_fatal_entry(data, &(&1 == cause)) do
          {flow_node_instance_id, entry} ->
            process_fatal_error_info(cause, entry.flow_node_id, flow_node_instance_id)

          nil ->
            error_info
        end

      error_info ->
        error_info
    end
  end

  defp find_fatal_entry(data, error_info_matches?) do
    Enum.find(data.flow_node_instance_states, fn {_id, entry} ->
      entry.state == :fatal and Map.has_key?(entry, :error_info) and
        error_info_matches?.(entry.error_info)
    end)
  end

  defp process_fatal_error_info(cause, flow_node_id, flow_node_instance_id) do
    %{
      "error_code" => "process_fatal",
      "message" => "Process instance went fatal: #{cause["message"]}",
      "detail" => %{
        "cause" => cause,
        "flow_node_id" => flow_node_id,
        "flow_node_instance_id" => flow_node_instance_id
      }
    }
  end

  defp process_instance_fatal_error_info({:event_subprocess_correlation_failed, _, _} = reason),
    do: ErrorInfo.build(reason)

  defp process_instance_fatal_error_info(
         {:event_subprocess_timer_resolution_failed, _, _} = reason
       ),
       do: ErrorInfo.build(reason)

  defp process_instance_fatal_error_info({fatal_error, _detail} = reason)
       when fatal_error in [
              :compensation_scope_failed,
              :compensation_scope_start_failed,
              :compensation_handler_dispatch_failed,
              :process_instance_crashed
            ],
       do: ErrorInfo.build(reason)

  defp process_instance_fatal_error_info(
         {:lost_successor_repair_failed, flow_node_id, _failure} = reason
       ),
       do: %{ErrorInfo.build(reason) | "detail" => flow_node_id}

  defp process_instance_fatal_error_info(fatal_reason),
    do: process_fatal_error_info(ErrorInfo.build(fatal_reason), nil, nil)

  defp persist_pi_resume_failed(data, reason) do
    adapter = PersistenceAdapter.adapter()

    PersistenceRetry.with_retry(
      fn ->
        adapter.update_process_instance(data.process_instance_id, %{
          state: @pi_state_fatal,
          finished_at: DateTime.utc_now(),
          error_info: resume_failed_error_info(data, reason)
        })
      end,
      "PI resume failed #{data.process_instance_id}"
    )
  end

  defp resume_failed_error_info(data, reason) do
    error_info = %{
      "error_code" => "resume_failed",
      "message" =>
        "Process instance '#{data.process_instance_id}' could not be resumed after an " <>
          "engine restart because #{resume_failure_cause(reason)}."
    }

    if is_atom(reason),
      do: Map.put(error_info, "detail", Atom.to_string(reason)),
      else: error_info
  end

  defp resume_failure_cause(:not_found), do: "its process version no longer exists"

  defp resume_failure_cause({:resume_crashed, _formatted_exception}),
    do: "an internal error occurred while its state was rebuilt (see the engine log)"

  defp resume_failure_cause(:no_executable_process),
    do: "its process version contains no executable process"

  defp resume_failure_cause(:start_event_never_recorded),
    do:
      "its Start Event was never recorded: the engine stopped after it created the process " <>
        "instance and before it persisted the first flow node instance, so there is no state " <>
        "to continue from"

  defp resume_failure_cause(_reason),
    do: "its process model or its data objects could not be loaded"

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
                 "detail" => JsonSafe.convert(abort_reason)
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
            "detail" => JsonSafe.convert(error_info)
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
            "detail" => JsonSafe.convert(escalation_info)
          }
        })
      end,
      "PI escalated #{data.process_instance_id}"
    )
  end

  defp persist_pi_compensated(data) do
    adapter = PersistenceAdapter.adapter()

    PersistenceRetry.with_retry(
      fn ->
        adapter.update_process_instance(data.process_instance_id, %{
          state: @pi_state_compensated,
          finished_at: DateTime.utc_now()
        })
      end,
      "PI compensated #{data.process_instance_id}"
    )
  end

  defp persist_pi_cancelled(data) do
    adapter = PersistenceAdapter.adapter()

    PersistenceRetry.with_retry(
      fn ->
        adapter.update_process_instance(data.process_instance_id, %{
          state: @pi_state_cancelled,
          finished_at: DateTime.utc_now()
        })
      end,
      "PI cancelled #{data.process_instance_id}"
    )
  end

  defp emit_transaction_cancelled(data) do
    transaction_node_id = extract_transaction_node_id(data)

    compensation_handler_count =
      Enum.find_value(data.flow_node_instance_states, 0, fn {_id, entry} ->
        Map.get(entry.type_properties || %{}, :compensation_handler_count)
      end)

    EngineEventBus.publish(%Event.TransactionCancelled{
      process_instance_id: data.process_instance_id,
      root_process_instance_id: data.root_process_instance_id,
      transaction_node_id: transaction_node_id,
      compensation_handler_count: compensation_handler_count,
      lane_name: resolve_lane_for_flow_node_id(data, transaction_node_id),
      occurred_at: DateTime.utc_now()
    })

    :telemetry.execute(
      [:bfw_engine, :transaction, :cancelled],
      %{system_time: System.system_time()},
      %{
        process_instance_id: data.process_instance_id,
        transaction_node_id: transaction_node_id,
        compensation_handler_count: compensation_handler_count
      }
    )
  end

  defp extract_transaction_node_id(data) do
    model_id = (data.process_model && data.process_model.id) || ""

    case String.split(model_id, "__subprocess__") do
      [_parent, node_id] -> node_id
      _ -> nil
    end
  end

  defp persist_fni_create(
         data,
         flow_node_instance_id,
         flow_node,
         token,
         lane_name,
         previous_flow_node_instance_ids,
         type_properties \\ %{}
       ) do
    adapter = PersistenceAdapter.adapter()

    attributes = %{
      type_properties: type_properties,
      id: flow_node_instance_id,
      process_instance_id: data.process_instance_id,
      flow_node_id: flow_node.id,
      flow_node_type: Atom.to_string(flow_node.type),
      event_type: FlowNodeLookup.extract_event_type(flow_node),
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

  # -------------------------------------------------------------------
  # Multi-Instance iteration helpers
  # -------------------------------------------------------------------

  defp dispatch_mi_iteration_fni(
         data,
         from,
         shell_fni_id,
         index,
         _item,
         token,
         loop_overlay,
         flow_node
       ) do
    case Map.get(data.flow_node_instance_states, shell_fni_id) do
      %{state: state, pid: shell_task_pid} when state in [:active, :waiting] ->
        create_mi_iteration_fni(
          data,
          from,
          {shell_fni_id, shell_task_pid},
          index,
          token,
          loop_overlay,
          flow_node
        )

      _ended_or_unknown ->
        :gen_statem.reply(from, {:error, :shell_not_active})
        data
    end
  end

  defp create_mi_iteration_fni(
         data,
         from,
         {shell_fni_id, shell_task_pid},
         index,
         token,
         loop_overlay,
         flow_node
       ) do
    iteration_fni_id = UuidV7.generate()
    lane_name = LaneResolution.resolve_lane_name(data.process_model, flow_node)

    adapter = PersistenceAdapter.adapter()

    attributes = %{
      id: iteration_fni_id,
      process_instance_id: data.process_instance_id,
      flow_node_id: flow_node.id,
      flow_node_type: Atom.to_string(flow_node.type),
      event_type: FlowNodeLookup.extract_event_type(flow_node),
      lane_name: lane_name,
      state: "active",
      started_at: DateTime.utc_now(),
      input_token: token.payload,
      previous_flow_node_instance_ids: [shell_fni_id],
      multi_instance_id: shell_fni_id,
      iteration_index: index,
      type_properties: %{"loop_overlay" => Map.delete(loop_overlay, "results")}
    }

    iteration_context = %{
      iteration_fni_id: iteration_fni_id,
      shell_fni_id: shell_fni_id,
      shell_task_pid: shell_task_pid,
      index: index,
      token: token,
      loop_overlay: loop_overlay,
      flow_node: flow_node,
      lane_name: lane_name
    }

    case PersistenceRetry.with_retry(
           fn -> adapter.create_flow_node_instance(attributes) end,
           "MI iteration FNI create #{iteration_fni_id}"
         ) do
      {:ok, _} ->
        emit_fni_started(data, iteration_fni_id, flow_node, [shell_fni_id],
          multi_instance_id: shell_fni_id,
          iteration_index: index
        )

        dispatch_mi_iteration_handler(data, from, iteration_context)

      {:error, _reason} ->
        :gen_statem.reply(from, {:error, :persistence_failed})
        data
    end
  end

  defp dispatch_mi_iteration_handler(data, from, context) do
    case HandlerDispatch.inner_handler_for(context.flow_node) do
      {:ok, handler_module} ->
        start_mi_iteration_task(data, from, context, handler_module)

      {:error, _} ->
        fatal_mi_iteration_fni(
          data,
          from,
          context,
          "unsupported_element",
          "Unsupported inner element type for MI iteration: #{context.flow_node.type}",
          :unsupported_element
        )
    end
  end

  defp start_mi_iteration_task(data, from, context, handler_module) do
    process_instance_pid = self()

    handler_context =
      InstanceHandlerDispatch.build_handler_context(
        data,
        context.iteration_fni_id,
        context.flow_node,
        process_instance_pid
      )

    handler_context = %{
      handler_context
      | loop: context.loop_overlay,
        multi_instance_id: context.shell_fni_id,
        iteration_index: context.index
    }

    :ok =
      InstanceHandlerDispatch.register_service_task_completion_route(
        context.flow_node,
        context.iteration_fni_id,
        context.shell_fni_id
      )

    case Task.Supervisor.start_child(data.task_supervisor, fn ->
           previous_trap_exit = Process.flag(:trap_exit, true)

           result =
             BoundaryAwareHandler.wrap_enter(
               handler_module,
               context.flow_node,
               context.token,
               handler_context
             )

           InstanceHandlerDispatch.dispatch_handler_result(
             process_instance_pid,
             context.iteration_fni_id,
             result
           )

           receive do
             {:EXIT, _from, :shutdown} -> :ok
           after
             0 -> :ok
           end

           Process.flag(:trap_exit, previous_trap_exit)
         end) do
      {:ok, task_pid} ->
        Process.monitor(task_pid)

        entry =
          build_mi_iteration_entry(
            task_pid,
            :active,
            context.flow_node,
            context.token,
            context.shell_fni_id,
            context.index,
            context.loop_overlay
          )

        data = put_in(data.flow_node_instance_states[context.iteration_fni_id], entry)

        data =
          put_in(
            data.mi_shell_tasks[context.iteration_fni_id],
            {context.shell_fni_id, context.shell_task_pid}
          )

        :gen_statem.reply(from, {:ok, context.iteration_fni_id})
        data

      {:error, reason} ->
        Logger.error(
          "Failed to start MI iteration task for #{context.flow_node.id}[#{context.index}]: #{inspect(reason)}"
        )

        fatal_mi_iteration_fni(
          data,
          from,
          context,
          "task_start_failed",
          "Failed to start MI iteration task for '#{context.flow_node.id}' index #{context.index}",
          :task_start_failed
        )
    end
  end

  defp fatal_mi_iteration_fni(data, from, context, error_code, message, reply_reason) do
    error_info = %{"error_code" => error_code, "message" => message}

    _persist_result =
      FniLifecycle.transition_to_fatal(
        context.iteration_fni_id,
        data.process_instance_id,
        error_info,
        context.flow_node,
        %{},
        context.lane_name,
        data.root_process_instance_id,
        multi_instance_id: context.shell_fni_id,
        iteration_index: context.index,
        was_waiting: false
      )

    entry =
      build_mi_iteration_entry(
        nil,
        :fatal,
        context.flow_node,
        context.token,
        context.shell_fni_id,
        context.index,
        context.loop_overlay
      )

    data = put_in(data.flow_node_instance_states[context.iteration_fni_id], entry)
    :gen_statem.reply(from, {:error, reply_reason})
    data
  end

  defp build_mi_iteration_entry(pid, state, flow_node, token, shell_fni_id, index, loop_overlay) do
    %{
      pid: pid,
      flow_node_id: flow_node.id,
      flow_node_type: flow_node.type,
      event_type: FlowNodeLookup.extract_event_type(flow_node),
      state: state,
      token: token,
      previous_flow_node_instance_ids: [shell_fni_id],
      type_properties: %{},
      next_flow_node_ids: [],
      loop_overlay: loop_overlay,
      multi_instance_id: shell_fni_id,
      iteration_index: index
    }
  end

  # An iteration that was already interrupted or settled keeps its state; its
  # shell was told or is gone.
  defp handle_mi_iteration_ok(data, iteration_fni_id, result, shell_task_pid) do
    data =
      if flow_node_instance_live?(data, iteration_fni_id) do
        send(shell_task_pid, {:mi_iteration_completed, iteration_fni_id, {:ok, result}})
        finish_iteration_entry(data, iteration_fni_id, result)
      else
        data
      end

    %{data | mi_shell_tasks: Map.delete(data.mi_shell_tasks, iteration_fni_id)}
  end

  defp finish_iteration_entry(data, iteration_fni_id, result) do
    data = %{
      data
      | data_object_cache:
          Map.merge(data.data_object_cache, extract_cache_updates(result.metadata))
    }

    case Map.get(data.flow_node_instance_states, iteration_fni_id) do
      nil ->
        data

      entry ->
        output_payload = result.output_payload || entry.token.payload

        put_in(data.flow_node_instance_states[iteration_fni_id], %{
          entry
          | state: :finished,
            pid: nil,
            token: %{entry.token | payload: output_payload}
        })
    end
  end

  defp handle_mi_iteration_error(data, iteration_fni_id, reason, shell_task_pid) do
    entry = Map.get(data.flow_node_instance_states, iteration_fni_id)

    data =
      if entry && entry.state not in [:finished, :fatal, :aborted, :interrupted, :error] do
        flow_node = FlowNodeLookup.find_flow_node(data, entry.flow_node_id)
        error_info = ErrorInfo.build(reason)

        _transition_result =
          FniLifecycle.transition_to_fatal(
            iteration_fni_id,
            data.process_instance_id,
            error_info,
            flow_node,
            Map.get(entry, :type_properties, %{}),
            LaneResolution.resolve_lane_name(data.process_model, flow_node),
            data.root_process_instance_id,
            multi_instance_id: Map.get(entry, :multi_instance_id),
            iteration_index: Map.get(entry, :iteration_index),
            was_waiting: entry.state == :waiting
          )

        put_in(data.flow_node_instance_states[iteration_fni_id], %{
          entry
          | state: :fatal,
            pid: nil
        })
      else
        data
      end

    send(shell_task_pid, {:mi_iteration_completed, iteration_fni_id, {:error, reason}})
    %{data | mi_shell_tasks: Map.delete(data.mi_shell_tasks, iteration_fni_id)}
  end

  defp reattach_iteration_shell(data, shell_fni_id, shell_task_pid) do
    iterations =
      data.flow_node_instance_states
      |> Enum.filter(fn {_id, entry} -> Map.get(entry, :multi_instance_id) == shell_fni_id end)
      |> Enum.sort_by(fn {_id, entry} -> Map.get(entry, :iteration_index) end)

    live = Enum.filter(iterations, fn {_id, entry} -> entry.state in [:active, :waiting] end)
    finished = Enum.filter(iterations, fn {_id, entry} -> entry.state == :finished end)

    data =
      Enum.reduce(live, data, fn {iteration_fni_id, _entry}, accumulator ->
        put_in(accumulator.mi_shell_tasks[iteration_fni_id], {shell_fni_id, shell_task_pid})
      end)

    occupied_indices =
      iterations
      |> Enum.map(fn {_id, entry} -> Map.get(entry, :iteration_index) end)
      |> Enum.reject(&is_nil/1)

    finished_payloads =
      Enum.map(finished, fn {_id, entry} ->
        payload = entry.token && entry.token.payload
        payload || %{}
      end)

    snapshot = %{
      live_count: length(live),
      finished_payloads: finished_payloads,
      occupied_indices: occupied_indices
    }

    {data, snapshot}
  end

  # Iterations end through their shell: killing one mid-write breaks its
  # connection. An iteration still tracked afterwards has its result queued;
  # while the instance keeps running, that message decides its outcome.
  defp interrupt_all_iterations(data) do
    data.mi_shell_tasks
    |> Enum.map(fn {_iteration_fni_id, {shell_fni_id, _shell_task_pid}} -> shell_fni_id end)
    |> Enum.uniq()
    |> Enum.reduce(data, &interrupt_iterations_for_shell(&2, &1))
  end

  defp live_entries_outside_iterations(data) do
    Enum.filter(data.flow_node_instance_states, fn {id, entry} ->
      entry.state in [:active, :waiting] and not Map.has_key?(data.mi_shell_tasks, id)
    end)
  end

  defp interrupt_iterations_for_shell(data, shell_fni_id) do
    iteration_fni_ids =
      data.mi_shell_tasks
      |> Enum.filter(fn {_iteration_fni_id, {owner_shell_fni_id, _shell_task_pid}} ->
        owner_shell_fni_id == shell_fni_id
      end)
      |> Enum.map(fn {iteration_fni_id, _shell_task} -> iteration_fni_id end)

    exit_reasons =
      iteration_fni_ids
      |> Enum.flat_map(&live_iteration_pid(data, &1))
      |> shutdown_and_await_iteration_tasks()

    Enum.reduce(iteration_fni_ids, data, fn iteration_fni_id, accumulator ->
      interrupt_single_iteration(accumulator, iteration_fni_id, exit_reasons)
    end)
  end

  defp live_iteration_pid(data, iteration_fni_id) do
    case Map.get(data.flow_node_instance_states, iteration_fni_id) do
      %{state: state, pid: pid} when state in [:active, :waiting] and is_pid(pid) ->
        if Process.alive?(pid), do: [pid], else: []

      _not_live ->
        []
    end
  end

  defp interrupt_single_iteration(data, iteration_fni_id, exit_reasons) do
    entry = Map.get(data.flow_node_instance_states, iteration_fni_id)

    cond do
      is_nil(entry) or entry.state not in [:active, :waiting] ->
        data

      Map.has_key?(exit_reasons, entry.pid) ->
        finish_shut_down_iteration(
          data,
          iteration_fni_id,
          entry,
          Map.fetch!(exit_reasons, entry.pid)
        )

      entry.state == :active ->
        # The pid is already dead but the entry is still :active: the
        # completion result or the crash DOWN is already queued in our
        # mailbox. Let that message drive the outcome; leave mi_shell_tasks
        # alone so it is still there when that message is processed. A
        # queued park result interrupts the iteration instead.
        put_in(
          data.flow_node_instance_states[iteration_fni_id],
          Map.put(entry, :interrupt_requested, true)
        )

      true ->
        # entry.state == :waiting with a nil/dead pid: a parked iteration with
        # no in-flight write to protect. Cancel it now.
        finish_interrupted_iteration(data, iteration_fni_id, entry)
    end
  end

  # A queued `{:ok, %FlowNodeResult{}}` means the Task already committed its
  # finish; that message decides the outcome.
  defp finish_shut_down_iteration(data, iteration_fni_id, entry, exit_reason) do
    case exit_reason do
      reason when reason in [:normal, :shutdown, :noproc] ->
        if queued_ok_iteration_result?(iteration_fni_id) do
          data
        else
          finish_interrupted_iteration(data, iteration_fni_id, entry)
        end

      _other_reason ->
        finish_interrupted_iteration(data, iteration_fni_id, entry)
    end
  end

  defp queued_ok_iteration_result?(iteration_fni_id) do
    {:messages, messages} = Process.info(self(), :messages)

    Enum.any?(messages, fn
      {:fni_result, ^iteration_fni_id, {:ok, %FlowNodeResult{}}} -> true
      _ -> false
    end)
  end

  defp shutdown_and_await_iteration_tasks([]), do: %{}

  defp shutdown_and_await_iteration_tasks(pids) do
    monitored = Map.new(pids, fn pid -> {Process.monitor(pid), pid} end)
    Enum.each(pids, &Process.exit(&1, :shutdown))

    {exit_reasons, remaining} =
      await_iteration_downs(monitored, %{}, deadline_after(@iteration_shutdown_grace_ms))

    Enum.each(remaining, fn {_reference, pid} -> Process.exit(pid, :kill) end)

    {exit_reasons, unconfirmed} =
      await_iteration_downs(remaining, exit_reasons, deadline_after(@iteration_kill_wait_ms))

    Enum.reduce(unconfirmed, exit_reasons, fn {reference, pid}, accumulator ->
      Process.demonitor(reference, [:flush])
      Map.put(accumulator, pid, :killed)
    end)
  end

  defp deadline_after(milliseconds), do: System.monotonic_time(:millisecond) + milliseconds

  defp await_iteration_downs(monitored, exit_reasons, _deadline) when map_size(monitored) == 0,
    do: {exit_reasons, monitored}

  defp await_iteration_downs(monitored, exit_reasons, deadline) do
    remaining_ms = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:DOWN, reference, :process, pid, exit_reason} when is_map_key(monitored, reference) ->
        await_iteration_downs(
          Map.delete(monitored, reference),
          Map.put(exit_reasons, pid, exit_reason),
          deadline
        )
    after
      remaining_ms -> {exit_reasons, monitored}
    end
  end

  defp finish_interrupted_iteration(
         data,
         iteration_fni_id,
         entry,
         reason \\ :cancelled_by_mi_shell
       ) do
    shell_task = Map.get(data.mi_shell_tasks, iteration_fni_id)
    flow_node = FlowNodeLookup.find_flow_node(data, entry.flow_node_id)

    persist_result =
      FniLifecycle.transition_to_interrupted(
        iteration_fni_id,
        data.process_instance_id,
        reason,
        flow_node,
        entry.type_properties,
        LaneResolution.resolve_lane_name(data.process_model, flow_node),
        data.root_process_instance_id,
        multi_instance_id: Map.get(entry, :multi_instance_id),
        iteration_index: Map.get(entry, :iteration_index),
        was_waiting: entry.state == :waiting
      )

    case persist_result do
      {:ok, :already_terminal} ->
        if queued_ok_iteration_result?(iteration_fni_id) do
          data
        else
          persisted_state =
            notify_shell_of_persisted_iteration_finish(shell_task, iteration_fni_id)

          data = %{data | mi_shell_tasks: Map.delete(data.mi_shell_tasks, iteration_fni_id)}

          put_in(data.flow_node_instance_states[iteration_fni_id], %{
            entry
            | state: persisted_state,
              pid: nil
          })
        end

      _other ->
        InstanceHandlerDispatch.release_handler(
          flow_node,
          iteration_fni_id,
          :handle_aborted,
          entry
        )

        data = %{data | mi_shell_tasks: Map.delete(data.mi_shell_tasks, iteration_fni_id)}

        put_in(data.flow_node_instance_states[iteration_fni_id], %{
          entry
          | state: :interrupted,
            pid: nil
        })
    end
  end

  # Returns the iteration's persisted terminal state so the in-memory entry
  # leaves `:active`/`:waiting`; a dead pid there would keep the PI alive.
  defp notify_shell_of_persisted_iteration_finish(shell_task, iteration_fni_id) do
    adapter = PersistenceAdapter.adapter()

    case adapter.get_flow_node_instance_by_id(iteration_fni_id) do
      {:ok, %{state: state, output_token: output_token}}
      when state in [:finished, "finished"] ->
        notify_shell_of_finished_iteration(shell_task, iteration_fni_id, output_token)
        :finished

      {:ok, %{state: state}} when is_binary(state) ->
        persisted_terminal_state(state)

      _other ->
        :interrupted
    end
  end

  defp notify_shell_of_finished_iteration(nil, _iteration_fni_id, _output_token), do: :ok

  defp notify_shell_of_finished_iteration(
         {_shell_fni_id, shell_task_pid},
         iteration_fni_id,
         output_token
       ) do
    send(
      shell_task_pid,
      {:mi_iteration_completed, iteration_fni_id,
       {:ok,
        %FlowNodeResult{
          output_payload: output_token || %{},
          next_flow_node_ids: [],
          metadata: %{persisted: true}
        }}}
    )
  end

  defp persisted_flow_node_instance_state(flow_node_instance_id) do
    case PersistenceAdapter.adapter().get_flow_node_instance_by_id(flow_node_instance_id) do
      {:ok, %{state: state}} when state in [:finished, "finished"] -> :finished
      {:ok, %{state: state}} when is_binary(state) -> persisted_terminal_state(state)
      _other -> :interrupted
    end
  end

  defp persisted_terminal_state("fatal"), do: :fatal
  defp persisted_terminal_state("aborted"), do: :aborted
  defp persisted_terminal_state("error"), do: :error
  defp persisted_terminal_state(_state), do: :interrupted

  defp resolve_incoming_sequence_flow_id(data, flow_node, [source_fni_id | _])
       when is_binary(source_fni_id) do
    resolve_incoming_sequence_flow_id(data, flow_node, source_fni_id)
  end

  defp resolve_incoming_sequence_flow_id(data, flow_node, source_fni_id)
       when is_binary(source_fni_id) do
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
    {started_by_id, has_laneless_flow_node, lane_names} =
      process_instance_visibility_fields(data)

    EngineEventBus.publish(%Event.ProcessInstanceStateChanged{
      process_instance_id: data.process_instance_id,
      process_model_id: data.process_model.id,
      version: data.process_model.version,
      parent_process_instance_id: data.parent_process_instance_id,
      root_process_instance_id: data.root_process_instance_id,
      triggerer_flow_node_instance_id: data.triggerer_flow_node_instance_id,
      old_state: old_state,
      new_state: new_state,
      started_by_id: started_by_id,
      has_laneless_flow_node: has_laneless_flow_node,
      lane_names: lane_names,
      occurred_at: DateTime.utc_now()
    })

    :telemetry.execute(
      [:bfw_engine, :process_instance, :state_change],
      %{system_time: System.system_time()},
      %{
        process_instance_id: data.process_instance_id,
        parent_process_instance_id: data.parent_process_instance_id,
        old_state: old_state,
        new_state: new_state
      }
    )
  end

  defp process_instance_visibility_fields(data) do
    lane_names =
      data.flow_node_instance_states
      |> Map.values()
      |> Enum.map(fn entry ->
        resolve_lane_for_flow_node_id(data, entry.flow_node_id)
      end)

    has_laneless_flow_node = Enum.any?(lane_names, &is_nil/1)
    distinct_lane_names = lane_names |> Enum.reject(&is_nil/1) |> Enum.uniq() |> Enum.sort()

    started_by_id =
      case data.identity do
        %{id: identity_id} -> identity_id
        _ -> nil
      end

    {started_by_id, has_laneless_flow_node, distinct_lane_names}
  end

  defp resolve_lane_for_flow_node_id(data, flow_node_id) do
    flow_node = FlowNodeLookup.find_flow_node(data, flow_node_id)
    LaneResolution.resolve_lane_name(data.process_model, flow_node)
  end

  defp resolve_lane_for_flow_node_instance(data, flow_node_instance_id) do
    case Map.get(data.flow_node_instance_states, flow_node_instance_id) do
      nil -> nil
      entry -> resolve_lane_for_flow_node_id(data, entry.flow_node_id)
    end
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

  defp notify_parent(data, :compensated) do
    case data.notify_pid do
      nil ->
        :ok

      pid when is_pid(pid) ->
        process_instance_pid = self()
        final_tokens = build_final_tokens(data)
        send(pid, {:child_pi_compensated, process_instance_pid, final_tokens})
    end
  end

  defp notify_parent(data, :cancelled) do
    case data.notify_pid do
      nil ->
        :ok

      pid when is_pid(pid) ->
        process_instance_pid = self()
        final_tokens = build_final_tokens(data)
        send(pid, {:child_pi_cancelled, process_instance_pid, final_tokens})
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

  defp forward_escalation_passthrough(%{notify_pid: nil} = data, escalation_info) do
    :telemetry.execute(
      [:bfw_engine, :escalation, :uncaught],
      %{system_time: System.system_time()},
      %{process_instance_id: data.process_instance_id, escalation_info: escalation_info}
    )
  end

  defp forward_escalation_passthrough(data, escalation_info) do
    send(data.notify_pid, {:child_pi_escalation_passthrough, self(), escalation_info})
  end

  defp emit_fni_started(
         data,
         flow_node_instance_id,
         flow_node,
         previous_flow_node_instance_ids,
         opts \\ []
       ) do
    EngineEventBus.publish(%Event.FlowNodeInstanceStarted{
      flow_node_instance_id: flow_node_instance_id,
      process_instance_id: data.process_instance_id,
      root_process_instance_id: data.root_process_instance_id,
      flow_node_id: flow_node.id,
      flow_node_type: flow_node.type,
      event_type: FlowNodeLookup.extract_event_type(flow_node),
      lane_name: LaneResolution.resolve_lane_name(data.process_model, flow_node),
      triggerer_flow_node_instance_id: nil,
      multi_instance_id: Keyword.get(opts, :multi_instance_id),
      iteration_index: Keyword.get(opts, :iteration_index),
      occurred_at: DateTime.utc_now()
    })

    :telemetry.execute(
      [:bfw_engine, :flow_node_instance, :started],
      %{system_time: System.system_time()},
      %{
        flow_node_instance_id: flow_node_instance_id,
        flow_node_type: flow_node.type,
        previous_flow_node_instance_ids: previous_flow_node_instance_ids
      }
    )
  end

  defp emit_fni_state_changed(data, flow_node_instance_id, entry, old_state, new_state) do
    flow_node = FlowNodeLookup.find_flow_node(data, entry.flow_node_id)

    EngineEventBus.publish(%Event.FlowNodeInstanceStateChanged{
      flow_node_instance_id: flow_node_instance_id,
      process_instance_id: data.process_instance_id,
      root_process_instance_id: data.root_process_instance_id,
      flow_node_id: entry.flow_node_id,
      flow_node_type: entry.flow_node_type,
      event_type:
        if(flow_node,
          do: FlowNodeLookup.extract_event_type(flow_node),
          else: Map.get(entry, :event_type)
        ),
      lane_name:
        if(flow_node, do: LaneResolution.resolve_lane_name(data.process_model, flow_node)),
      old_state: old_state,
      new_state: new_state,
      multi_instance_id: Map.get(entry, :multi_instance_id),
      iteration_index: Map.get(entry, :iteration_index),
      occurred_at: DateTime.utc_now()
    })

    :telemetry.execute(
      [:bfw_engine, :flow_node_instance, :state_change],
      %{system_time: System.system_time()},
      %{
        flow_node_instance_id: flow_node_instance_id,
        process_instance_id: data.process_instance_id,
        flow_node_type: entry.flow_node_type,
        old_state: old_state,
        new_state: new_state,
        multi_instance_id: Map.get(entry, :multi_instance_id)
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
      root_process_instance_id: data.root_process_instance_id,
      lane_name: resolve_lane_for_flow_node_instance(data, flow_node_instance_id),
      occurred_at: DateTime.utc_now()
    })

    :telemetry.execute(
      [:bfw_engine, :call_activity, :child_started],
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

  # -------------------------------------------------------------------
  # ESP trigger action execution (thin delegation to EspScope)
  # -------------------------------------------------------------------

  defp deliver_api_escalation(data, escalation_info) do
    {data, esp_deliveries} = fire_api_escalation_esp(data, escalation_info)
    {data, boundary_deliveries} = fire_api_escalation_boundaries(data, escalation_info)
    {data, esp_deliveries ++ boundary_deliveries}
  end

  defp fire_api_escalation_esp(data, escalation_info) do
    case EspScope.resolve_escalation_catch(data, escalation_info) do
      {:ok, :noop} ->
        {data, []}

      {:ok, action} ->
        previous_ids = MapSet.new(Map.keys(data.flow_node_instance_states))
        data = execute_esp_action(data, action)
        record_api_esp_delivery(data, previous_ids, action, escalation_info)

      :none ->
        {data, []}
    end
  end

  defp record_api_esp_delivery(data, previous_ids, action, escalation_info) do
    case newly_dispatched_esp_flow_node_instance(data, previous_ids, action) do
      {flow_node_instance_id, flow_node_id} ->
        emit_escalation_raised(
          data,
          flow_node_instance_id,
          flow_node_id,
          escalation_info,
          :api_trigger
        )

        delivery = %{
          process_instance_id: data.process_instance_id,
          flow_node_instance_id: flow_node_instance_id
        }

        {data, [delivery]}

      nil ->
        {data, []}
    end
  end

  defp newly_dispatched_esp_flow_node_instance(data, previous_ids, {_tag, esp_node, _payload}) do
    Enum.find_value(data.flow_node_instance_states, fn {flow_node_instance_id, entry} ->
      if not MapSet.member?(previous_ids, flow_node_instance_id) and
           entry.flow_node_id == esp_node.id do
        {flow_node_instance_id, esp_node.id}
      end
    end)
  end

  defp fire_api_escalation_boundaries(data, escalation_info) do
    fires = EscalationTrigger.matching_waiting_boundaries(data, escalation_info)

    Enum.reduce(fires, {data, []}, fn fire, {accumulator, deliveries} ->
      apply_api_escalation_boundary_fire(accumulator, deliveries, fire, escalation_info)
    end)
  end

  defp apply_api_escalation_boundary_fire(data, deliveries, fire, escalation_info) do
    data =
      apply_boundary_catch_or_cycle_fire(
        data,
        fire.host_flow_node_instance_id,
        fire.boundary_node_id,
        escalation_info,
        fire.cancel_activity,
        nil,
        :catch
      )

    emit_escalation_raised(
      data,
      fire.boundary_flow_node_instance_id,
      fire.boundary_node_id,
      escalation_info,
      :api_trigger
    )

    delivery = %{
      process_instance_id: data.process_instance_id,
      flow_node_instance_id: fire.boundary_flow_node_instance_id
    }

    {data, deliveries ++ [delivery]}
  end

  defp reply_api_escalation_trigger(data, from, deliveries) do
    data = evaluate_parked_inclusive_joins(data)
    data = evaluate_parked_complex_joins(data)
    data = evaluate_conditional_waiters(data)
    data = execute_esp_conditionals(data)
    reply = {:ok, deliveries}

    if api_escalation_has_fatal_flow_node?(data) do
      do_transition_to_fatal(data, :fni_fatal, [{:reply, from, reply}])
    else
      finish_or_keep_after_api_escalation(data, from, reply)
    end
  end

  defp api_escalation_has_fatal_flow_node?(data) do
    Enum.any?(data.flow_node_instance_states, fn {_id, entry} -> entry.state == :fatal end)
  end

  defp finish_or_keep_after_api_escalation(data, from, reply) do
    case maybe_finish(data) do
      {:stop, data} -> {:stop_and_reply, :normal, [{:reply, from, reply}], data}
      {:continue, data} -> {:keep_state, data, [{:reply, from, reply}]}
    end
  end

  defp execute_esp_action(data, {:fire_interrupting, esp_node, payload}) do
    data
    |> interrupt_remaining_fnis(nil, :interrupted_by_event_subprocess)
    |> EspScope.teardown_triggers()
    |> dispatch_esp_shell(esp_node, payload)
  end

  defp execute_esp_action(data, {:fire_non_interrupting, esp_node, payload}) do
    dispatch_esp_shell(data, esp_node, payload)
  end

  defp execute_esp_action(data, :noop), do: data

  defp dispatch_esp_shell(data, esp_node, payload) do
    token = %Token{
      id: UuidV7.generate(),
      process_instance_id: data.process_instance_id,
      payload: payload || %{},
      originating_flow_node_instance_id: nil,
      created_at: DateTime.utc_now()
    }

    dispatch_flow_node_instance(data, esp_node, token, [])
  end

  defp execute_esp_conditionals(data) do
    {data, actions} = EspScope.evaluate_conditionals(data)
    Enum.reduce(actions, data, &execute_esp_action(&2, &1))
  end

  defp emit_subprocess_child_started(
         data,
         flow_node_instance_id,
         child_process_instance_id,
         subprocess_node_id,
         child_process_model_id,
         child_version,
         is_event_subprocess,
         is_ad_hoc_subprocess
       ) do
    EngineEventBus.publish(%Event.SubProcessChildStarted{
      subprocess_flow_node_instance_id: flow_node_instance_id,
      parent_process_instance_id: data.process_instance_id,
      child_process_instance_id: child_process_instance_id,
      subprocess_node_id: subprocess_node_id,
      child_process_model_id: child_process_model_id,
      child_version: child_version,
      is_event_subprocess: is_event_subprocess,
      is_ad_hoc_subprocess: is_ad_hoc_subprocess,
      root_process_instance_id: data.root_process_instance_id,
      lane_name: resolve_lane_for_flow_node_id(data, subprocess_node_id),
      occurred_at: DateTime.utc_now()
    })

    :telemetry.execute(
      [:bfw_engine, :subprocess, :child_started],
      %{system_time: System.system_time()},
      %{
        subprocess_flow_node_instance_id: flow_node_instance_id,
        parent_process_instance_id: data.process_instance_id,
        child_process_instance_id: child_process_instance_id,
        subprocess_node_id: subprocess_node_id,
        child_process_model_id: child_process_model_id,
        child_version: child_version,
        is_event_subprocess: is_event_subprocess
      }
    )
  end

  defp emit_escalation_raised(
         data,
         flow_node_instance_id,
         flow_node_id,
         escalation_info,
         throw_type
       ) do
    EngineEventBus.publish(%Event.EscalationRaised{
      escalation_code: escalation_info[:escalation_code],
      escalation_name: escalation_info[:escalation_name],
      process_instance_id: data.process_instance_id,
      root_process_instance_id: data.root_process_instance_id,
      flow_node_instance_id: flow_node_instance_id,
      flow_node_id: flow_node_id,
      throw_type: throw_type,
      lane_name: resolve_lane_for_flow_node_id(data, flow_node_id),
      occurred_at: DateTime.utc_now()
    })

    :telemetry.execute(
      [:bfw_engine, :escalation, :raised],
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
      [:bfw_engine, :escalation, :uncaught],
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

  defp emit_compensation_triggered(data, flow_node_instance_id, run_spec, target_count) do
    entry = Map.get(data.flow_node_instance_states, flow_node_instance_id)

    EngineEventBus.publish(%Event.CompensationTriggered{
      process_instance_id: data.process_instance_id,
      root_process_instance_id: data.root_process_instance_id,
      flow_node_instance_id: flow_node_instance_id,
      flow_node_id: (entry && entry.flow_node_id) || "",
      throw_type: run_spec.throw_type,
      activity_ref: get_in(run_spec, [:event_definition, Access.key(:activity_ref)]),
      target_count: target_count,
      lane_name: resolve_lane_for_flow_node_instance(data, flow_node_instance_id),
      occurred_at: DateTime.utc_now()
    })

    :telemetry.execute(
      [:bfw_engine, :compensation, :triggered],
      %{system_time: System.system_time()},
      %{
        process_instance_id: data.process_instance_id,
        flow_node_instance_id: flow_node_instance_id,
        throw_type: run_spec.throw_type,
        target_count: target_count
      }
    )
  end

  defp emit_activity_compensated(data, handler_fni_id, handler_entry, throw_fni_id) do
    type_properties = handler_entry.type_properties || %{}

    compensated_fni_id =
      Map.get(type_properties, :compensation_for) ||
        Map.get(type_properties, "compensation_for") || ""

    handler_activity_id = handler_entry.flow_node_id

    EngineEventBus.publish(%Event.ActivityCompensated{
      process_instance_id: data.process_instance_id,
      root_process_instance_id: data.root_process_instance_id,
      compensated_fni_id: compensated_fni_id,
      handler_fni_id: handler_fni_id,
      throw_fni_id: throw_fni_id,
      flow_node_id: handler_activity_id,
      handler_activity_id: handler_activity_id,
      lane_name: resolve_lane_for_flow_node_id(data, handler_activity_id),
      occurred_at: DateTime.utc_now()
    })

    :telemetry.execute(
      [:bfw_engine, :compensation, :activity_compensated],
      %{system_time: System.system_time()},
      %{
        process_instance_id: data.process_instance_id,
        handler_fni_id: handler_fni_id,
        throw_fni_id: throw_fni_id
      }
    )
  end

  defp identity_to_map(nil), do: nil

  defp identity_to_map(%{id: id, roles: roles, groups: groups}),
    do: %{"id" => id, "roles" => roles, "groups" => groups}

  # -------------------------------------------------------------------
  # Ad-hoc subprocess: completion condition evaluation
  # -------------------------------------------------------------------

  defp maybe_evaluate_adhoc_completion_condition(
         %{
           mode: AdHocMode,
           adhoc_completion_condition: condition,
           adhoc_completion_signaled: false
         } =
           data
       )
       when is_binary(condition) and condition != "" do
    bindings = build_adhoc_completion_bindings(data)

    result =
      if data.adhoc_completion_condition_compiled do
        BfwEngine.Expressions.evaluate(data.adhoc_completion_condition_compiled, bindings)
      else
        BfwEngine.Expressions.eval(condition, bindings)
      end

    case result do
      {:ok, true} ->
        %{data | adhoc_completion_signaled: true}

      {:ok, _falsy} ->
        data

      {:error, reason} ->
        Logger.warning("Ad-hoc completion condition evaluation failed: #{inspect(reason)}")

        data
    end
  end

  defp maybe_evaluate_adhoc_completion_condition(data), do: data

  defp build_adhoc_completion_bindings(data) do
    inner_activities =
      Enum.filter(data.process_model.flow_nodes, fn node ->
        node.type not in [:start_event, :end_event, :boundary_event]
      end)

    performed_count =
      inner_activities
      |> Enum.count(fn activity ->
        Enum.any?(data.flow_node_instance_states, fn {_id, entry} ->
          entry.flow_node_id == activity.id and entry.state == :finished
        end)
      end)

    active_count =
      Enum.count(data.flow_node_instance_states, fn {_id, entry} ->
        entry.state in [:active, :waiting]
      end)

    %{
      "performedActivities" => performed_count,
      "activeCount" => active_count,
      "totalActivities" => length(inner_activities)
    }
  end

  # -------------------------------------------------------------------
  # Ad-hoc subprocess: sequential auto-chaining
  # -------------------------------------------------------------------

  defp maybe_auto_chain_sequential_adhoc(
         %{mode: AdHocMode, adhoc_ordering: :sequential, adhoc_completion_signaled: false} = data
       ) do
    has_active =
      Enum.any?(data.flow_node_instance_states, fn {_id, entry} ->
        entry.state in [:active, :waiting]
      end)

    if has_active do
      data
    else
      inner_activities =
        Enum.filter(data.process_model.flow_nodes, fn node ->
          node.type not in [:start_event, :end_event, :boundary_event]
        end)

      performed_ids =
        data.flow_node_instance_states
        |> Enum.filter(fn {_id, entry} -> entry.state == :finished end)
        |> Enum.map(fn {_id, entry} -> entry.flow_node_id end)
        |> MapSet.new()

      next_activity =
        Enum.find(inner_activities, fn activity ->
          not MapSet.member?(performed_ids, activity.id)
        end)

      case next_activity do
        nil ->
          data

        activity ->
          activation_token = %Token{
            id: UuidV7.generate(),
            process_instance_id: data.process_instance_id,
            payload: adhoc_current_token_payload(data.flow_node_instance_states),
            originating_flow_node_instance_id: nil,
            created_at: DateTime.utc_now()
          }

          dispatch_flow_node_instance(data, activity, activation_token, [])
      end
    end
  end

  defp maybe_auto_chain_sequential_adhoc(data), do: data

  # -------------------------------------------------------------------
  # Ad-hoc subprocess: cancel remaining instances after completion
  # -------------------------------------------------------------------

  defp maybe_cancel_remaining_for_adhoc(
         %{
           mode: AdHocMode,
           adhoc_completion_signaled: true,
           adhoc_cancel_remaining_instances: true
         } =
           data
       ) do
    interrupt_remaining_fnis(data, nil, :adhoc_completion_cancelled)
  end

  defp maybe_cancel_remaining_for_adhoc(data), do: data

  # -------------------------------------------------------------------
  # Ad-hoc subprocess helpers (used by :call handlers)
  # -------------------------------------------------------------------

  defp do_activate_adhoc_activity(data, flow_node_id) do
    case Enum.find(data.process_model.flow_nodes, &(&1.id == flow_node_id)) do
      nil ->
        {{:error, :adhoc_activity_not_found}, data}

      _flow_node when data.adhoc_completion_signaled ->
        {{:error, :adhoc_already_completing}, data}

      _flow_node when data.adhoc_ordering == :sequential ->
        has_active =
          Enum.any?(data.flow_node_instance_states, fn {_id, entry} ->
            entry.state in [:active, :waiting]
          end)

        if has_active do
          {{:error, :adhoc_sequential_busy}, data}
        else
          do_dispatch_adhoc_activity(data, flow_node_id)
        end

      _flow_node ->
        do_dispatch_adhoc_activity(data, flow_node_id)
    end
  end

  defp do_dispatch_adhoc_activity(data, flow_node_id, activation_source \\ "rest") do
    flow_node = Enum.find(data.process_model.flow_nodes, &(&1.id == flow_node_id))
    old_fni_ids = MapSet.new(Map.keys(data.flow_node_instance_states))

    activation_token = %Token{
      id: UuidV7.generate(),
      process_instance_id: data.process_instance_id,
      payload: data.flow_node_instance_states |> adhoc_current_token_payload(),
      originating_flow_node_instance_id: nil,
      created_at: DateTime.utc_now()
    }

    data = dispatch_flow_node_instance(data, flow_node, activation_token, [])

    new_fni_ids =
      data.flow_node_instance_states
      |> Map.keys()
      |> Enum.reject(&MapSet.member?(old_fni_ids, &1))

    case new_fni_ids do
      [fni_id] ->
        emit_adhoc_activity_activated(data, flow_node_id, fni_id, activation_source)
        {{:ok, %{flow_node_instance_id: fni_id}}, data}

      _ ->
        {{:error, :dispatch_failed}, data}
    end
  end

  defp adhoc_current_token_payload(fni_states) do
    fni_states
    |> Enum.filter(fn {_id, entry} -> entry.state == :finished end)
    |> Enum.sort_by(fn {id, _entry} -> id end)
    |> Enum.reduce(%{}, fn {_id, entry}, accumulator ->
      Map.merge(accumulator, entry.token.payload)
    end)
  end

  defp build_adhoc_activities_list(data) do
    inner_activities =
      Enum.filter(data.process_model.flow_nodes, fn node ->
        node.type not in [:start_event, :end_event, :boundary_event]
      end)

    fni_states_by_flow_node_id = group_fni_states_by_flow_node_id(data)

    has_any_active =
      Enum.any?(data.flow_node_instance_states, fn {_id, entry} ->
        entry.state in [:active, :waiting]
      end)

    Enum.map(inner_activities, fn activity ->
      fni_entries = Map.get(fni_states_by_flow_node_id, activity.id, [])
      performed_count = Enum.count(fni_entries, fn {_id, entry} -> entry.state == :finished end)

      active_count =
        Enum.count(fni_entries, fn {_id, entry} -> entry.state in [:active, :waiting] end)

      enabled =
        cond do
          data.adhoc_completion_signaled -> false
          data.adhoc_ordering == :sequential and has_any_active -> false
          true -> true
        end

      %{
        id: activity.id,
        name: activity.name,
        type: Atom.to_string(activity.type),
        enabled: enabled,
        performed_count: performed_count,
        active_count: active_count
      }
    end)
  end

  defp build_adhoc_status(data) do
    inner_activities =
      Enum.filter(data.process_model.flow_nodes, fn node ->
        node.type not in [:start_event, :end_event, :boundary_event]
      end)

    fni_states_by_flow_node_id = group_fni_states_by_flow_node_id(data)

    total_active =
      data.flow_node_instance_states
      |> Enum.count(fn {_id, entry} -> entry.state in [:active, :waiting] end)

    performed_activity_ids =
      inner_activities
      |> Enum.filter(fn activity ->
        fni_entries = Map.get(fni_states_by_flow_node_id, activity.id, [])
        Enum.any?(fni_entries, fn {_id, entry} -> entry.state == :finished end)
      end)
      |> Enum.map(& &1.id)

    has_any_active =
      Enum.any?(data.flow_node_instance_states, fn {_id, entry} ->
        entry.state in [:active, :waiting]
      end)

    enabled_activity_ids =
      inner_activities
      |> Enum.filter(fn _activity ->
        cond do
          data.adhoc_completion_signaled -> false
          data.adhoc_ordering == :sequential and has_any_active -> false
          true -> true
        end
      end)
      |> Enum.map(& &1.id)

    %{
      active_count: total_active,
      performed_activities: performed_activity_ids,
      enabled_activities: enabled_activity_ids,
      completion_signaled: data.adhoc_completion_signaled
    }
  end

  defp group_fni_states_by_flow_node_id(data) do
    Enum.reduce(data.flow_node_instance_states, %{}, fn {fni_id, entry}, accumulator ->
      flow_node_id = entry.flow_node_id
      Map.update(accumulator, flow_node_id, [{fni_id, entry}], &[{fni_id, entry} | &1])
    end)
  end

  defp emit_adhoc_activity_activated(data, flow_node_id, flow_node_instance_id, source) do
    EngineEventBus.publish(%Event.AdHocActivityActivated{
      process_instance_id: data.process_instance_id,
      root_process_instance_id: data.root_process_instance_id,
      adhoc_flow_node_instance_id: data.triggerer_flow_node_instance_id || "",
      activated_flow_node_id: flow_node_id,
      activated_flow_node_instance_id: flow_node_instance_id,
      activation_source: source,
      lane_name: resolve_lane_for_flow_node_id(data, flow_node_id),
      occurred_at: DateTime.utc_now()
    })
  end

  @spec fetch_process_model(String.t(), String.t() | nil) ::
          {:ok, struct(), struct()} | {:error, term()}
  defp fetch_process_model(process_version_id, subprocess_node_id)

  defp fetch_process_model(process_version_id, nil) do
    case ModelCache.fetch(process_version_id) do
      {:ok, definitions} ->
        case select_executable_process(definitions, process_version_id) do
          nil ->
            {:error, :no_executable_process}

          process ->
            enriched_process =
              process
              |> InclusiveJoinAnalysis.enrich_process()
              |> ComplexRegionAnalysis.enrich_process()

            {:ok, enriched_process, definitions}
        end

      error ->
        error
    end
  end

  defp fetch_process_model(process_version_id, subprocess_node_id) do
    case ModelCache.fetch_subprocess_model(process_version_id, subprocess_node_id) do
      {:ok, subprocess_model, definitions} ->
        enriched_subprocess =
          subprocess_model
          |> InclusiveJoinAnalysis.enrich_process()
          |> ComplexRegionAnalysis.enrich_process()

        {:ok, enriched_subprocess, definitions}

      error ->
        error
    end
  end

  # A file with several processes yields one version per process, all sharing the
  # same definitions; the version's process model id picks the process to run.
  defp select_executable_process(definitions, process_version_id) do
    case Enum.filter(definitions.processes, & &1.is_executable) do
      [] ->
        nil

      [single_process] ->
        single_process

      executable_processes ->
        case CalledElementResolver.adapter().resolve_process_model_id(process_version_id) do
          {:ok, process_model_id} -> Enum.find(executable_processes, &(&1.id == process_model_id))
          {:error, _reason} -> nil
        end
    end
  end

  @spec find_fni_by_pid(struct(), pid()) :: {String.t(), map()} | nil
  defp find_fni_by_pid(data, pid) do
    Enum.find(data.flow_node_instance_states, fn {_id, entry} -> entry.pid == pid end)
  end

  @spec build_unsupported_event_definition_error_info(FlowNode.t()) :: %{String.t() => term()}
  defp build_unsupported_event_definition_error_info(%FlowNode{} = flow_node) do
    event_type = FlowNodeLookup.extract_event_type(flow_node) || "unknown"
    flow_node_type = Atom.to_string(flow_node.type)

    %{
      "error_code" => "unsupported_event_definition",
      "message" =>
        "Unsupported event definition '#{event_type}' on flow node '#{flow_node.id}' (#{flow_node_type})",
      "detail" => %{
        "flow_node_id" => flow_node.id,
        "flow_node_type" => flow_node_type,
        "event_type" => event_type
      }
    }
  end

  @spec send_async_gate(pid() | nil, :continue | :cancel) :: :ok
  defp send_async_gate(nil, _decision), do: :ok

  defp send_async_gate(pid, decision) when decision in [:continue, :cancel] do
    send(pid, {:async_gate, decision})
    :ok
  end
end

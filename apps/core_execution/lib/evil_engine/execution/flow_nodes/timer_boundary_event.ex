defmodule EvilEngine.Execution.FlowNodes.TimerBoundaryEvent do
  @moduledoc """
  Handler for `<bpmn:boundaryEvent>` with a Timer event definition.

  This is a subscription-model boundary handler: the handler owns its
  trigger source (the timer), subscribes to the Scheduler, and returns
  `{:boundary, boundary_node_id, payload, cancel_activity}` when the
  timer fires.

  ## Lifecycle

  1. `handle_enter/3` extracts the timer spec, evaluates FEEL if
     needed, schedules the timer with `target: self()` (the handler
     Task PID), and returns `{:async, fni_id, continuation, type_properties}`.
  2. The continuation blocks on `receive {:timer_fired, ...}`. When
     the timer fires, it returns `{:boundary, ...}` to the PI.
  3. The PI processes the boundary result generically: interrupts the
     host (if `cancel_activity`), cancels siblings, and dispatches the
     boundary event's outgoing path.

  ## Interrupting vs non-interrupting

  - **Interrupting** (`cancel_activity: true`): the boundary fires once,
    the host is interrupted, sibling boundaries are cancelled.
  - **Non-interrupting** (`cancel_activity: false`): the boundary fires,
    a parallel branch is spawned, the host continues.

  ## Cycle support

  `time_cycle` is supported on both interrupting and non-interrupting
  boundary events:

  - **Interrupting cycle**: Fires once (the first cycle fire). The host
    is interrupted and sibling boundaries are cancelled — identical to
    date/duration semantics.
  - **Non-interrupting cycle**: The handler Task loops, firing the
    boundary event on each cycle iteration and sending
    `{:boundary_cycle_fire, ...}` to the PI for intermediate fires.
    Each fire dispatches the boundary's outgoing path as a new parallel
    branch. The final fire (repetitions exhausted) uses the normal
    `{:boundary, ...}` result and finishes the boundary FNI. For
    infinite cycles (`R/...`), the Task loops indefinitely until killed
    by `cancel_boundary_fnis_for_host` when the host activity completes.

  ## Cleanup

  `handle_fatal/1` and `handle_aborted/1` cancel the armed timer in the
  Scheduler. The handler Task is killed by the Task Supervisor when the
  PI terminates — process hierarchy cleanup is the safety net.
  """

  @behaviour EvilEngine.Execution.FlowNodeHandler

  alias EvilEngine.BPMN.Model.FlowNode
  alias EvilEngine.Events.EngineEventBus
  alias EvilEngine.Execution.FniLifecycle
  alias EvilEngine.Execution.HandlerContext
  alias EvilEngine.Execution.ProcessInstance.Helpers
  alias EvilEngine.Expressions
  alias EvilEngine.Expressions.Context, as: FeelContext
  alias EvilEngine.Timers.ISO8601
  alias EvilEngine.Timers.Scheduler
  alias EvilEngine.Types.Event
  alias EvilEngine.Types.Token

  # -------------------------------------------------------------------
  # FlowNodeHandler callbacks
  # -------------------------------------------------------------------

  @spec handle_enter(FlowNode.t(), Token.t(), HandlerContext.t()) ::
          {:async, String.t(), (-> term()), map()} | {:error, term()}
  @impl true
  def handle_enter(flow_node, token, context) do
    timer_definition = flow_node.type_data.event_definition
    cancel_activity = flow_node.type_data.cancel_activity
    host_fni_id = context.host_flow_node_instance_id

    case extract_timer_spec(timer_definition) do
      {:ok, :cycle, spec_string} ->
        handle_cycle_boundary(
          flow_node,
          token,
          context,
          spec_string,
          cancel_activity,
          host_fni_id
        )

      {:ok, kind, spec_string} ->
        schedule_and_wait(
          flow_node,
          token,
          context,
          kind,
          spec_string,
          cancel_activity,
          host_fni_id
        )

      {:error, _reason} = error ->
        error
    end
  end

  @impl true
  def handle_fatal(entry) do
    _cancel_result = cancel_timer_from_entry(entry)
    :ok
  end

  @impl true
  def handle_aborted(entry) do
    _cancel_result = cancel_timer_from_entry(entry)
    :ok
  end

  # -------------------------------------------------------------------
  # Resume
  # -------------------------------------------------------------------

  @doc """
  Resume a timer boundary FNI from persisted state.

  Reads `fire_at` from the FNI's `type_properties`:

  - **Future**: re-schedules the timer, blocks until it fires
  - **Past**: immediately fires the boundary result (timer should
    have fired while the engine was down)

  Non-interrupting cycles (`is_cycle: true`) restore the cycle receive
  loop, including remaining repetitions persisted after each re-arm.
  """
  @spec handle_resume(FlowNode.t(), map(), HandlerContext.t()) ::
          {:boundary, String.t(), term(), boolean()} | {:error, term()}
  def handle_resume(flow_node, entry, context) do
    type_props = entry.type_properties || %{}
    cancel_activity = resolve_cancel_activity(type_props, flow_node)

    if cycle_resume?(type_props) do
      resume_cycle_boundary(flow_node, context, type_props, cancel_activity)
    else
      resume_one_shot_boundary(flow_node, context, type_props, cancel_activity)
    end
  end

  # -------------------------------------------------------------------
  # Private: initial enter flow
  # -------------------------------------------------------------------

  defp schedule_and_wait(
         flow_node,
         token,
         context,
         kind,
         spec_string,
         cancel_activity,
         host_fni_id
       ) do
    reference_time = DateTime.utc_now()

    case resolve_timer_spec(kind, spec_string, token.payload, context, reference_time) do
      {:ok, fire_at} ->
        do_schedule_and_wait(flow_node, context, fire_at, cancel_activity, host_fni_id)

      {:error, reason} ->
        {:error, %{reason: :timer_resolution_failed, detail: reason}}
    end
  end

  defp do_schedule_and_wait(flow_node, context, fire_at, cancel_activity, host_fni_id) do
    {:ok, timer_ref} = schedule_timer(flow_node, context, fire_at)

    type_properties = %{
      host_flow_node_instance_id: host_fni_id,
      fire_at: DateTime.to_iso8601(fire_at),
      cancel_activity: cancel_activity,
      timer_ref: timer_ref
    }

    case FniLifecycle.park_async(context, type_properties) do
      :ok ->
        continuation = fn ->
          receive do
            {:timer_fired, ^timer_ref, _metadata} ->
              emit_timer_fired_event(context, flow_node, timer_ref)
              {:boundary, flow_node.id, %{}, cancel_activity}
          end
        end

        {:async, context.flow_node_instance_id, continuation,
         Map.put(type_properties, :persisted, true)}

      {:error, :persistence_failed} ->
        {:error, :persistence_failed}
    end
  end

  # -------------------------------------------------------------------
  # Private: cycle boundary flow
  # -------------------------------------------------------------------

  defp handle_cycle_boundary(flow_node, token, context, spec_string, cancel_activity, host_fni_id) do
    reference_time = DateTime.utc_now()
    feel_context = FeelContext.from_handler_context(context, token.payload)

    resolved_spec =
      case try_feel_evaluation(spec_string, feel_context) do
        {:ok, resolved} when is_binary(resolved) -> resolved
        _ -> spec_string
      end

    case ISO8601.resolve_fire_at(:cycle, resolved_spec, reference_time) do
      {:ok, {:cycle, cycle_spec}} ->
        first_fire = ISO8601.first_fire_at(cycle_spec, reference_time)

        if cancel_activity do
          do_schedule_and_wait(flow_node, context, first_fire, cancel_activity, host_fni_id)
        else
          do_schedule_cycle_loop(
            flow_node,
            context,
            first_fire,
            cycle_spec,
            cancel_activity,
            host_fni_id
          )
        end

      {:error, reason} ->
        {:error, %{reason: :timer_resolution_failed, detail: reason}}
    end
  end

  defp do_schedule_cycle_loop(
         flow_node,
         context,
         first_fire,
         cycle_spec,
         cancel_activity,
         host_fni_id
       ) do
    {:ok, timer_ref} = schedule_timer(flow_node, context, first_fire)

    type_properties =
      cycle_type_properties(host_fni_id, first_fire, cancel_activity, timer_ref, cycle_spec)

    case FniLifecycle.park_async(context, type_properties) do
      :ok ->
        process_instance_pid = context.process_instance_pid
        flow_node_instance_id = context.flow_node_instance_id

        continuation = fn ->
          cycle_receive_loop(
            process_instance_pid,
            flow_node_instance_id,
            flow_node,
            context,
            cancel_activity,
            timer_ref,
            first_fire,
            cycle_spec
          )
        end

        {:async, flow_node_instance_id, continuation, Map.put(type_properties, :persisted, true)}

      {:error, :persistence_failed} ->
        {:error, :persistence_failed}
    end
  end

  defp cycle_receive_loop(
         process_instance_pid,
         flow_node_instance_id,
         flow_node,
         context,
         cancel_activity,
         timer_ref,
         current_fire,
         cycle_spec
       ) do
    receive do
      {:timer_fired, ^timer_ref, _metadata} ->
        emit_timer_fired_event(context, flow_node, timer_ref)

        case ISO8601.next_cycle_fire(cycle_spec, current_fire) do
          {next_fire, updated_spec} ->
            send(
              process_instance_pid,
              {:fni_result, flow_node_instance_id,
               {:boundary_cycle_fire, flow_node.id, %{}, cancel_activity}}
            )

            {:ok, next_timer_ref} = schedule_timer(flow_node, context, next_fire)

            rearm_type_properties =
              cycle_type_properties(
                context.host_flow_node_instance_id,
                next_fire,
                cancel_activity,
                next_timer_ref,
                updated_spec
              )

            case persist_cycle_type_properties(context, rearm_type_properties) do
              :ok ->
                cycle_receive_loop(
                  process_instance_pid,
                  flow_node_instance_id,
                  flow_node,
                  context,
                  cancel_activity,
                  next_timer_ref,
                  next_fire,
                  updated_spec
                )

              {:error, :persistence_failed} ->
                _cancel_result = Scheduler.cancel(next_timer_ref)
                {:error, :persistence_failed}
            end

          nil ->
            {:boundary, flow_node.id, %{}, cancel_activity}
        end
    end
  end

  # -------------------------------------------------------------------
  # Private: resume flow
  # -------------------------------------------------------------------

  defp resume_one_shot_boundary(flow_node, context, type_props, cancel_activity) do
    fire_at_string = Map.get(type_props, :fire_at) || Map.get(type_props, "fire_at")

    case parse_persisted_fire_at(fire_at_string) do
      {:ok, fire_at} ->
        now = DateTime.utc_now()

        if DateTime.compare(fire_at, now) == :gt do
          resume_schedule_and_wait(flow_node, context, fire_at, cancel_activity)
        else
          resume_immediate_fire(flow_node, context, cancel_activity)
        end

      {:error, reason} ->
        {:error, %{reason: :resume_timer_failed, detail: reason}}
    end
  end

  defp resume_cycle_boundary(flow_node, context, type_props, cancel_activity) do
    fire_at_string = Map.get(type_props, :fire_at) || Map.get(type_props, "fire_at")

    with {:ok, fire_at} <- parse_persisted_fire_at(fire_at_string),
         {:ok, cycle_spec} <- parse_persisted_cycle_spec(type_props) do
      if DateTime.compare(fire_at, DateTime.utc_now()) == :gt do
        resume_cycle_schedule_and_wait(flow_node, context, fire_at, cycle_spec, cancel_activity)
      else
        deliver_due_cycle_tick(flow_node, context, fire_at, cycle_spec, cancel_activity)
      end
    else
      {:error, reason} ->
        {:error, %{reason: :resume_timer_failed, detail: reason}}
    end
  end

  defp resume_cycle_schedule_and_wait(flow_node, context, fire_at, cycle_spec, cancel_activity) do
    {:ok, timer_ref} = schedule_timer(flow_node, context, fire_at)

    cycle_receive_loop(
      context.process_instance_pid,
      context.flow_node_instance_id,
      flow_node,
      context,
      cancel_activity,
      timer_ref,
      fire_at,
      cycle_spec
    )
  end

  defp deliver_due_cycle_tick(flow_node, context, fire_at, cycle_spec, cancel_activity) do
    emit_timer_fired_event(context, flow_node, nil)

    case ISO8601.next_cycle_fire(cycle_spec, fire_at) do
      {next_fire, updated_spec} ->
        send(
          context.process_instance_pid,
          {:fni_result, context.flow_node_instance_id,
           {:boundary_cycle_fire, flow_node.id, %{}, cancel_activity}}
        )

        resume_cycle_schedule_and_wait(
          flow_node,
          context,
          next_fire,
          updated_spec,
          cancel_activity
        )

      nil ->
        {:boundary, flow_node.id, %{}, cancel_activity}
    end
  end

  defp resume_schedule_and_wait(flow_node, context, fire_at, cancel_activity) do
    {:ok, timer_ref} = schedule_timer(flow_node, context, fire_at)

    receive do
      {:timer_fired, ^timer_ref, _metadata} ->
        emit_timer_fired_event(context, flow_node, timer_ref)
        {:boundary, flow_node.id, %{}, cancel_activity}
    end
  end

  defp resume_immediate_fire(flow_node, context, cancel_activity) do
    emit_timer_fired_event(context, flow_node, nil)
    {:boundary, flow_node.id, %{}, cancel_activity}
  end

  # -------------------------------------------------------------------
  # Private: Scheduler interaction
  # -------------------------------------------------------------------

  defp schedule_timer(flow_node, context, fire_at) do
    Scheduler.schedule(%{
      fire_at: fire_at,
      target: self(),
      metadata: %{
        kind: :boundary,
        process_instance_id: context.process_instance_id,
        flow_node_instance_id: context.flow_node_instance_id,
        flow_node_id: flow_node.id
      }
    })
  end

  defp cancel_timer_from_entry(entry) do
    handler_pid = Map.get(entry, :pid)

    if is_pid(handler_pid) do
      Scheduler.cancel_all_for_target(handler_pid)
    else
      type_props = entry.type_properties || %{}

      timer_ref =
        Map.get(type_props, :timer_ref) || Map.get(type_props, "timer_ref")

      if timer_ref, do: _cancel_result = Scheduler.cancel(timer_ref)
    end
  end

  # -------------------------------------------------------------------
  # Private: event emission
  # -------------------------------------------------------------------

  defp emit_timer_fired_event(context, flow_node, timer_ref) do
    EngineEventBus.publish(%Event.TimerFired{
      timer_ref: timer_ref || "",
      process_instance_id: context.process_instance_id,
      flow_node_instance_id: context.flow_node_instance_id,
      flow_node_id: flow_node.id,
      kind: :boundary,
      root_process_instance_id: context.root_process_instance_id,
      lane_name: Helpers.resolve_lane_name_from_context(context, flow_node),
      occurred_at: DateTime.utc_now()
    })
  end

  # -------------------------------------------------------------------
  # Private: timer spec extraction
  # -------------------------------------------------------------------

  defp extract_timer_spec(%{time_date: date})
       when is_binary(date) and date != "" do
    {:ok, :date, date}
  end

  defp extract_timer_spec(%{time_duration: duration})
       when is_binary(duration) and duration != "" do
    {:ok, :duration, duration}
  end

  defp extract_timer_spec(%{time_cycle: cycle})
       when is_binary(cycle) and cycle != "" do
    {:ok, :cycle, cycle}
  end

  defp extract_timer_spec(_definition) do
    {:error,
     %{
       reason: :missing_timer_spec,
       detail: "timer event definition has no time_date, time_duration, or time_cycle"
     }}
  end

  # -------------------------------------------------------------------
  # Private: timer spec resolution
  # -------------------------------------------------------------------

  @doc false
  @spec resolve_timer_spec(
          :date | :duration | :cycle,
          String.t(),
          map(),
          HandlerContext.t(),
          DateTime.t()
        ) :: {:ok, DateTime.t()} | {:ok, {:cycle, ISO8601.cycle_spec()}} | {:error, term()}
  def resolve_timer_spec(kind, spec_string, token_payload, context, reference_time) do
    feel_context = FeelContext.from_handler_context(context, token_payload)

    case try_feel_evaluation(spec_string, feel_context) do
      {:ok, %DateTime{} = datetime} ->
        {:ok, datetime}

      {:ok, resolved_string} when is_binary(resolved_string) ->
        ISO8601.resolve_fire_at(kind, resolved_string, reference_time)

      _feel_failed ->
        ISO8601.resolve_fire_at(kind, spec_string, reference_time)
    end
  end

  # -------------------------------------------------------------------
  # Private: helpers
  # -------------------------------------------------------------------

  defp try_feel_evaluation(spec_string, feel_context) do
    Expressions.eval(spec_string, feel_context)
  rescue
    _exception -> {:error, :feel_not_applicable}
  end

  defp parse_persisted_fire_at(nil), do: {:error, :no_fire_at}

  defp parse_persisted_fire_at(fire_at_string) when is_binary(fire_at_string) do
    case DateTime.from_iso8601(fire_at_string) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_persisted_fire_at(%DateTime{} = datetime), do: {:ok, datetime}
  defp parse_persisted_fire_at(_other), do: {:error, :invalid_fire_at}

  defp cycle_resume?(type_props) do
    value = Map.get(type_props, :is_cycle) || Map.get(type_props, "is_cycle")
    value == true or value == "true"
  end

  defp cycle_type_properties(host_fni_id, fire_at, cancel_activity, timer_ref, cycle_spec) do
    %{
      host_flow_node_instance_id: host_fni_id,
      fire_at: DateTime.to_iso8601(fire_at),
      cancel_activity: cancel_activity,
      timer_ref: timer_ref,
      is_cycle: true,
      cycle_repetitions: encode_cycle_repetitions(cycle_spec.repetitions),
      cycle_interval: Duration.to_iso8601(cycle_spec.interval_duration)
    }
  end

  defp persist_cycle_type_properties(context, type_properties) do
    case FniLifecycle.park_async(context, type_properties) do
      :ok ->
        send(
          context.process_instance_pid,
          {:fni_merge_type_properties, context.flow_node_instance_id, type_properties}
        )

        :ok

      {:error, :persistence_failed} = error ->
        error
    end
  end

  defp parse_persisted_cycle_spec(type_props) do
    repetitions =
      Map.get(type_props, :cycle_repetitions) || Map.get(type_props, "cycle_repetitions")

    interval = Map.get(type_props, :cycle_interval) || Map.get(type_props, "cycle_interval")

    with {:ok, decoded_repetitions} <- decode_cycle_repetitions(repetitions),
         {:ok, duration} <- parse_cycle_interval(interval) do
      {:ok, %{repetitions: decoded_repetitions, interval_duration: duration, start_at: nil}}
    end
  end

  defp parse_cycle_interval(interval) when is_binary(interval) do
    Duration.from_iso8601(interval)
  end

  defp parse_cycle_interval(_interval), do: {:error, :invalid_cycle_interval}

  defp encode_cycle_repetitions(:infinite), do: "infinite"
  defp encode_cycle_repetitions(count) when is_integer(count), do: count

  defp decode_cycle_repetitions("infinite"), do: {:ok, :infinite}
  defp decode_cycle_repetitions(:infinite), do: {:ok, :infinite}
  defp decode_cycle_repetitions(count) when is_integer(count) and count >= 1, do: {:ok, count}

  defp decode_cycle_repetitions(count) when is_binary(count) do
    case Integer.parse(count) do
      {parsed, ""} when parsed >= 1 -> {:ok, parsed}
      _ -> {:error, :invalid_cycle_repetitions}
    end
  end

  defp decode_cycle_repetitions(_other), do: {:error, :invalid_cycle_repetitions}

  defp resolve_cancel_activity(type_props, flow_node) do
    case Map.get(type_props, :cancel_activity) || Map.get(type_props, "cancel_activity") do
      nil -> flow_node.type_data.cancel_activity
      value -> value
    end
  end
end

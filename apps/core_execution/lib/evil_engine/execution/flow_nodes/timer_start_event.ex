defmodule EvilEngine.Execution.FlowNodes.TimerStartEvent do
  @moduledoc """
  Handler for `<bpmn:startEvent>` with a Timer event definition.

  Timer Start Events have three kinds with fundamentally different
  semantics:

  - **`timeCycle`** — Auto-scheduled at deploy time by `StartEventManager`.
    When the Scheduler fires, `TimerStartListener` creates a new PI.
    The handler itself is a pass-through (the timer already did its
    job before the PI existed).

  - **`timeDate`** — Blocking gate. The PI is started manually. The
    handler computes the target datetime and blocks (via the Scheduler)
    until that datetime is reached, then completes. If the datetime is
    already in the past, the handler completes immediately.

  - **`timeDuration`** — Blocking delay. The PI is started manually.
    The handler computes `now + duration` and blocks until then.

  The blocking pattern for `timeDate` / `timeDuration` follows the same
  `{:async, fni_id, continuation_fn, type_properties}` shape used by
  `TimerCatchEvent`.

  ## Lifecycle callbacks

  - `handle_fatal/1` / `handle_aborted/1`: cancel the armed timer in
    the Scheduler (only relevant for date/duration; cycle is a no-op
    since the handler is a pass-through).
  """

  @behaviour EvilEngine.Execution.FlowNodeHandler

  alias EvilEngine.BPMN.Model.FlowNode
  alias EvilEngine.Events.EngineEventBus
  alias EvilEngine.Execution.FlowNodeResult
  alias EvilEngine.Execution.FniLifecycle
  alias EvilEngine.Execution.HandlerContext
  alias EvilEngine.Execution.SequenceFlowResolver
  alias EvilEngine.Expressions
  alias EvilEngine.Expressions.Context, as: FeelContext
  alias EvilEngine.Timers.ISO8601
  alias EvilEngine.Timers.Scheduler
  alias EvilEngine.Types.Event
  alias EvilEngine.Types.Token

  @spec handle_enter(FlowNode.t(), Token.t(), HandlerContext.t()) ::
          {:ok, FlowNodeResult.t()}
          | {:async, String.t(), (-> term()), map()}
          | {:error, term()}
  @impl true
  def handle_enter(flow_node, token, context) do
    timer_definition = flow_node.type_data.event_definition

    case classify_timer(timer_definition) do
      :cycle ->
        handle_cycle_passthrough(flow_node, token, context)

      {:blocking, kind, spec_string} ->
        schedule_and_wait(flow_node, token, context, kind, spec_string)
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
  # Resume (called by PI during reactivation)
  # -------------------------------------------------------------------

  @spec handle_resume(FlowNode.t(), map(), HandlerContext.t()) ::
          {:ok, FlowNodeResult.t()} | {:error, term()}
  def handle_resume(flow_node, entry, context) do
    type_props = entry.type_properties || %{}

    fire_at_string =
      Map.get(type_props, :fire_at) || Map.get(type_props, "fire_at")

    case parse_persisted_fire_at(fire_at_string) do
      {:ok, fire_at} ->
        now = DateTime.utc_now()

        if DateTime.compare(fire_at, now) == :gt do
          resume_schedule_and_wait(flow_node, entry, context, fire_at)
        else
          resume_immediate_complete(flow_node, entry, context)
        end

      {:error, reason} ->
        {:error, %{reason: :resume_timer_failed, detail: reason}}
    end
  end

  # -------------------------------------------------------------------
  # Cycle: pass-through (PI was auto-created by TimerStartListener)
  # -------------------------------------------------------------------

  defp handle_cycle_passthrough(flow_node, token, context) do
    with {:ok, next_ids} <- resolve_outgoing(flow_node, context),
         {:ok, lifecycle_result} <- FniLifecycle.finish(context, flow_node, token.payload, %{}) do
      {:ok,
       %FlowNodeResult{
         output_payload: token.payload,
         next_flow_node_ids: next_ids,
         metadata: %{persisted: true, lifecycle: lifecycle_result}
       }}
    end
  end

  # -------------------------------------------------------------------
  # Date / Duration: schedule and block
  # -------------------------------------------------------------------

  defp schedule_and_wait(flow_node, token, context, kind, spec_string) do
    reference_time = DateTime.utc_now()

    case resolve_timer_spec(kind, spec_string, token.payload, context, reference_time) do
      {:ok, fire_at} ->
        now = DateTime.utc_now()

        if DateTime.compare(fire_at, now) in [:lt, :eq] do
          handle_immediate_complete(flow_node, token, context)
        else
          do_schedule_and_wait(flow_node, token, context, fire_at)
        end

      {:error, reason} ->
        {:error, %{reason: :timer_resolution_failed, detail: reason}}
    end
  end

  defp handle_immediate_complete(flow_node, token, context) do
    emit_timer_fired_event(context, flow_node, nil)

    with {:ok, next_ids} <- resolve_outgoing(flow_node, context),
         {:ok, lifecycle_result} <- FniLifecycle.finish(context, flow_node, token.payload, %{}) do
      {:ok,
       %FlowNodeResult{
         output_payload: token.payload,
         next_flow_node_ids: next_ids,
         metadata: %{persisted: true, lifecycle: lifecycle_result}
       }}
    end
  end

  defp do_schedule_and_wait(flow_node, token, context, fire_at) do
    {:ok, timer_ref} = schedule_timer(flow_node, context, fire_at)

    type_properties = %{
      timer_ref: timer_ref,
      fire_at: DateTime.to_iso8601(fire_at)
    }

    case FniLifecycle.park_async(context, type_properties) do
      :ok ->
        continuation = build_timer_continuation(flow_node, token, context, timer_ref)

        {:async, context.flow_node_instance_id, continuation,
         Map.put(type_properties, :persisted, true)}

      {:error, :persistence_failed} ->
        {:error, :persistence_failed}
    end
  end

  defp build_timer_continuation(flow_node, token, context, timer_ref) do
    fn ->
      receive do
        {:timer_fired, ^timer_ref, _metadata} ->
          emit_timer_fired_event(context, flow_node, timer_ref)
          finish_after_timer(flow_node, token.payload, context)
      end
    end
  end

  defp finish_after_timer(flow_node, payload, context) do
    with {:ok, next_ids} <- resolve_outgoing(flow_node, context),
         {:ok, lifecycle_result} <- FniLifecycle.finish(context, flow_node, payload, %{}) do
      {:ok,
       %FlowNodeResult{
         output_payload: payload,
         next_flow_node_ids: next_ids,
         metadata: %{persisted: true, lifecycle: lifecycle_result}
       }}
    end
  end

  # -------------------------------------------------------------------
  # Resume helpers
  # -------------------------------------------------------------------

  defp resume_schedule_and_wait(flow_node, entry, context, fire_at) do
    {:ok, timer_ref} = schedule_timer(flow_node, context, fire_at)

    receive do
      {:timer_fired, ^timer_ref, _metadata} ->
        emit_timer_fired_event(context, flow_node, timer_ref)

        with {:ok, next_ids} <- resolve_outgoing(flow_node, context),
             {:ok, lifecycle_result} <-
               FniLifecycle.finish(context, flow_node, entry.token.payload, %{}) do
          {:ok,
           %FlowNodeResult{
             output_payload: entry.token.payload,
             next_flow_node_ids: next_ids,
             metadata: %{persisted: true, lifecycle: lifecycle_result}
           }}
        end
    end
  end

  defp resume_immediate_complete(flow_node, entry, context) do
    emit_timer_fired_event(context, flow_node, nil)

    with {:ok, next_ids} <- resolve_outgoing(flow_node, context),
         {:ok, lifecycle_result} <-
           FniLifecycle.finish(context, flow_node, entry.token.payload, %{}) do
      {:ok,
       %FlowNodeResult{
         output_payload: entry.token.payload,
         next_flow_node_ids: next_ids,
         metadata: %{persisted: true, lifecycle: lifecycle_result}
       }}
    end
  end

  # -------------------------------------------------------------------
  # Timer classification
  # -------------------------------------------------------------------

  defp classify_timer(%{time_cycle: cycle}) when is_binary(cycle) and cycle != "" do
    :cycle
  end

  defp classify_timer(%{time_date: date}) when is_binary(date) and date != "" do
    {:blocking, :date, date}
  end

  defp classify_timer(%{time_duration: duration})
       when is_binary(duration) and duration != "" do
    {:blocking, :duration, duration}
  end

  defp classify_timer(_definition) do
    {:blocking, :duration, "PT0S"}
  end

  # -------------------------------------------------------------------
  # Timer spec resolution
  # -------------------------------------------------------------------

  @doc false
  @spec resolve_timer_spec(
          :date | :duration,
          String.t(),
          map(),
          HandlerContext.t(),
          DateTime.t()
        ) :: {:ok, DateTime.t()} | {:error, term()}
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
  # Scheduler interaction
  # -------------------------------------------------------------------

  defp schedule_timer(flow_node, context, fire_at) do
    Scheduler.schedule(%{
      fire_at: fire_at,
      target: self(),
      metadata: %{
        kind: :timer_start,
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
  # Event emission
  # -------------------------------------------------------------------

  defp emit_timer_fired_event(context, flow_node, timer_ref) do
    EngineEventBus.publish(%Event.TimerFired{
      timer_ref: timer_ref || "",
      process_instance_id: context.process_instance_id,
      flow_node_instance_id: context.flow_node_instance_id,
      flow_node_id: flow_node.id,
      kind: :start,
      occurred_at: DateTime.utc_now()
    })
  end

  # -------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------

  defp try_feel_evaluation(spec_string, feel_context) do
    Expressions.eval(spec_string, feel_context)
  rescue
    _exception -> {:error, :feel_not_applicable}
  end

  defp resolve_outgoing(flow_node, context) do
    case SequenceFlowResolver.resolve(flow_node, context.process_model) do
      {:ok, targets} -> {:ok, Enum.map(targets, & &1.id)}
      {:error, reason, meta} -> {:error, Map.put(meta, :reason, reason)}
    end
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
end

defmodule BfwEngine.Execution.FlowNodes.TimerCatchEvent do
  @moduledoc """
  Handler for `<bpmn:intermediateCatchEvent>` with a Timer event definition.

  On enter, the handler:

  1. Extracts the timer spec from the event definition (exactly one of
     `time_date`, `time_duration`; `time_cycle` is rejected per the BPMN spec)
  2. Attempts FEEL evaluation — if the spec is a FEEL expression that
     evaluates to a DateTime or a string, use it; otherwise fall back
     to raw ISO 8601 parsing via `BfwEngine.Timers.ISO8601`
  3. Schedules the resolved fire time in the `Scheduler` with
     `target: self()` (the handler Task PID — NOT the PI PID)
  4. Returns `{:async, fni_id, continuation_fn, type_properties}` — the
     FNI parks in `:waiting` while the handler Task stays alive, blocked
     in a `receive` until the Scheduler delivers
     `{:timer_fired, timer_ref, metadata}`

  When the timer fires, the handler emits `Event.TimerFired`, resolves
  outgoing flows, and returns `{:ok, FlowNodeResult}` through the
  generic FNI result pipeline. The PI has zero timer-specific logic.

  ## Lifecycle callbacks

  - `handle_fatal/1` / `handle_aborted/1`: cancel the armed timer in
    the Scheduler. The handler Task is killed by the Task Supervisor
    when the PI terminates — process hierarchy cleanup is the safety net.
  - `handle_resume/3`: re-schedule a timer from persisted `fire_at` in
    `type_properties`. If the fire time is in the past, immediately
    complete. If in the future, block until the timer fires (same
    receive pattern as the initial enter).
  """

  @behaviour BfwEngine.Execution.FlowNodeHandler

  alias BfwEngine.BPMN.Model.FlowNode
  alias BfwEngine.Events.EngineEventBus
  alias BfwEngine.Execution.FlowNodeResult
  alias BfwEngine.Execution.FniLifecycle
  alias BfwEngine.Execution.HandlerContext
  alias BfwEngine.Execution.ProcessInstance.Helpers
  alias BfwEngine.Execution.SequenceFlowResolver
  alias BfwEngine.Expressions
  alias BfwEngine.Expressions.Context, as: FeelContext
  alias BfwEngine.Timers.ISO8601
  alias BfwEngine.Timers.Scheduler
  alias BfwEngine.Types.Event
  alias BfwEngine.Types.Token

  # -------------------------------------------------------------------
  # FlowNodeHandler callbacks
  # -------------------------------------------------------------------

  @spec handle_enter(FlowNode.t(), Token.t(), HandlerContext.t()) ::
          {:async, String.t(), (-> term()), map()} | {:error, term()}
  @impl true
  def handle_enter(flow_node, token, context) do
    timer_definition = flow_node.type_data.event_definition

    case extract_timer_spec(timer_definition) do
      {:ok, kind, spec_string} ->
        schedule_and_wait(flow_node, token, context, kind, spec_string)

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Cancel the armed timer when the PI fatals.

  The handler Task is killed by the Task Supervisor when the PI
  terminates; the Scheduler's PID monitor provides a second safety net.
  """
  @impl true
  def handle_fatal(entry) do
    _cancel_result = cancel_timer_from_entry(entry)
    :ok
  end

  @doc """
  Cancel the armed timer when the PI is aborted.
  """
  @impl true
  def handle_aborted(entry) do
    _cancel_result = cancel_timer_from_entry(entry)
    :ok
  end

  # -------------------------------------------------------------------
  # Resume (called by PI during reactivation, parallel to CallActivity)
  # -------------------------------------------------------------------

  @doc """
  Resume a timer catch FNI from persisted state.

  Reads `fire_at` from the FNI's `type_properties`:

  - **Future**: re-schedules the timer, blocks until it fires
  - **Past**: immediately completes (timer should have fired while
    the engine was down)

  Called inside a Task spawned by the PI — the return value is sent
  back as `{:fni_result, fni_id, result}`.
  """
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
  # Timer spec resolution (public for testing)
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
  # Private: initial enter flow
  # -------------------------------------------------------------------

  defp schedule_and_wait(flow_node, token, context, kind, spec_string) do
    reference_time = DateTime.utc_now()

    case resolve_timer_spec(kind, spec_string, token.payload, context, reference_time) do
      {:ok, fire_at} ->
        do_schedule_and_wait(flow_node, token, context, fire_at)

      {:error, reason} ->
        {:error, %{reason: :timer_resolution_failed, detail: reason}}
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
  # Private: resume flow
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
  # Private: Scheduler interaction
  # -------------------------------------------------------------------

  defp schedule_timer(flow_node, context, fire_at) do
    Scheduler.schedule(%{
      fire_at: fire_at,
      target: self(),
      metadata: %{
        kind: :catch,
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
      kind: :catch,
      root_process_instance_id: context.root_process_instance_id,
      lane_name: Helpers.resolve_lane_name_from_context(context, flow_node),
      occurred_at: DateTime.utc_now()
    })
  end

  # -------------------------------------------------------------------
  # Private: timer spec extraction
  # -------------------------------------------------------------------

  defp extract_timer_spec(%{time_date: date}) when is_binary(date) and date != "" do
    {:ok, :date, date}
  end

  defp extract_timer_spec(%{time_duration: duration})
       when is_binary(duration) and duration != "" do
    {:ok, :duration, duration}
  end

  defp extract_timer_spec(%{time_cycle: cycle}) when is_binary(cycle) and cycle != "" do
    {:error,
     %{
       reason: :unsupported_timer_type,
       detail: "time_cycle is not supported on intermediate catch events"
     }}
  end

  defp extract_timer_spec(_definition) do
    {:error,
     %{
       reason: :missing_timer_spec,
       detail: "timer event definition has no time_date or time_duration"
     }}
  end

  # -------------------------------------------------------------------
  # Private: helpers
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

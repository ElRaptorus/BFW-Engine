defmodule EvilEngine.Execution.FniLifecycle do
  @moduledoc """
  FNI state transition functions for handler-owned lifecycle.

  Handlers call `finish/4`, `transition_to_waiting/2`, and `park_async/2`
  during their execution. The PI calls `transition_to_fatal/7`,
  `transition_to_aborted/7`, `transition_to_error/7`,
  `transition_to_interrupted/7` for exceptional paths (crash fallback,
  cascade, error cascade, boundary interrupt).

  ## Persistence resilience

  All adapter calls are wrapped with `PersistenceRetry.with_retry/3`
  (bounded exponential backoff, default 5 attempts). On retry exhaustion:

  - `finish/4` — returns `{:error, {:persist_failed, reason}}`, which
    fatals the FNI at the PI level.
  - `transition_to_waiting/2`, `park_async/2` — return
    `{:error, :persistence_failed}`. Handlers propagate this back to
    the PI, which fatals the FNI and then itself.
  - `transition_to_fatal/4`, `transition_to_aborted/4`,
    `transition_to_interrupted/4` — return `{:error, :persistence_failed}`.
    The PI is typically already stopping when these are called; the return
    is available for escalation if needed.
  """

  require Logger

  alias EvilEngine.BPMN.Model.FlowNode
  alias EvilEngine.Events.EngineEventBus
  alias EvilEngine.Execution.DataObjectWriteIntent
  alias EvilEngine.Execution.DataObjectWriter
  alias EvilEngine.Execution.FniLifecycle.LifecycleResult
  alias EvilEngine.Execution.HandlerContext
  alias EvilEngine.Execution.PayloadCap
  alias EvilEngine.Execution.Persistence, as: PersistenceAdapter
  alias EvilEngine.Execution.PersistenceRetry
  alias EvilEngine.Execution.ProcessInstance.Helpers
  alias EvilEngine.Types.Event

  @fni_state_finished "finished"
  @fni_state_waiting "waiting"
  @fni_state_fatal "fatal"
  @fni_state_aborted "aborted"
  @fni_state_interrupted "interrupted"
  @fni_state_error "error"

  # -------------------------------------------------------------------
  # Handler-called (normal paths)
  # -------------------------------------------------------------------

  @doc """
  Finish an FNI: payload cap check, DOA evaluation, atomic persist, emit events.

  Called by handlers after they compute their output. Returns
  `{:ok, %LifecycleResult{}}` with cache updates the PI needs to apply,
  or `{:error, reason}` on payload cap or DOA evaluation failure.
  """
  @spec finish(HandlerContext.t(), FlowNode.t(), term(), map(), keyword()) ::
          {:ok, LifecycleResult.t()} | {:error, term()}
  def finish(context, flow_node, output_payload, type_properties, opts \\ []) do
    case PayloadCap.check(output_payload, field: :fni_output) do
      :ok ->
        do_finish(context, flow_node, output_payload, type_properties, opts)

      {:error, :payload_too_large, details} ->
        Logger.warning(
          "FNI #{context.flow_node_instance_id} output exceeds payload cap: #{inspect(details)}"
        )

        {:error, {:payload_too_large, details}}
    end
  end

  @doc """
  Finish an FNI with terminal state `:error` (Error End Event).

  Same pipeline as `finish/4` (payload cap, DOA, atomic persist, emit events)
  but persists the FNI as `"error"` instead of `"finished"`. The emitted
  `FlowNodeInstanceFinished` event carries `terminal_state: :error`.
  """
  @spec finish_as_error(HandlerContext.t(), FlowNode.t(), term(), map()) ::
          {:ok, LifecycleResult.t()} | {:error, term()}
  def finish_as_error(context, flow_node, output_payload, type_properties) do
    case PayloadCap.check(output_payload, field: :fni_output) do
      :ok ->
        do_finish_as_error(context, flow_node, output_payload, type_properties)

      {:error, :payload_too_large, details} ->
        Logger.warning(
          "FNI #{context.flow_node_instance_id} output exceeds payload cap: #{inspect(details)}"
        )

        {:error, {:payload_too_large, details}}
    end
  end

  @doc "Park FNI as waiting. Returns `{:error, :persistence_failed}` on retry exhaustion."
  @spec transition_to_waiting(HandlerContext.t(), map()) :: :ok | {:error, :persistence_failed}
  def transition_to_waiting(context, type_properties) do
    persist_fni_waiting(context.flow_node_instance_id, type_properties)
  end

  @doc """
  Park FNI as async-waiting. Returns `{:error, :persistence_failed}` on retry exhaustion.

  Only handles persistence. Registry registration remains with the PI
  because `Registry.register/3` must be called from the registering
  process itself (the PI), not from a spawned handler Task.
  """
  @spec park_async(HandlerContext.t(), map()) :: :ok | {:error, :persistence_failed}
  def park_async(context, type_properties) do
    merged_type_properties = Map.merge(%{async: true}, type_properties)
    persist_fni_waiting(context.flow_node_instance_id, merged_type_properties)
  end

  @doc """
  Park FNI as waiting by ID (no HandlerContext required).

  Called by the PI process for conditional events so that all DB writes
  happen from the PI's GenServer context, avoiding Ecto sandbox contention
  with concurrent handler Tasks.
  """
  @spec transition_to_waiting_by_id(String.t(), map()) :: :ok | {:error, :persistence_failed}
  def transition_to_waiting_by_id(flow_node_instance_id, type_properties) do
    persist_fni_waiting(flow_node_instance_id, type_properties)
  end

  # -------------------------------------------------------------------
  # PI-called (exceptional paths)
  # -------------------------------------------------------------------

  @doc """
  Transition FNI to fatal state. Called by PI for crash fallback and cascade.

  Returns `{:error, :persistence_failed}` if the persist fails after retry
  exhaustion, allowing the PI to escalate (force_fatal on itself).

  Accepts optional `flow_node` for complete event emission. Pass `nil` when
  flow_node info is unavailable (e.g., crash fallback before handler runs).

  `existing_type_properties` preserves handler-written metadata (e.g.
  `child_process_instance_id` on Call Activities) across the state transition.
  """
  @spec transition_to_fatal(
          String.t(),
          String.t(),
          term(),
          FlowNode.t() | nil,
          map(),
          String.t() | nil,
          String.t() | nil
        ) ::
          :ok | {:error, :persistence_failed}
  def transition_to_fatal(
        flow_node_instance_id,
        process_instance_id,
        reason,
        flow_node \\ nil,
        existing_type_properties \\ %{},
        lane_name \\ nil,
        root_process_instance_id \\ nil
      ) do
    error_info = Helpers.to_json_safe(normalize_error_info(reason))
    adapter = PersistenceAdapter.adapter()

    merged_type_properties =
      existing_type_properties
      |> Helpers.stringify_keys()
      |> Map.merge(%{"error" => true})

    result =
      PersistenceRetry.with_retry(
        fn ->
          adapter.update_flow_node_instance(flow_node_instance_id, :update_finished, %{
            state: @fni_state_fatal,
            finished_at: DateTime.utc_now(),
            error_info: error_info,
            type_properties: merged_type_properties
          })
        end,
        "FNI fatal #{flow_node_instance_id}"
      )

    case result do
      :ok ->
        emit_fni_finished(
          process_instance_id,
          flow_node_instance_id,
          flow_node,
          :fatal,
          merged_type_properties,
          error_info,
          lane_name: lane_name,
          root_process_instance_id: root_process_instance_id
        )

        :ok

      {:error, _} ->
        {:error, :persistence_failed}
    end
  end

  @doc """
  Transition FNI to aborted state. Called by PI for API abort and cascade.

  Returns `{:error, :persistence_failed}` if the persist fails after retry
  exhaustion, allowing the PI to escalate.

  Accepts optional `flow_node` for complete event emission.

  `existing_type_properties` preserves handler-written metadata across the
  state transition.
  """
  @spec transition_to_aborted(
          String.t(),
          String.t(),
          term(),
          FlowNode.t() | nil,
          map(),
          String.t() | nil,
          String.t() | nil
        ) ::
          :ok | {:error, :persistence_failed}
  def transition_to_aborted(
        flow_node_instance_id,
        process_instance_id,
        reason,
        flow_node \\ nil,
        existing_type_properties \\ %{},
        lane_name \\ nil,
        root_process_instance_id \\ nil
      ) do
    adapter = PersistenceAdapter.adapter()

    merged_type_properties =
      existing_type_properties
      |> Helpers.stringify_keys()
      |> Map.merge(Helpers.stringify_keys(%{aborted: true, reason: reason}))

    result =
      PersistenceRetry.with_retry(
        fn ->
          adapter.update_flow_node_instance(flow_node_instance_id, :update_finished, %{
            state: @fni_state_aborted,
            finished_at: DateTime.utc_now(),
            output_token: nil,
            type_properties: merged_type_properties
          })
        end,
        "FNI aborted #{flow_node_instance_id}"
      )

    case result do
      :ok ->
        emit_fni_finished(
          process_instance_id,
          flow_node_instance_id,
          flow_node,
          :aborted,
          %{},
          nil,
          lane_name: lane_name,
          root_process_instance_id: root_process_instance_id
        )

        :ok

      {:error, _} ->
        {:error, :persistence_failed}
    end
  end

  @doc """
  Transition FNI to error state. Called by PI for Error End Event cascade.

  When an Error End Event fires and the PI transitions to `:error`, all
  remaining active/waiting FNIs receive this transition — symmetric with
  `transition_to_fatal` (crash cascade) and `transition_to_aborted` (API
  abort cascade).

  Returns `{:error, :persistence_failed}` if the persist fails after retry
  exhaustion, allowing the PI to escalate.
  """
  @spec transition_to_error(
          String.t(),
          String.t(),
          term(),
          FlowNode.t() | nil,
          map(),
          String.t() | nil,
          String.t() | nil
        ) ::
          :ok | {:error, :persistence_failed}
  def transition_to_error(
        flow_node_instance_id,
        process_instance_id,
        reason,
        flow_node \\ nil,
        existing_type_properties \\ %{},
        lane_name \\ nil,
        root_process_instance_id \\ nil
      ) do
    error_info = Helpers.to_json_safe(normalize_error_info(reason))
    adapter = PersistenceAdapter.adapter()

    merged_type_properties =
      existing_type_properties
      |> Helpers.stringify_keys()
      |> Map.merge(%{"error" => true})

    result =
      PersistenceRetry.with_retry(
        fn ->
          adapter.update_flow_node_instance(flow_node_instance_id, :update_finished, %{
            state: @fni_state_error,
            finished_at: DateTime.utc_now(),
            error_info: error_info,
            type_properties: merged_type_properties
          })
        end,
        "FNI error #{flow_node_instance_id}"
      )

    case result do
      :ok ->
        emit_fni_finished(
          process_instance_id,
          flow_node_instance_id,
          flow_node,
          :error,
          merged_type_properties,
          error_info,
          lane_name: lane_name,
          root_process_instance_id: root_process_instance_id
        )

        :ok

      {:error, _} ->
        {:error, :persistence_failed}
    end
  end

  @doc """
  Transition FNI to interrupted state. Called by PI for boundary and terminate.

  Returns `{:error, :persistence_failed}` if the persist fails after retry
  exhaustion, allowing the PI to escalate.

  Accepts optional `flow_node` for complete event emission.

  `existing_type_properties` preserves handler-written metadata across the
  state transition.
  """
  @spec transition_to_interrupted(
          String.t(),
          String.t(),
          term(),
          FlowNode.t() | nil,
          map(),
          String.t() | nil,
          String.t() | nil
        ) ::
          :ok | {:error, :persistence_failed}
  def transition_to_interrupted(
        flow_node_instance_id,
        process_instance_id,
        reason,
        flow_node \\ nil,
        existing_type_properties \\ %{},
        lane_name \\ nil,
        root_process_instance_id \\ nil
      ) do
    adapter = PersistenceAdapter.adapter()

    merged_type_properties =
      existing_type_properties
      |> Helpers.stringify_keys()
      |> Map.merge(Helpers.stringify_keys(%{interrupted: true, reason: reason}))

    result =
      PersistenceRetry.with_retry(
        fn ->
          adapter.update_flow_node_instance(flow_node_instance_id, :update_finished, %{
            state: @fni_state_interrupted,
            finished_at: DateTime.utc_now(),
            output_token: nil,
            type_properties: merged_type_properties
          })
        end,
        "FNI interrupted #{flow_node_instance_id}"
      )

    case result do
      :ok ->
        emit_fni_finished(
          process_instance_id,
          flow_node_instance_id,
          flow_node,
          :interrupted,
          %{},
          nil,
          lane_name: lane_name,
          root_process_instance_id: root_process_instance_id
        )

        :ok

      {:error, _} ->
        {:error, :persistence_failed}
    end
  end

  # -------------------------------------------------------------------
  # Internal
  # -------------------------------------------------------------------

  defp do_finish(context, flow_node, output_payload, type_properties, opts) do
    prepare_result =
      DataObjectWriter.prepare_associations(
        flow_node,
        context.flow_node_instance_id,
        output_payload,
        context.data_objects,
        context.process_model,
        context
      )

    case prepare_result do
      {:ok, updated_cache, intents} ->
        persist_and_emit_finish(
          context,
          flow_node,
          output_payload,
          type_properties,
          updated_cache,
          intents,
          opts
        )

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    exception ->
      Logger.error(
        "FniLifecycle.finish crash for FNI #{context.flow_node_instance_id}: #{Exception.message(exception)}\n#{Exception.format_stacktrace(__STACKTRACE__)}"
      )

      {:error, {:lifecycle_crash, Exception.message(exception)}}
  end

  defp do_finish_as_error(context, flow_node, output_payload, type_properties) do
    prepare_result =
      DataObjectWriter.prepare_associations(
        flow_node,
        context.flow_node_instance_id,
        output_payload,
        context.data_objects,
        context.process_model,
        context
      )

    case prepare_result do
      {:ok, updated_cache, intents} ->
        persist_and_emit_finish_as_error(
          context,
          flow_node,
          output_payload,
          type_properties,
          updated_cache,
          intents
        )

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    exception ->
      Logger.error(
        "FniLifecycle.finish_as_error crash for FNI #{context.flow_node_instance_id}: #{Exception.message(exception)}\n#{Exception.format_stacktrace(__STACKTRACE__)}"
      )

      {:error, {:lifecycle_crash, Exception.message(exception)}}
  end

  defp persist_and_emit_finish_as_error(
         context,
         flow_node,
         output_payload,
         type_properties,
         updated_cache,
         intents
       ) do
    stringified_type_properties = Helpers.stringify_keys(type_properties)

    fni_changes = %{
      state: @fni_state_error,
      finished_at: DateTime.utc_now(),
      output_token: output_payload,
      type_properties: stringified_type_properties
    }

    adapter = PersistenceAdapter.adapter()

    case PersistenceRetry.with_retry(
           fn ->
             adapter.finish_fni_with_data_objects(
               context.flow_node_instance_id,
               fni_changes,
               intents
             )
           end,
           "FNI finish_as_error+DO atomic #{context.flow_node_instance_id}"
         ) do
      {:ok, %{writes: write_results}} ->
        lane_name = resolve_lane_name(context.process_model, flow_node)

        emit_data_object_written_events(
          context.process_instance_id,
          intents,
          write_results,
          context.root_process_instance_id,
          lane_name
        )

        emit_fni_finished(
          context.process_instance_id,
          context.flow_node_instance_id,
          flow_node,
          :error,
          stringified_type_properties,
          nil,
          lane_name: lane_name,
          root_process_instance_id: context.root_process_instance_id,
          multi_instance_id: context.multi_instance_id,
          iteration_index: context.iteration_index
        )

        cache_updates = Map.new(intents, fn intent -> {intent.data_object_id, intent.value} end)

        merged_updates =
          Map.merge(updated_cache_delta(context.data_objects, updated_cache), cache_updates)

        {:ok, %LifecycleResult{data_object_cache_updates: merged_updates}}

      {:error, reason} ->
        {:error, {:persist_failed, reason}}
    end
  end

  defp persist_and_emit_finish(
         context,
         flow_node,
         output_payload,
         type_properties,
         updated_cache,
         intents,
         opts
       ) do
    stringified_type_properties = Helpers.stringify_keys(type_properties)

    fni_changes = %{
      state: @fni_state_finished,
      finished_at: DateTime.utc_now(),
      output_token: output_payload,
      type_properties: stringified_type_properties
    }

    fni_changes =
      case Keyword.get(opts, :previous_flow_node_instance_ids) do
        ids when is_list(ids) and ids != [] ->
          Map.put(fni_changes, :previous_flow_node_instance_ids, ids)

        _ ->
          fni_changes
      end

    fni_changes =
      case Keyword.get(opts, :triggerer_flow_node_instance_id) do
        nil -> fni_changes
        triggerer_id -> Map.put(fni_changes, :triggerer_flow_node_instance_id, triggerer_id)
      end

    adapter = PersistenceAdapter.adapter()

    case PersistenceRetry.with_retry(
           fn ->
             adapter.finish_fni_with_data_objects(
               context.flow_node_instance_id,
               fni_changes,
               intents
             )
           end,
           "FNI finish+DO atomic #{context.flow_node_instance_id}"
         ) do
      {:ok, %{writes: write_results}} ->
        lane_name = resolve_lane_name(context.process_model, flow_node)

        emit_data_object_written_events(
          context.process_instance_id,
          intents,
          write_results,
          context.root_process_instance_id,
          lane_name
        )

        triggerer_fni_id = Keyword.get(opts, :triggerer_flow_node_instance_id)

        emit_fni_finished(
          context.process_instance_id,
          context.flow_node_instance_id,
          flow_node,
          :finished,
          stringified_type_properties,
          nil,
          lane_name: lane_name,
          root_process_instance_id: context.root_process_instance_id,
          triggerer_flow_node_instance_id: triggerer_fni_id,
          multi_instance_id: context.multi_instance_id,
          iteration_index: context.iteration_index
        )

        cache_updates = Map.new(intents, fn intent -> {intent.data_object_id, intent.value} end)

        merged_updates =
          Map.merge(updated_cache_delta(context.data_objects, updated_cache), cache_updates)

        {:ok, %LifecycleResult{data_object_cache_updates: merged_updates}}

      {:error, reason} ->
        {:error, {:persist_failed, reason}}
    end
  end

  defp updated_cache_delta(original_cache, updated_cache) do
    updated_cache
    |> Enum.reject(fn {key, value} -> Map.get(original_cache, key) == value end)
    |> Map.new()
  end

  defp persist_fni_waiting(flow_node_instance_id, type_properties) do
    adapter = PersistenceAdapter.adapter()

    case PersistenceRetry.with_retry(
           fn ->
             adapter.update_flow_node_instance(flow_node_instance_id, :update_waiting, %{
               state: @fni_state_waiting,
               type_properties: Helpers.stringify_keys(type_properties)
             })
           end,
           "FNI waiting #{flow_node_instance_id}"
         ) do
      :ok -> :ok
      {:error, _} -> {:error, :persistence_failed}
    end
  end

  defp emit_fni_finished(
         process_instance_id,
         flow_node_instance_id,
         flow_node,
         terminal_state,
         type_properties,
         error_info,
         emit_opts
       ) do
    lane_name = Keyword.get(emit_opts, :lane_name)
    root_process_instance_id = Keyword.get(emit_opts, :root_process_instance_id)
    triggerer_fni_id = Keyword.get(emit_opts, :triggerer_flow_node_instance_id)

    flow_node_id = if flow_node, do: flow_node.id
    flow_node_type = if flow_node, do: flow_node.type

    event_type =
      if flow_node do
        Helpers.extract_event_type(flow_node)
      end

    EngineEventBus.publish(%Event.FlowNodeInstanceFinished{
      flow_node_instance_id: flow_node_instance_id,
      process_instance_id: process_instance_id,
      root_process_instance_id: root_process_instance_id,
      flow_node_id: flow_node_id,
      flow_node_type: flow_node_type,
      event_type: event_type,
      lane_name: lane_name,
      terminal_state: terminal_state,
      triggerer_flow_node_instance_id: triggerer_fni_id,
      type_properties: type_properties,
      error_info: Helpers.sanitize_error_info(error_info),
      multi_instance_id: Keyword.get(emit_opts, :multi_instance_id),
      iteration_index: Keyword.get(emit_opts, :iteration_index),
      occurred_at: DateTime.utc_now()
    })

    :telemetry.execute(
      [:evil_engine, :flow_node_instance, :state_change],
      %{system_time: System.system_time()},
      %{
        flow_node_instance_id: flow_node_instance_id,
        process_instance_id: process_instance_id,
        flow_node_type: flow_node_type,
        terminal_state: terminal_state
      }
    )
  end

  defp emit_data_object_written_events(
         process_instance_id,
         intents,
         write_results,
         root_process_instance_id,
         lane_name
       ) do
    intents
    |> Enum.zip(write_results)
    |> Enum.each(fn {%DataObjectWriteIntent{} = intent, write_result} ->
      EngineEventBus.publish(%Event.DataObjectWritten{
        process_instance_id: process_instance_id,
        root_process_instance_id: root_process_instance_id,
        flow_node_instance_id: intent.flow_node_instance_id,
        data_object_id: intent.data_object_id,
        write_id: write_result.write_id,
        previous_value: intent.previous_value,
        value: intent.value,
        created_at: write_result.created_at,
        lane_name: lane_name
      })
    end)
  end

  defp resolve_lane_name(nil, _flow_node), do: nil

  defp resolve_lane_name(process_model, flow_node),
    do: Helpers.resolve_lane_name(process_model, flow_node)

  defp normalize_error_info(%{"error_code" => _, "message" => _} = already_normalized),
    do: already_normalized

  defp normalize_error_info(reason), do: Helpers.build_error_info(reason)
end

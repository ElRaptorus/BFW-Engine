defmodule EvilEngine.Execution.ResumeRunner do
  @moduledoc """
  One-shot boot-time task that resumes all root-level `running` process instances.

  Only process instances without a `parent_process_instance_id` are resumed
  directly. Child PIs (spawned by Call Activities) are re-attached or
  re-spawned by their parent's Call Activity handler during resume — resuming
  them independently would cause duplicate execution.

  Reads persisted PI/FNI data via the configured persistence adapter and
  starts each PI under the `DynamicSupervisor` with `resume: true`.

  Emits `Event.EngineStarted` after all PIs have been resumed.
  """

  require Logger

  alias EvilEngine.Events.EngineEventBus
  alias EvilEngine.Events.MessageSubscriptions
  alias EvilEngine.Events.SignalSubscriptions
  alias EvilEngine.Execution.Persistence
  alias EvilEngine.Execution.PersistenceRetry
  alias EvilEngine.Types.Event

  @doc """
  Resume all running process instances from the persistence layer.

  Called as a one-shot `Task` from the `core_execution` application
  supervisor at boot. Drives the persistence adapter's paginated
  `list_running_process_instances/1` callback in a tail-recursive loop
  until the cursor is exhausted, processing one batch at a time. Peak
  memory is bounded by `EVIL_RESUME_BATCH_SIZE` (default `1000`)
  multiplied by per-PI row size.

  Returns `{:ok, count}` with the number of successfully resumed PIs.
  Mid-stream DB errors log the cursor and report the count resumed
  before the failure.
  """
  @spec resume_all() :: {:ok, non_neg_integer()}
  def resume_all do
    adapter = Persistence.adapter()

    cleanup_orphans(adapter)

    batch_size = batch_size()

    count = resume_batches(adapter, batch_size, nil, 0, 0)
    MessageSubscriptions.mark_ready()
    SignalSubscriptions.mark_ready()
    emit_engine_started()
    maybe_publish_resume_overload()
    {:ok, count}
  rescue
    error ->
      Logger.error("ResumeRunner: unexpected error during resume: #{Exception.message(error)}")

      MessageSubscriptions.mark_ready()
      SignalSubscriptions.mark_ready()
      emit_engine_started()
      maybe_publish_resume_overload()
      {:ok, 0}
  end

  defp cleanup_orphans(adapter) do
    case PersistenceRetry.with_retry(
           fn -> adapter.cleanup_orphaned_flow_node_instances() end,
           "Resume: cleanup orphaned FNIs",
           max_attempts: 3
         ) do
      {:ok, 0} -> :ok
      {:ok, count} -> Logger.warning("Startup cleanup: aborted #{count} orphaned FNIs")
      {:error, reason} -> Logger.error("Startup cleanup: FNI sweep failed: #{inspect(reason)}")
    end

    case PersistenceRetry.with_retry(
           fn -> adapter.cleanup_orphaned_process_instances() end,
           "Resume: cleanup orphaned PIs",
           max_attempts: 3
         ) do
      {:ok, 0} -> :ok
      {:ok, count} -> Logger.warning("Startup cleanup: aborted #{count} orphaned child PIs")
      {:error, reason} -> Logger.error("Startup cleanup: PI sweep failed: #{inspect(reason)}")
    end
  end

  defp batch_size do
    Application.get_env(:core_execution, :resume_batch_size, 1000)
  end

  defp resume_batches(adapter, batch_size, cursor, resumed_acc, total_acc) do
    case PersistenceRetry.with_retry(
           fn -> adapter.list_running_process_instances(limit: batch_size, after: cursor) end,
           "Resume: list running PIs (cursor=#{inspect(cursor)})",
           max_attempts: 3
         ) do
      {:ok, %{records: records, next_cursor: next_cursor}} ->
        resumed_in_batch = Enum.count(records, &(resume_one(adapter, &1) == :ok))
        new_resumed = resumed_acc + resumed_in_batch
        new_total = total_acc + length(records)

        case next_cursor do
          nil ->
            Logger.info("ResumeRunner: resumed #{new_resumed}/#{new_total} process instances")
            new_resumed

          _ ->
            resume_batches(adapter, batch_size, next_cursor, new_resumed, new_total)
        end

      {:error, reason} ->
        Logger.error(
          "ResumeRunner: failed batch read at cursor=#{inspect(cursor)}: #{inspect(reason)}"
        )

        Logger.info("ResumeRunner: resumed #{resumed_acc}/#{total_acc} before error")
        resumed_acc
    end
  end

  defp resume_one(adapter, process_instance) do
    with {:ok, flow_node_instances} <-
           PersistenceRetry.with_retry(
             fn -> adapter.list_flow_node_instances(process_instance.id) end,
             "Resume: list FNIs for PI #{process_instance.id}",
             max_attempts: 3
           ),
         {:ok, pending_arrivals} <-
           PersistenceRetry.with_retry(
             fn -> adapter.list_gateway_pending_arrivals(process_instance.id) end,
             "Resume: list pending arrivals for PI #{process_instance.id}",
             max_attempts: 3
           ) do
        opts = %{
          resume: true,
          process_instance_id: process_instance.id,
          process_version_id: process_instance.process_version_id,
          business_key: process_instance[:business_key],
          parent_process_instance_id: process_instance[:parent_process_instance_id],
          triggerer_flow_node_instance_id: process_instance[:triggerer_flow_node_instance_id],
          started_at: process_instance[:started_at],
          started_by: process_instance[:started_by],
          started_with_context: process_instance[:started_with_context],
          fni_data: flow_node_instances,
          pending_arrivals: pending_arrivals
        }

        case DynamicSupervisor.start_child(
               EvilEngine.Execution.Supervisor,
               {EvilEngine.Execution.ProcessInstance, opts}
             ) do
          {:ok, _pid} ->
            :ok

          {:error, reason} ->
            Logger.error(
              "ResumeRunner: failed to start PI #{process_instance.id}: #{inspect(reason)}"
            )

            :error
        end
    else
      {:error, reason} ->
        Logger.error(
          "ResumeRunner: failed to load data for PI #{process_instance.id}: #{inspect(reason)}"
        )

        :error
    end
  end

  defp emit_engine_started do
    EngineEventBus.publish(%Event.EngineStarted{
      engine_id: engine_id(),
      engine_name: "ThomasTheDaemonEngine",
      version: Application.spec(:core_execution, :vsn) |> to_string(),
      started_at: DateTime.utc_now()
    })
  end

  # Resume bypasses EVIL_MAX_CONCURRENT_PIS so PI trees come back whole.
  # When that leaves the engine over the configured cap, emit EngineOverloaded
  # so operators see the oversubscription. Remaining resumes are never refused.
  defp maybe_publish_resume_overload do
    case EvilEngine.Execution.configured_limit() do
      :infinity ->
        :ok

      limit when is_integer(limit) and limit >= 0 ->
        active = EvilEngine.Execution.count_active()

        if active > limit do
          EngineEventBus.publish(%Event.EngineOverloaded{
            level: resume_overload_level(active, limit),
            active_process_instances: active,
            limit: limit,
            occurred_at: DateTime.utc_now()
          })
        else
          :ok
        end
    end
  end

  defp resume_overload_level(active, limit) when limit > 0 do
    if active / limit >= 0.9 do
      :critical
    else
      :elevated
    end
  end

  defp resume_overload_level(_active, _limit), do: :critical

  defp engine_id do
    Application.get_env(:core_execution, :engine_id, "default")
  end
end

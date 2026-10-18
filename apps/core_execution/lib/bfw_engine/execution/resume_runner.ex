defmodule BfwEngine.Execution.ResumeRunner do
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

  alias BfwEngine.Events.EngineEventBus
  alias BfwEngine.Events.MessageSubscriptions
  alias BfwEngine.Events.SignalSubscriptions
  alias BfwEngine.Execution.Persistence
  alias BfwEngine.Execution.PersistenceRetry
  alias BfwEngine.Execution.ProcessInstance
  alias BfwEngine.Types.Event

  @resume_settle_timeout_ms 30_000

  @doc """
  Resume all running process instances from the persistence layer.

  Called as a one-shot `Task` from the `core_execution` application
  supervisor at boot. Drives the persistence adapter's paginated
  `list_running_process_instances/1` callback in a tail-recursive loop
  until the cursor is exhausted, processing one batch at a time. Peak
  memory is bounded by `BFE_RESUME_BATCH_SIZE` (default `1000`)
  multiplied by per-PI row size.

  Returns `{:ok, count}` with the number of successfully resumed PIs.
  Mid-stream DB errors log the cursor and report the count resumed
  before the failure.
  """
  @spec resume_all() :: {:ok, non_neg_integer()}
  def resume_all do
    # Readiness outlives an application restart in the same node; only this
    # run may set it again.
    :ok = MessageSubscriptions.mark_not_ready()
    :ok = SignalSubscriptions.mark_not_ready()
    adapter = Persistence.adapter()

    cleanup_orphans(adapter)

    batch_size = batch_size()

    count = resume_batches(adapter, batch_size, nil, 0, 0)
    await_resume_settled(%{})
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

  # The PI sweep runs first: the FNI sweep keeps compensation handlers whose
  # anchoring instance is not terminal, so orphaned anchors must be aborted
  # before it.
  defp cleanup_orphans(adapter) do
    case PersistenceRetry.with_retry(
           fn -> adapter.cleanup_orphaned_process_instances() end,
           "Resume: cleanup orphaned PIs",
           max_attempts: 3
         ) do
      {:ok, 0} -> :ok
      {:ok, count} -> Logger.warning("Startup cleanup: aborted #{count} orphaned child PIs")
      {:error, reason} -> Logger.error("Startup cleanup: PI sweep failed: #{inspect(reason)}")
    end

    case PersistenceRetry.with_retry(
           fn -> adapter.cleanup_orphaned_flow_node_instances() end,
           "Resume: cleanup orphaned FNIs",
           max_attempts: 3
         ) do
      {:ok, 0} -> :ok
      {:ok, count} -> Logger.warning("Startup cleanup: aborted #{count} orphaned FNIs")
      {:error, reason} -> Logger.error("Startup cleanup: FNI sweep failed: #{inspect(reason)}")
    end
  end

  defp batch_size do
    Application.get_env(:core_execution, :resume_batch_size, 1000)
  end

  # Child PIs are resumed by their parent's handler Task, which reports the
  # parent settled only after the child is running; sweeping until a round
  # finds no newly resumed PI therefore covers whole trees. Fresh starts
  # settle at once and never cause another round, so a steady start load
  # cannot keep the sweep going.
  defp await_resume_settled(settled_pids) do
    unsettled_pids =
      BfwEngine.Execution.Supervisor
      |> DynamicSupervisor.which_children()
      |> Enum.flat_map(fn
        {_id, pid, _type, _modules} when is_pid(pid) -> [pid]
        _restarting -> []
      end)
      |> Enum.reject(&Map.has_key?(settled_pids, &1))

    resumed_found? =
      unsettled_pids
      |> Enum.map(&await_process_instance_settled/1)
      |> Enum.any?()

    if resumed_found? do
      await_resume_settled(Map.merge(settled_pids, Map.from_keys(unsettled_pids, true)))
    else
      :ok
    end
  end

  defp await_process_instance_settled(process_instance_pid) do
    case ProcessInstance.await_resume_settled(process_instance_pid, @resume_settle_timeout_ms) do
      {:ok, resumed?} ->
        resumed?

      {:error, :timeout} ->
        Logger.warning(
          "ResumeRunner: PI #{inspect(process_instance_pid)} did not report its subscriptions " <>
            "re-registered within #{@resume_settle_timeout_ms} ms"
        )

        true
    end
  end

  defp resume_batches(adapter, batch_size, cursor, resumed_acc, total_acc) do
    case PersistenceRetry.with_retry(
           fn -> adapter.list_running_process_instances(limit: batch_size, after: cursor) end,
           "Resume: list running PIs (cursor=#{inspect(cursor)})",
           max_attempts: 3
         ) do
      {:ok, %{records: records, next_cursor: next_cursor}} ->
        resumed_in_batch = Enum.count(records, &(resume_one_isolated(adapter, &1) == :ok))
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

  # One PI that raises must not abort the batch and hide the PIs already resumed.
  defp resume_one_isolated(adapter, process_instance) do
    resume_one(adapter, process_instance)
  rescue
    error ->
      Logger.error(
        "ResumeRunner: resuming PI #{process_instance.id} raised: #{Exception.message(error)}"
      )

      :error
  end

  defp resume_one(adapter, process_instance) do
    with {:ok, flow_node_instances} <-
           PersistenceRetry.with_retry(
             fn -> adapter.list_all_flow_node_instances(process_instance.id) end,
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
             BfwEngine.Execution.Supervisor,
             {BfwEngine.Execution.ProcessInstance, opts}
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
      engine_name: "Bifrost Forge World Engine",
      version: Application.spec(:core_execution, :vsn) |> to_string(),
      started_at: DateTime.utc_now()
    })
  end

  # Resume bypasses BFE_MAX_CONCURRENT_PIS so PI trees come back whole.
  # When that leaves the engine over the configured cap, emit EngineOverloaded
  # so operators see the oversubscription. Remaining resumes are never refused.
  defp maybe_publish_resume_overload do
    case BfwEngine.Execution.configured_limit() do
      :infinity ->
        :ok

      limit when is_integer(limit) and limit >= 0 ->
        active = BfwEngine.Execution.count_active()

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

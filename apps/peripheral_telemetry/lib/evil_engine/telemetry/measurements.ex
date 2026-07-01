defmodule EvilEngine.Telemetry.Measurements do
  @moduledoc """
  Periodic telemetry measurements emitted by the poller.

  Also detects load-level threshold crossings and publishes
  `EngineOverloaded` / `EngineRecovered` events via the
  `EngineEventBus` (Layer 3).
  """

  require Logger

  alias EvilEngine.Events.EngineEventBus
  alias EvilEngine.Types.Event

  @execution_supervisor :"Elixir.EvilEngine.Execution.Supervisor"

  @elevated_threshold 0.7
  @critical_threshold 0.9

  @doc """
  Counts active children under the Execution DynamicSupervisor and emits
  telemetry events for the active PI gauge and capacity ratio.

  When the PI cap is finite, detects threshold crossings between
  `normal` / `elevated` / `critical` and publishes `EngineOverloaded`
  or `EngineRecovered` events on transitions.

  Called periodically by `:telemetry_poller`. The supervisor name is a
  well-known atom; no compile-time dependency on `core_execution` needed.
  """
  @spec active_process_instances() :: :ok
  def active_process_instances do
    %{active: active_count} = DynamicSupervisor.count_children(@execution_supervisor)

    :telemetry.execute([:evil_engine, :process_instance, :active], %{count: active_count}, %{})

    limit = Application.get_env(:core_execution, :max_concurrent_process_instances, :infinity)
    emit_capacity_ratio(active_count, limit)
    check_overload_crossing(active_count, limit)
  catch
    :exit, reason ->
      Logger.debug(
        "Telemetry poller: active_process_instances measurement skipped (supervisor not running): #{inspect(reason)}"
      )

      :ok
  end

  defp emit_capacity_ratio(_active, :infinity) do
    :telemetry.execute([:evil_engine, :process_instance, :capacity], %{ratio: 0.0}, %{})
  end

  defp emit_capacity_ratio(active, limit) when is_integer(limit) and limit > 0 do
    ratio = active / limit
    :telemetry.execute([:evil_engine, :process_instance, :capacity], %{ratio: ratio}, %{})
  end

  defp emit_capacity_ratio(_active, _limit), do: :ok

  defp check_overload_crossing(_active, :infinity), do: :ok

  defp check_overload_crossing(active, limit) when is_integer(limit) and limit > 0 do
    new_level = compute_level(active, limit)
    previous = :persistent_term.get(:evil_engine_load_level, :normal)

    if new_level != previous do
      :persistent_term.put(:evil_engine_load_level, new_level)
      emit_level_transition(new_level, previous, active, limit)
    end

    :ok
  end

  defp check_overload_crossing(_active, _limit), do: :ok

  defp emit_level_transition(new_level, _previous, active, limit)
       when new_level in [:elevated, :critical] do
    EngineEventBus.publish(%Event.EngineOverloaded{
      level: new_level,
      active_process_instances: active,
      limit: limit,
      occurred_at: DateTime.utc_now()
    })
  end

  defp emit_level_transition(:normal, previous, active, limit) do
    EngineEventBus.publish(%Event.EngineRecovered{
      previous_level: previous,
      active_process_instances: active,
      limit: limit,
      occurred_at: DateTime.utc_now()
    })
  end

  defp compute_level(active, limit) do
    ratio = active / limit

    cond do
      ratio < @elevated_threshold -> :normal
      ratio < @critical_threshold -> :elevated
      true -> :critical
    end
  end

  @doc """
  Samples DB connection pool stats for each known repo and emits
  telemetry gauges for pool size, checked-out count, and idle count.

  Uses DBConnection's `get_connection_metrics` to probe the pool's
  ready connection count. Falls back to `{0, 0, 0}` when the pool is
  unreachable (e.g. in test with Ecto SQL Sandbox).

  Called periodically by `:telemetry_poller`.
  """
  @spec db_pool_stats() :: :ok
  def db_pool_stats do
    for {label, repo} <- known_repos() do
      {pool_size, checked_out, idle} = probe_repo_pool(repo)

      :telemetry.execute(
        [:evil_engine, :db, :pool],
        %{size: pool_size, checked_out: checked_out, idle: idle},
        %{repo: label}
      )
    end

    :ok
  catch
    :exit, _ -> :ok
  end

  defp known_repos do
    repos = [{:write, EvilEngine.Persistence.Repo}]

    if Code.ensure_loaded?(EvilEngine.Persistence.ReadRepo) and
         Process.whereis(EvilEngine.Persistence.ReadRepo) != nil do
      repos ++ [{:read, EvilEngine.Persistence.ReadRepo}]
    else
      repos
    end
  end

  defp probe_repo_pool(repo) do
    pool_size = repo.config()[:pool_size] || 10
    {ready_count, _queue_length} = probe_pool_connections(repo)
    checked_out = max(0, pool_size - ready_count)
    {pool_size, checked_out, ready_count}
  rescue
    _ -> {0, 0, 0}
  catch
    :exit, _ -> {0, 0, 0}
  end

  defp probe_pool_connections(repo) do
    case Process.whereis(repo) do
      nil ->
        {0, 0}

      supervisor_pid ->
        pool_pid =
          supervisor_pid
          |> Supervisor.which_children()
          |> Enum.find_value(fn
            {_, pid, :worker, _} when is_pid(pid) -> pid
            _ -> nil
          end)

        if pool_pid do
          metrics = DBConnection.ConnectionPool.get_connection_metrics(pool_pid)
          aggregate_pool_metrics(metrics)
        else
          {0, 0}
        end
    end
  rescue
    _ -> {0, 0}
  catch
    :exit, _ -> {0, 0}
  end

  defp aggregate_pool_metrics([%{ready_conn_count: ready} | _]), do: {ready, 0}
  defp aggregate_pool_metrics(_), do: {0, 0}
end

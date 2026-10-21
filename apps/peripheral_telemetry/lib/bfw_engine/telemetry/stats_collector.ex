defmodule BfwEngine.Telemetry.StatsCollector do
  @moduledoc """
  Assembles the `/stats` JSON snapshot on demand.

  Queries live data from Ash resources, ETS tables, and the plugin
  registry. When a database-backed section cannot be read, `snapshot/0`
  answers `{:error, :database_unavailable}` instead of reporting zeros:
  a zero count is a statement, an unreadable count is not.
  """

  require Ash.Query
  require Logger

  alias BfwEngine.Events.EngineEventBus
  alias BfwEngine.Persistence.Resources.FlowNodeInstance, as: FNIResource
  alias BfwEngine.Persistence.Resources.ProcessInstance, as: PIResource

  @elevated_threshold 0.7
  @critical_threshold 0.9

  @timer_primary_table :bfw_engine_timers_primary

  @dialyzer {:nowarn_function, snapshot: 0, info: 0}

  @doc "Returns the full /stats snapshot, or an error when a database query fails."
  @spec snapshot() :: {:ok, map()} | {:error, :database_unavailable}
  def snapshot do
    {:ok, build_snapshot()}
  rescue
    exception ->
      Logger.error(
        "Stats snapshot failed: database query raised #{inspect(exception.__struct__)}"
      )

      {:error, :database_unavailable}
  catch
    :exit, reason ->
      Logger.error("Stats snapshot failed: database query exited with #{inspect(reason)}")
      {:error, :database_unavailable}
  end

  defp build_snapshot do
    config = Application.get_all_env(:peripheral_telemetry)

    %{
      engine: %{
        id: Keyword.get(config, :engine_id, "unknown"),
        name: Keyword.get(config, :engine_name, "unknown"),
        version: Application.spec(:core_execution, :vsn) |> to_string(),
        started_at: started_at(),
        uptime_seconds: uptime_seconds(),
        load: load_level()
      },
      process_instances: query_process_instance_counts(),
      flow_node_instances: query_flow_node_instance_counts(),
      user_tasks_pending: query_user_tasks_pending(),
      async_flow_nodes: query_async_flow_nodes(),
      timers: query_timer_stats(),
      plugins: query_plugins(),
      listeners: sink_info(),
      db_pools: query_db_pool_info()
    }
  end

  @doc "Returns the /info payload."
  @spec info() :: map()
  def info do
    config = Application.get_all_env(:peripheral_telemetry)

    %{
      engine_id: Keyword.get(config, :engine_id, "unknown"),
      engine_name: Keyword.get(config, :engine_name, "unknown"),
      version: Application.spec(:core_execution, :vsn) |> to_string(),
      started_at: started_at()
    }
  end

  defp query_process_instance_counts do
    count_by_state(
      PIResource,
      %{running: 0, finished: 0, fatal: 0, aborted: 0, error: 0},
      ["running", "finished", "fatal", "aborted", "error"]
    )
  end

  defp query_flow_node_instance_counts do
    count_by_state(
      FNIResource,
      %{
        active: 0,
        waiting: 0,
        finished: 0,
        fatal: 0,
        aborted: 0,
        interrupted: 0,
        error: 0,
        by_type: %{}
      },
      ["active", "waiting", "finished", "fatal", "aborted", "interrupted", "error"]
    )
  end

  defp count_by_state(resource, defaults, states) do
    Enum.reduce(states, defaults, fn state_string, accumulator ->
      Map.put(
        accumulator,
        String.to_existing_atom(state_string),
        count_resources(resource, state_string)
      )
    end)
  end

  defp query_user_tasks_pending do
    count =
      FNIResource
      |> Ash.Query.filter(flow_node_type == "user_task" and state == "waiting")
      |> Ash.Query.for_read(:read, %{}, authorize?: false)
      |> Ash.count!(authorize?: false)

    %{count: count, by_assignee_role: %{}}
  end

  defp query_async_flow_nodes do
    count =
      FNIResource
      |> Ash.Query.filter(state == "waiting" and flow_node_type != "user_task")
      |> Ash.Query.for_read(:read, %{}, authorize?: false)
      |> Ash.count!(authorize?: false)

    %{waiting: count, by_plugin: %{}}
  end

  defp query_timer_stats do
    armed =
      try do
        :ets.info(@timer_primary_table, :size)
      catch
        :error, :badarg -> 0
      end

    now_ms = System.system_time(:millisecond)
    one_minute_ms = now_ms + 60_000

    fire_in_next_minute =
      try do
        @timer_primary_table
        |> :ets.select([{{{:"$1", :_}, :_, :_, :_}, [{:"=<", :"$1", one_minute_ms}], [true]}])
        |> length()
      catch
        :error, :badarg -> 0
      end

    %{armed: armed, fire_in_next_minute: fire_in_next_minute}
  end

  defp query_plugins do
    BfwEngine.Plugins.Registry.list_plugins()
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp count_resources(resource, state_string) do
    resource
    |> Ash.Query.filter(state == ^state_string)
    |> Ash.Query.for_read(:read, %{}, authorize?: false)
    |> Ash.count!(authorize?: false)
  end

  defp load_level do
    limit = Application.get_env(:core_execution, :max_concurrent_process_instances, :infinity)
    compute_load_level(limit)
  end

  defp compute_load_level(:infinity), do: "normal"

  defp compute_load_level(limit) when is_integer(limit) and limit > 0 do
    active =
      try do
        %{active: active_count} =
          DynamicSupervisor.count_children(BfwEngine.Execution.Supervisor)

        active_count
      catch
        :exit, _ -> 0
      end

    ratio = active / limit

    cond do
      ratio < @elevated_threshold -> "normal"
      ratio < @critical_threshold -> "elevated"
      true -> "critical"
    end
  end

  defp compute_load_level(_), do: "normal"

  defp started_at do
    case :persistent_term.get(:bfw_engine_started_at, nil) do
      nil ->
        now = DateTime.utc_now()
        :persistent_term.put(:bfw_engine_started_at, now)
        now

      recorded_started_at ->
        recorded_started_at
    end
  end

  defp uptime_seconds do
    start = started_at()
    DateTime.diff(DateTime.utc_now(), start, :second)
  end

  defp query_db_pool_info do
    for {label, repo} <- known_repos(), into: %{} do
      pool_size = repo.config()[:pool_size] || 0
      {to_string(label), %{pool_size: pool_size}}
    end
  rescue
    _ -> %{}
  catch
    :exit, _ -> %{}
  end

  defp known_repos do
    repos = [{:write, BfwEngine.Persistence.Repo}]

    if Code.ensure_loaded?(BfwEngine.Persistence.ReadRepo) and
         Process.whereis(BfwEngine.Persistence.ReadRepo) != nil do
      repos ++ [{:read, BfwEngine.Persistence.ReadRepo}]
    else
      repos
    end
  end

  defp sink_info do
    sinks = EngineEventBus.list_sinks()

    by_name =
      Enum.reduce(sinks, %{}, fn sink, accumulator ->
        Map.put(accumulator, sink.name, "on")
      end)

    defaults = %{
      "console" => "off",
      "telemetry" => "off",
      "websocket" => "off"
    }

    %{
      event_sinks_count: length(sinks),
      event_sinks_by_name: Map.merge(defaults, by_name),
      monitoring_panels_count: 0
    }
  catch
    :exit, _ ->
      %{
        event_sinks_count: 0,
        event_sinks_by_name: %{},
        monitoring_panels_count: 0
      }
  end
end

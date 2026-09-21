defmodule BfwEngine.Test.BenchmarkReporter do
  @moduledoc false
  use Agent

  alias BfwEngine.Types.Wire

  @regression_drop_factor 0.8
  @regression_rise_factor 1.2

  def start_link(opts \\ []) when is_list(opts) do
    agent_options = agent_start_options(Keyword.get(opts, :name, __MODULE__))

    case Agent.start_link(fn -> %{workloads: []} end, agent_options) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        {:ok, pid}
    end
  end

  def stop do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> Agent.stop(pid)
    end
  end

  def stop(server) do
    Agent.stop(server)
  end

  def record(workload) when is_map(workload) do
    case Process.whereis(__MODULE__) do
      nil ->
        :ok

      pid ->
        record(workload, pid)
    end
  end

  def record(workload, server) when is_map(workload) do
    Agent.update(server, fn state ->
      %{state | workloads: [workload | state.workloads]}
    end)
  end

  def runtime_snapshot do
    memory = :erlang.memory()
    {number_of_collections, words_reclaimed, _left} = :erlang.statistics(:garbage_collection)

    %{
      beam_process_count: :erlang.system_info(:process_count),
      memory_bytes: %{
        total: memory[:total],
        processes: memory[:processes],
        system: memory[:system],
        atom: memory[:atom],
        binary: memory[:binary],
        ets: memory[:ets]
      },
      garbage_collection: %{
        number_of_collections: number_of_collections,
        words_reclaimed: words_reclaimed
      }
    }
  end

  def write!(path) do
    write!(path, __MODULE__)
  end

  def write!(path, server) do
    File.mkdir_p!(Path.dirname(path))
    snapshot = runtime_snapshot()
    workloads = Agent.get(server, &Enum.reverse(&1.workloads))

    report = %{
      schema_version: 1,
      recorded_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      git_sha: git_sha(),
      otp_release: List.to_string(:erlang.system_info(:otp_release)),
      elixir_version: System.version(),
      beam_process_count: snapshot.beam_process_count,
      memory_bytes: snapshot.memory_bytes,
      garbage_collection: snapshot.garbage_collection,
      workloads: workloads
    }

    File.write!(path, Jason.encode!(camelize(report), pretty: true))
    path
  end

  @doc """
  Compare overlapping workload ids. A regression is a drop of more than 20%
  on process_instances_per_second or either throughput KPI, or a rise of
  more than 20% on latencies_milliseconds.p99 or queue_time_milliseconds_p99.
  Missing ids on either side are skipped.
  """
  def compare_baseline(baseline, current) when is_map(baseline) and is_map(current) do
    baseline_by_id = Map.new(List.wrap(baseline["workloads"]), &{&1["id"], &1})
    current_by_id = Map.new(List.wrap(current["workloads"]), &{&1["id"], &1})

    regressions =
      baseline_by_id
      |> Map.keys()
      |> Enum.filter(&Map.has_key?(current_by_id, &1))
      |> Enum.flat_map(fn workload_id ->
        regression_messages(workload_id, baseline_by_id[workload_id], current_by_id[workload_id])
      end)

    if regressions == [], do: :ok, else: {:error, regressions}
  end

  defp agent_start_options(nil), do: []
  defp agent_start_options(name), do: [name: name]

  defp regression_messages(workload_id, baseline_workload, current_workload) do
    throughput_fields = [
      {"processInstancesPerSecond", :drop},
      {["kpis", "resumeThroughputProcessInstancesPerSecond"], :drop},
      {["kpis", "seedingThroughputProcessInstancesPerSecond"], :drop}
    ]

    latency_fields = [
      {["latenciesMilliseconds", "p99"], :rise},
      {"queueTimeMillisecondsP99", :rise}
    ]

    (throughput_fields ++ latency_fields)
    |> Enum.flat_map(fn {path, direction} ->
      baseline_value = get_in_path(baseline_workload, path)
      current_value = get_in_path(current_workload, path)

      cond do
        not is_number(baseline_value) or not is_number(current_value) ->
          []

        direction == :drop and current_value < baseline_value * @regression_drop_factor ->
          ["#{workload_id} #{inspect(path)} dropped from #{baseline_value} to #{current_value}"]

        direction == :rise and current_value > baseline_value * @regression_rise_factor ->
          ["#{workload_id} #{inspect(path)} rose from #{baseline_value} to #{current_value}"]

        true ->
          []
      end
    end)
  end

  defp get_in_path(map, path) when is_binary(path), do: map[path]
  defp get_in_path(map, path) when is_list(path), do: get_in(map, path)

  defp git_sha do
    case System.cmd("git", ["rev-parse", "--short", "HEAD"], stderr_to_stdout: true) do
      {sha, 0} -> String.trim(sha)
      _ -> nil
    end
  end

  defp camelize(term), do: Wire.camelize_keys(term)
end

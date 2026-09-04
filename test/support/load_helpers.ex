defmodule EvilEngine.Test.LoadHelpers do
  @moduledoc """
  Helpers for load / benchmark tests.

  Provides bulk PI/FNI seeding via direct Ash writes (bypassing the
  normal execution path) and timing utilities for benchmark reporting.
  """

  alias EvilEngine.Persistence.Api, as: Domain
  alias EvilEngine.Persistence.Resources.FlowNodeInstance
  alias EvilEngine.Persistence.Resources.ProcessInstance
  alias EvilEngine.Test.BenchmarkReporter

  @doc """
  Seed `count` process instances with FNIs into the database.

  Each PI gets one FNI per entry in `fni_templates`. Returns a list of
  `%{process_instance_id, flow_node_instance_ids}` maps.

  ## Parameters

  - `process_version_id` — the deployed process version ID
  - `count` — number of PIs to create
  - `fni_templates` — list of FNI template maps, each with at least
    `:flow_node_id`, `:flow_node_type`, `:state`
  """
  @spec seed_process_instances(String.t(), pos_integer(), [map()]) :: [map()]
  def seed_process_instances(process_version_id, count, fni_templates) do
    Enum.map(1..count, fn _i ->
      process_instance_id = Ash.UUIDv7.generate()
      now = DateTime.utc_now()

      {:ok, _} =
        Ash.create(
          ProcessInstance,
          %{
            id: process_instance_id,
            process_version_id: process_version_id,
            state: "running",
            started_at: now,
            started_by: %{"id" => "load-test", "roles" => [], "groups" => []},
            started_with_context: %{}
          },
          domain: Domain
        )

      flow_node_instance_ids =
        Enum.map(fni_templates, fn template ->
          flow_node_instance_id = Ash.UUIDv7.generate()

          {:ok, _} =
            Ash.create(
              FlowNodeInstance,
              %{
                id: flow_node_instance_id,
                process_instance_id: process_instance_id,
                flow_node_id: template.flow_node_id,
                flow_node_type: to_string(template.flow_node_type),
                state: to_string(template.state),
                started_at: now,
                input_token: template[:input_token] || %{},
                type_properties: template[:type_properties] || %{},
                previous_flow_node_instance_ids: template[:previous_flow_node_instance_ids] || []
              },
              domain: Domain
            )

          flow_node_instance_id
        end)

      %{process_instance_id: process_instance_id, flow_node_instance_ids: flow_node_instance_ids}
    end)
  end

  @doc """
  Seed `total` PIs by round-robin over a list of `{version_id, fni_templates}` pairs.

  Distributes PIs evenly across the templates, with any remainder going to
  the first template.
  """
  @spec seed_mixed_pis([{String.t(), [map()]}], pos_integer()) :: [map()]
  def seed_mixed_pis(templates, total) do
    template_count = length(templates)
    per_template = div(total, template_count)
    remainder = rem(total, template_count)

    templates
    |> Enum.with_index()
    |> Enum.flat_map(fn {{version_id, flow_node_instance_template}, index} ->
      count = if index == 0, do: per_template + remainder, else: per_template
      seed_process_instances(version_id, count, flow_node_instance_template)
    end)
  end

  @doc """
  Measure the wall-clock time of a function and log it as a benchmark.

  Returns `{elapsed_ms, result}`. When `opts` includes `:id`, also records a
  workload into `EvilEngine.Test.BenchmarkReporter` (no-op if the agent is not
  started).

  ## Options

  - `:id` — workload identifier; recording is skipped when omitted
  - `:kind` — `"execution" | "resume" | "seeding" | "pool_pressure" | "dmn"`
  - `:process_count` — number of process instances in the workload
  - `:latency_samples_milliseconds` — samples for p50/p95/p99; omit for `null`
  - `:latency_samples_table` — ETS bag of `{:sample, milliseconds}` read **after** the fun
  - `:queue_time_milliseconds_p99` — optional P99 DB queue time
  - `:queue_time_collector` — collector from `start_queue_time_collector/0`, read **after** the fun
  - `:kpis` — optional throughput KPI map
  - `:kpi_kind` — `:resume` or `:seeding`; after the fun, copies `process_instances_per_second`
    into the matching KPI field
  """
  @spec measure(String.t(), (-> term())) :: {non_neg_integer(), term()}
  @spec measure(String.t(), (-> term()), keyword()) :: {non_neg_integer(), term()}
  def measure(label, fun, opts \\ []) when is_list(opts) do
    {elapsed_us, result} = :timer.tc(fun)
    elapsed_ms = div(elapsed_us, 1000)
    IO.puts("[BENCH] #{label}: #{elapsed_ms}ms")
    maybe_record_measurement(opts, elapsed_ms)
    {elapsed_ms, result}
  end

  @doc "Terminate all running PI processes from the DynamicSupervisor."
  @spec terminate_all_process_instances() :: :ok
  def terminate_all_process_instances do
    children = DynamicSupervisor.which_children(EvilEngine.Execution.Supervisor)

    Enum.each(children, fn {_, pid, _, _} ->
      DynamicSupervisor.terminate_child(EvilEngine.Execution.Supervisor, pid)
    end)
  rescue
    _ -> :ok
  end

  @doc "Count how many PI processes are registered in the Execution Registry."
  @spec count_registered_process_instances() :: non_neg_integer()
  def count_registered_process_instances do
    Registry.count(EvilEngine.Execution.Registry)
  end

  @doc """
  Restore shared sandbox ownership (P82) then call `ResumeRunner.resume_all/0`.

  Large resume workloads can tear the shared checkout (checkout timeout /
  OwnershipError). Callers must keep sandbox `{:shared, self()}` — this
  retries after restore instead of disabling the sandbox.
  """
  @spec resume_all_with_sandbox_retry() :: term()
  def resume_all_with_sandbox_retry do
    # Do not checkout/restore before the first attempt: a fresh sandbox
    # transaction hides rows seeded in the test's existing shared checkout (P82).
    EvilEngine.Test.DbAssertions.with_sandbox_retry(fn ->
      EvilEngine.Execution.ResumeRunner.resume_all()
    end)
  end

  @doc """
  Start collecting DB queue_time values via telemetry.

  Returns a handle that can be passed to `queue_time_p99/1` and `stop_queue_time_collector/1`.
  """
  @spec start_queue_time_collector() :: map()
  def start_queue_time_collector do
    table = :ets.new(:queue_times, [:bag, :public])
    handler_id = "queue-time-collector-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:evil_engine, :db, :query],
      fn _event, measurements, _metadata, config ->
        queue_time_ms = measurements[:queue_time_ms]

        if is_number(queue_time_ms) do
          try do
            :ets.insert(config.table, {:sample, queue_time_ms})
          rescue
            ArgumentError -> :ok
          end
        end
      end,
      %{table: table}
    )

    # Test crash skips `stop_queue_time_collector/1`; the ETS table dies with
    # the test process but the telemetry handler stays attached (P88).
    ExUnit.Callbacks.on_exit(fn -> :telemetry.detach(handler_id) end)

    %{table: table, handler_id: handler_id}
  end

  @doc "Compute the P99 queue_time_ms from collected samples."
  @spec queue_time_p99(map()) :: float()
  def queue_time_p99(%{table: table}) do
    samples = Enum.map(:ets.tab2list(table), fn {:sample, value} -> value end)
    percentile(samples, 0.99)
  end

  @doc "Compute the max queue_time_ms from collected samples."
  @spec queue_time_max(map()) :: float()
  def queue_time_max(%{table: table}) do
    samples =
      :ets.tab2list(table)
      |> Enum.map(fn {:sample, value} -> value end)

    case Enum.max(samples, fn -> 0.0 end) do
      value when is_number(value) -> value / 1.0
      _ -> 0.0
    end
  end

  @doc """
  Start collecting DBConnection.ConnectionError events via telemetry.

  Returns a handle with an atomics counter for error occurrences.
  """
  @spec start_connection_error_collector() :: map()
  def start_connection_error_collector do
    error_count = :atomics.new(1, signed: false)
    handler_id = "conn-error-collector-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:db_connection, :connection_error],
      fn _event, _measurements, _metadata, config ->
        :atomics.add(config.error_count, 1, 1)
      end,
      %{error_count: error_count}
    )

    %{error_count: error_count, handler_id: handler_id}
  end

  @doc "Read the connection error count."
  @spec connection_error_count(map()) :: non_neg_integer()
  def connection_error_count(%{error_count: error_count}) do
    :atomics.get(error_count, 1)
  end

  @doc "Stop the connection error collector."
  @spec stop_connection_error_collector(map()) :: :ok
  def stop_connection_error_collector(%{handler_id: handler_id}) do
    :telemetry.detach(handler_id)
    :ok
  end

  @doc """
  Stop the queue time collector and clean up.

  Idempotent: ExUnit `on_exit` runs after the test process exits, which
  already drops ETS tables owned by that process. A second `:ets.delete/1`
  would raise `ArgumentError`.
  """
  @spec stop_queue_time_collector(map()) :: :ok
  def stop_queue_time_collector(%{table: table, handler_id: handler_id}) do
    :telemetry.detach(handler_id)

    case :ets.info(table) do
      :undefined -> :ok
      _info -> :ets.delete(table)
    end

    :ok
  end

  @doc "Clean up seeded rows via direct SQL (avoids needing Ash :destroy actions)."
  @spec cleanup_seeded_pis([map()]) :: :ok
  def cleanup_seeded_pis(seeded) do
    process_instance_ids =
      Enum.map(seeded, fn %{process_instance_id: id} ->
        {:ok, binary_uuid} = Ecto.UUID.dump(id)
        binary_uuid
      end)

    EvilEngine.Persistence.Repo.query!(
      "DELETE FROM flow_node_instances WHERE process_instance_id = ANY($1::uuid[])",
      [process_instance_ids]
    )

    EvilEngine.Persistence.Repo.query!(
      "DELETE FROM process_instances WHERE id = ANY($1::uuid[])",
      [process_instance_ids]
    )

    :ok
  end

  defp maybe_record_measurement(opts, elapsed_milliseconds) do
    case Keyword.get(opts, :id) do
      nil ->
        :ok

      id ->
        process_count = Keyword.get(opts, :process_count, 0)
        elapsed_denominator = max(elapsed_milliseconds, 1)
        process_instances_per_second = process_count * 1000 / elapsed_denominator

        BenchmarkReporter.record(%{
          id: id,
          kind: Keyword.get(opts, :kind),
          process_count: process_count,
          elapsed_milliseconds: elapsed_milliseconds,
          process_instances_per_second: process_instances_per_second,
          latencies_milliseconds: latencies_milliseconds(latency_samples_after_fun(opts)),
          queue_time_milliseconds_p99: queue_time_milliseconds_p99_after_fun(opts),
          kpis: kpis_after_fun(opts, process_instances_per_second)
        })
    end
  end

  defp latency_samples_after_fun(opts) do
    case Keyword.fetch(opts, :latency_samples_milliseconds) do
      {:ok, samples} ->
        samples

      :error ->
        case Keyword.get(opts, :latency_samples_table) do
          nil ->
            nil

          table ->
            Enum.map(:ets.tab2list(table), fn {:sample, milliseconds} -> milliseconds end)
        end
    end
  end

  defp queue_time_milliseconds_p99_after_fun(opts) do
    case Keyword.fetch(opts, :queue_time_milliseconds_p99) do
      {:ok, queue_time_milliseconds_p99} ->
        queue_time_milliseconds_p99

      :error ->
        case Keyword.get(opts, :queue_time_collector) do
          nil -> nil
          collector -> queue_time_p99(collector)
        end
    end
  end

  defp kpis_after_fun(opts, process_instances_per_second) do
    kpis = Keyword.get(opts, :kpis, default_kpis())

    case Keyword.get(opts, :kpi_kind) do
      :resume ->
        Map.put(
          kpis,
          :resume_throughput_process_instances_per_second,
          process_instances_per_second
        )

      :seeding ->
        Map.put(
          kpis,
          :seeding_throughput_process_instances_per_second,
          process_instances_per_second
        )

      _other ->
        kpis
    end
  end

  defp default_kpis do
    %{
      resume_throughput_process_instances_per_second: nil,
      seeding_throughput_process_instances_per_second: nil
    }
  end

  defp latencies_milliseconds(samples) when is_list(samples) do
    %{
      p50: percentile(samples, 0.50),
      p95: percentile(samples, 0.95),
      p99: percentile(samples, 0.99)
    }
  end

  defp latencies_milliseconds(_omitted), do: nil

  defp percentile(samples, quantile) do
    sorted_samples = Enum.sort(samples)

    case sorted_samples do
      [] ->
        0.0

      _non_empty ->
        index = min(trunc(length(sorted_samples) * quantile), length(sorted_samples) - 1)
        Enum.at(sorted_samples, index) / 1.0
    end
  end
end

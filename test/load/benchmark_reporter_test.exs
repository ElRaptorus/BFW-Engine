defmodule BfwEngine.Load.BenchmarkReporterTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias BfwEngine.Test.BenchmarkReporter
  alias BfwEngine.Test.LoadHelpers

  @tag :load
  test "write! emits schemaVersion 1 with recorded workload and runtime snapshot" do
    {:ok, pid} = BenchmarkReporter.start_link(name: nil)

    try do
      BenchmarkReporter.record(
        %{
          id: "fixture_sleep",
          kind: :execution,
          process_count: 10,
          elapsed_milliseconds: 100,
          process_instances_per_second: 100.0,
          latencies_milliseconds: %{p50: 10.0, p95: 10.0, p99: 10.0},
          queue_time_milliseconds_p99: nil,
          kpis: %{
            resume_throughput_process_instances_per_second: nil,
            seeding_throughput_process_instances_per_second: nil
          }
        },
        pid
      )

      path = Path.join(System.tmp_dir!(), "bench-#{System.unique_integer([:positive])}.json")
      assert ^path = BenchmarkReporter.write!(path, pid)
      map = path |> File.read!() |> Jason.decode!()
      assert map["schemaVersion"] == 1
      assert is_binary(map["recordedAt"])
      assert is_integer(map["beamProcessCount"])
      assert is_integer(get_in(map, ["memoryBytes", "total"]))
      assert [%{"id" => "fixture_sleep"}] = map["workloads"]
      assert is_integer(hd(map["workloads"])["elapsedMilliseconds"])
    after
      BenchmarkReporter.stop(pid)
    end
  end

  @tag :load
  test "compare_baseline fails when a numeric KPI drops more than 20 percent" do
    baseline = %{
      "workloads" => [
        %{
          "id" => "exec_10000_linear",
          "processInstancesPerSecond" => 300.0,
          "kpis" => %{"resumeThroughputProcessInstancesPerSecond" => nil}
        }
      ]
    }

    current = %{
      "workloads" => [
        %{
          "id" => "exec_10000_linear",
          "processInstancesPerSecond" => 200.0,
          "kpis" => %{"resumeThroughputProcessInstancesPerSecond" => nil}
        }
      ]
    }

    assert {:error, regressions} = BenchmarkReporter.compare_baseline(baseline, current)
    assert Enum.any?(regressions, &String.contains?(&1, "exec_10000_linear"))
  end

  @tag :load
  test "compare_baseline ignores a workload id that exists only on one side" do
    baseline = %{"workloads" => [%{"id" => "old_only", "processInstancesPerSecond" => 1.0}]}
    current = %{"workloads" => [%{"id" => "new_only", "processInstancesPerSecond" => 1.0}]}
    assert :ok = BenchmarkReporter.compare_baseline(baseline, current)
  end

  @tag :load
  test "measure/2 returns elapsed milliseconds and prints [BENCH]" do
    output =
      capture_io(fn ->
        send(self(), LoadHelpers.measure("fixture_label", fn -> :done end))
      end)

    assert_received {elapsed_ms, :done}
    assert is_integer(elapsed_ms)
    assert elapsed_ms >= 0
    assert output =~ "[BENCH] fixture_label:"
    assert output =~ "ms"
  end

  @tag :load
  test "measure/3 records a workload when id is set" do
    {:ok, _pid} = BenchmarkReporter.start_link()

    capture_io(fn ->
      LoadHelpers.measure("fixture_sleep", fn -> Process.sleep(1) end,
        id: "fixture_sleep",
        kind: :execution,
        process_count: 10
      )
    end)

    path = Path.join(System.tmp_dir!(), "bench-#{System.unique_integer([:positive])}.json")
    BenchmarkReporter.write!(path)
    map = path |> File.read!() |> Jason.decode!()
    workload = Enum.find(map["workloads"], &(&1["id"] == "fixture_sleep"))

    assert workload["id"] == "fixture_sleep"
    assert workload["kind"] == "execution"
    assert workload["processCount"] == 10
    assert is_integer(workload["elapsedMilliseconds"])
    assert is_number(workload["processInstancesPerSecond"])
    assert is_nil(workload["latenciesMilliseconds"])
    assert is_nil(workload["queueTimeMillisecondsP99"])
    assert is_nil(get_in(workload, ["kpis", "resumeThroughputProcessInstancesPerSecond"]))
    assert is_nil(get_in(workload, ["kpis", "seedingThroughputProcessInstancesPerSecond"]))
  end

  @tag :load
  test "measure/3 computes latency percentiles with the queue_time_p99 index rule" do
    {:ok, _pid} = BenchmarkReporter.start_link()
    samples = [1.0, 2.0, 3.0, 4.0]

    capture_io(fn ->
      LoadHelpers.measure("latencies", fn -> :ok end,
        id: "latencies",
        kind: :execution,
        process_count: 4,
        latency_samples_milliseconds: samples,
        queue_time_milliseconds_p99: 12.5
      )
    end)

    path = Path.join(System.tmp_dir!(), "bench-#{System.unique_integer([:positive])}.json")
    BenchmarkReporter.write!(path)

    workload =
      path
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("workloads")
      |> Enum.find(&(&1["id"] == "latencies"))

    assert workload["latenciesMilliseconds"]["p50"] == 3.0
    assert workload["latenciesMilliseconds"]["p95"] == 4.0
    assert workload["latenciesMilliseconds"]["p99"] == 4.0
    assert workload["queueTimeMillisecondsP99"] == 12.5
  end

  @tag :load
  test "measure/3 reads queue_time_collector after the timed function" do
    {:ok, _pid} = BenchmarkReporter.start_link()
    collector = LoadHelpers.start_queue_time_collector()

    try do
      capture_io(fn ->
        LoadHelpers.measure(
          "queue_after",
          fn ->
            :ets.insert(collector.table, {:sample, 42.0})
            :ok
          end,
          id: "queue_after",
          kind: :execution,
          process_count: 1,
          queue_time_collector: collector
        )
      end)

      path = Path.join(System.tmp_dir!(), "bench-#{System.unique_integer([:positive])}.json")
      BenchmarkReporter.write!(path)

      workload =
        path
        |> File.read!()
        |> Jason.decode!()
        |> Map.fetch!("workloads")
        |> Enum.find(&(&1["id"] == "queue_after"))

      assert workload["queueTimeMillisecondsP99"] == 42.0
    after
      LoadHelpers.stop_queue_time_collector(collector)
      assert :ok == LoadHelpers.stop_queue_time_collector(collector)
    end
  end

  @tag :load
  test "measure/3 reads latency_samples_table after the timed function" do
    {:ok, _pid} = BenchmarkReporter.start_link()
    latency_samples_table = :ets.new(:latency_after, [:public, :bag])

    try do
      capture_io(fn ->
        LoadHelpers.measure(
          "latency_after",
          fn ->
            Enum.each([1.0, 2.0, 3.0, 4.0], fn sample ->
              :ets.insert(latency_samples_table, {:sample, sample})
            end)

            :ok
          end,
          id: "latency_after",
          kind: :execution,
          process_count: 4,
          latency_samples_table: latency_samples_table
        )
      end)

      path = Path.join(System.tmp_dir!(), "bench-#{System.unique_integer([:positive])}.json")
      BenchmarkReporter.write!(path)

      workload =
        path
        |> File.read!()
        |> Jason.decode!()
        |> Map.fetch!("workloads")
        |> Enum.find(&(&1["id"] == "latency_after"))

      assert workload["latenciesMilliseconds"]["p50"] == 3.0
      assert workload["latenciesMilliseconds"]["p95"] == 4.0
      assert workload["latenciesMilliseconds"]["p99"] == 4.0
    after
      :ets.delete(latency_samples_table)
    end
  end

  @tag :load
  test "measure/3 kpi_kind :resume fills resume throughput after the timed function" do
    {:ok, _pid} = BenchmarkReporter.start_link()

    capture_io(fn ->
      LoadHelpers.measure("resume_kpi", fn -> Process.sleep(10) end,
        id: "resume_kpi",
        kind: :resume,
        process_count: 100,
        kpi_kind: :resume
      )
    end)

    path = Path.join(System.tmp_dir!(), "bench-#{System.unique_integer([:positive])}.json")
    BenchmarkReporter.write!(path)

    workload =
      path
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("workloads")
      |> Enum.find(&(&1["id"] == "resume_kpi"))

    assert workload["kpis"]["resumeThroughputProcessInstancesPerSecond"] ==
             workload["processInstancesPerSecond"]

    assert is_nil(workload["kpis"]["seedingThroughputProcessInstancesPerSecond"])
  end

  @tag :load
  test "measure/3 kpi_kind :seeding fills seeding throughput after the timed function" do
    {:ok, _pid} = BenchmarkReporter.start_link()

    capture_io(fn ->
      LoadHelpers.measure("seed_kpi", fn -> Process.sleep(10) end,
        id: "seed_kpi",
        kind: :seeding,
        process_count: 50,
        kpi_kind: :seeding
      )
    end)

    path = Path.join(System.tmp_dir!(), "bench-#{System.unique_integer([:positive])}.json")
    BenchmarkReporter.write!(path)

    workload =
      path
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("workloads")
      |> Enum.find(&(&1["id"] == "seed_kpi"))

    assert is_nil(workload["kpis"]["resumeThroughputProcessInstancesPerSecond"])

    assert workload["kpis"]["seedingThroughputProcessInstancesPerSecond"] ==
             workload["processInstancesPerSecond"]
  end

  @tag :load
  test "measure/3 does not record when id is omitted" do
    {:ok, _pid} = BenchmarkReporter.start_link()

    before_path = Path.join(System.tmp_dir!(), "bench-#{System.unique_integer([:positive])}.json")
    BenchmarkReporter.write!(before_path)
    before_ids = workload_ids(before_path)

    capture_io(fn ->
      LoadHelpers.measure("unrecorded", fn -> :ok end, kind: :execution, process_count: 1)
    end)

    after_path = Path.join(System.tmp_dir!(), "bench-#{System.unique_integer([:positive])}.json")
    BenchmarkReporter.write!(after_path)
    after_ids = workload_ids(after_path)

    assert after_ids == before_ids
    refute "unrecorded" in after_ids
  end

  @tag :load
  test "already-started start_link/0 preserves previously recorded workloads" do
    {:ok, pid} = BenchmarkReporter.start_link()
    unique_id = "preserve_#{System.unique_integer([:positive])}"

    BenchmarkReporter.record(%{
      id: unique_id,
      kind: :execution,
      process_count: 1,
      elapsed_milliseconds: 1,
      process_instances_per_second: 1.0,
      latencies_milliseconds: nil,
      queue_time_milliseconds_p99: nil,
      kpis: %{
        resume_throughput_process_instances_per_second: nil,
        seeding_throughput_process_instances_per_second: nil
      }
    })

    assert {:ok, ^pid} = BenchmarkReporter.start_link()

    path = Path.join(System.tmp_dir!(), "bench-#{System.unique_integer([:positive])}.json")
    BenchmarkReporter.write!(path)
    assert unique_id in workload_ids(path)
  end

  @tag :load
  test "stop/1 on a private agent does not kill the named reporter" do
    {:ok, named_pid} = BenchmarkReporter.start_link()
    {:ok, private_pid} = BenchmarkReporter.start_link(name: nil)

    assert Process.whereis(BenchmarkReporter) == named_pid

    BenchmarkReporter.stop(private_pid)

    assert Process.alive?(named_pid)
    assert Process.whereis(BenchmarkReporter) == named_pid
    refute Process.alive?(private_pid)
  end

  defp workload_ids(path) do
    path
    |> File.read!()
    |> Jason.decode!()
    |> Map.fetch!("workloads")
    |> Enum.map(& &1["id"])
  end
end

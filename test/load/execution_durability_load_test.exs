defmodule EvilEngine.Load.ExecutionDurabilityLoadTest do
  @moduledoc """
  Opt-in HTTP execution durability: 20,000 / 50,000 / 100,000 process
  instances per shape.

  Excluded from `mix test.load` and the GitHub load-bench job. Run with
  `mix test.load.durability` (this file only) or `mix test.load.all`
  (default suite + this file, one JSON). Not a 5×-baseline gate — first
  measured ceilings are generous wall-clock caps so a laptop can finish;
  GitHub `ubuntu-latest` is the wrong box for this file.
  """

  use EvilEngine.ExecutionCase, async: false

  alias EvilEngine.Events.EngineEventBus
  alias EvilEngine.Plugins.Loader
  alias EvilEngine.Test.AutoFinisher
  alias EvilEngine.Test.CompletionCounter
  alias EvilEngine.Test.DbAssertions
  alias EvilEngine.Test.ExamplePlugin
  alias EvilEngine.Test.LoadHelpers

  @moduletag :load
  @moduletag :durability

  @mi_start_body %{"payload" => %{"items" => [1, 2, 3]}}

  # {count, label, await_ms, ceiling_ms, exunit_timeout_ms}
  # Caps are scaled from GitHub mixed 10,000 at ~26.5/s (worst measured
  # box), plus headroom for call-activity child PIs.
  @batches [
    {20_000, "20000", 1_200_000, 1_200_000, 1_500_000},
    {50_000, "50000", 2_700_000, 2_700_000, 3_000_000},
    {100_000, "100000", 5_400_000, 5_400_000, 7_200_000}
  ]

  @single_shapes [
    %{
      name: "linear",
      deploy: ["linear_start_end.bpmn"],
      start: {"LinearStartEnd", %{}},
      roots_only: false
    },
    %{
      name: "parallel_gateway",
      deploy: ["parallel_gateway_two_branches.bpmn"],
      start: {"ParallelGatewayTwoBranches", %{}},
      roots_only: false
    },
    %{
      name: "mi_parallel_script",
      deploy: ["mi_parallel_script_task.bpmn"],
      start: {"mi-parallel-script-task", @mi_start_body},
      roots_only: false
    },
    %{
      name: "call_activity",
      deploy: ["call_activity_child.bpmn", "call_activity_basic.bpmn"],
      start: {"CallActivityBasic", %{}},
      roots_only: true
    }
  ]

  setup do
    facade = Loader.facade_for_plugin("evil:test_load")
    ExamplePlugin.on_load(facade)

    EngineEventBus.register_sink(
      "test:auto_finisher",
      AutoFinisher,
      []
    )

    on_exit(fn ->
      LoadHelpers.terminate_all_process_instances()
    end)

    :ok
  end

  for {count, label, await_ms, ceiling_ms, timeout_ms} <- @batches,
      shape <- @single_shapes do
    @tag timeout: timeout_ms
    test "D: #{label} #{shape.name} PIs" do
      run_single_shape(
        "exec_#{unquote(label)}_#{unquote(shape.name)}",
        unquote(count),
        unquote(await_ms),
        unquote(ceiling_ms),
        unquote(Macro.escape(shape))
      )
    end
  end

  for {count, label, await_ms, ceiling_ms, timeout_ms} <- @batches do
    @tag timeout: timeout_ms
    test "D: #{label} mixed PIs" do
      run_mixed(
        "exec_#{unquote(label)}_mixed_standard",
        unquote(count),
        unquote(await_ms),
        unquote(ceiling_ms)
      )
    end
  end

  defp run_single_shape(workload_id, count, await_ms, ceiling_ms, shape) do
    Enum.each(shape.deploy, fn bpmn_file ->
      {201, _} = http_deploy(bpmn_file)
    end)

    {process_model_id, body} = shape.start

    run_counted_starts(workload_id, count, await_ms, ceiling_ms, shape.roots_only, fn _index ->
      {201, _} = http_start_with_sandbox_retry(process_model_id, body)
    end)
  end

  defp run_mixed(workload_id, count, await_ms, ceiling_ms) do
    {201, _} = http_deploy("linear_start_end.bpmn")
    {201, _} = http_deploy("parallel_gateway_two_branches.bpmn")
    {201, _} = http_deploy("mi_parallel_script_task.bpmn")
    {201, _} = http_deploy("call_activity_child.bpmn")
    {201, _} = http_deploy("call_activity_basic.bpmn")

    starters = [
      {"LinearStartEnd", %{}},
      {"ParallelGatewayTwoBranches", %{}},
      {"mi-parallel-script-task", @mi_start_body},
      {"CallActivityBasic", %{}}
    ]

    run_counted_starts(workload_id, count, await_ms, ceiling_ms, true, fn index ->
      {process_model_id, body} = Enum.at(starters, rem(index - 1, 4))
      {201, _} = http_start_with_sandbox_retry(process_model_id, body)
    end)
  end

  defp run_counted_starts(workload_id, count, await_ms, ceiling_ms, count_roots_only, start_one) do
    counter = CompletionCounter.start(roots_only: count_roots_only)
    queue_collector = LoadHelpers.start_queue_time_collector()

    {elapsed_ms, _} =
      LoadHelpers.measure(
        workload_id,
        fn ->
          for index <- 1..count do
            start_one.(index)
          end

          {:ok, _} = CompletionCounter.await(counter, count, await_ms)
        end,
        id: workload_id,
        kind: :execution,
        process_count: count,
        queue_time_collector: queue_collector
      )

    p99_queue_ms = LoadHelpers.queue_time_p99(queue_collector)
    IO.puts("[BENCH] #{workload_id} P99 queue_time: #{Float.round(p99_queue_ms, 1)}ms")

    assert CompletionCounter.count(counter) >= count
    assert elapsed_ms < ceiling_ms
    assert p99_queue_ms < 1_000, "P99 queue_time #{p99_queue_ms}ms exceeds 1000ms ceiling"

    LoadHelpers.stop_queue_time_collector(queue_collector)
    CompletionCounter.stop(counter)
  end

  defp http_start_with_sandbox_retry(process_model_id, body) do
    DbAssertions.with_sandbox_retry(fn ->
      http_start(process_model_id, body)
    end)
  end
end

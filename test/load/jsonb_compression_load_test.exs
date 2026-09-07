defmodule EvilEngine.Load.JsonbCompressionLoadTest do
  @moduledoc """
  Item 4 — LZ4 vs PGLZ latency gate. Opt-in via `mix test.load.hardening`.
  """
  use EvilEngine.ExecutionCase, async: false

  @moduletag :load
  @moduletag :hardening

  alias EvilEngine.Execution.ResumeRunner
  alias EvilEngine.Plugins.Loader
  alias EvilEngine.Test.CompletionCounter
  alias EvilEngine.Test.DbAssertions
  alias EvilEngine.Test.ExamplePlugin
  alias EvilEngine.Test.LoadHelpers
  alias EvilEngine.Test.PayloadCapFixtures

  @mi_start_body %{"payload" => %{"items" => [1, 2, 3]}}
  @graphql_tokens_query """
  query {
    processInstances(limit: 5) {
      results {
        id
        flowNodeInstances {
          id
          inputToken
          outputToken
        }
      }
    }
  }
  """
  @admin_claims %{"zeeky_boogie_doog" => true}

  setup do
    Application.put_env(
      :core_execution,
      :service_task_dispatch,
      EvilEngine.Plugins.RegistryDispatch
    )

    facade = Loader.facade_for_plugin("evil:test_jsonb_compression")
    ExamplePlugin.on_load(facade)

    on_exit(fn ->
      LoadHelpers.terminate_all_process_instances()
      LoadHelpers.set_jsonb_compression!("lz4")
    end)

    :ok
  end

  @tag timeout: 3_600_000
  test "LZ4 vs PGLZ p50/p95 gate on write_result, DOA, publish, resume, GraphQL" do
    count = String.to_integer(System.get_env("TDE_LOAD_COMPRESSION_COUNT") || "10000")
    five_deep_roots = min(100, count)

    # Absinthe compiles on first query. Warm once so the lz4 wave is not
    # penalised relative to the later pglz wave in the same VM.
    warmup_graphql_token_query()

    lz4 = run_compression_wave("jsonb_lz4", count, five_deep_roots)
    lz4_storage = LoadHelpers.jsonb_payload_bytes()

    LoadHelpers.set_jsonb_compression!("pglz")
    pglz_storage = LoadHelpers.jsonb_payload_bytes()

    LoadHelpers.terminate_all_process_instances()
    DbAssertions.truncate_persistence_tables()

    pglz = run_compression_wave("jsonb_pglz", count, five_deep_roots)

    IO.puts(
      "[BENCH] jsonb_gate lz4_vs_pglz storage_bytes lz4=#{lz4_storage} pglz=#{pglz_storage}"
    )

    assert_gate(lz4, pglz)
  end

  defp run_compression_wave(prefix, count, five_deep_roots) do
    deploy_wave_fixtures()

    exec_collector = LoadHelpers.start_source_query_collector()
    counter = CompletionCounter.start(roots_only: true)

    linear_body = %{"payload" => PayloadCapFixtures.mint_payload(60_000)}

    starters = [
      {"LinearStartEnd", linear_body},
      {"ParallelGatewayTwoBranches", %{}},
      {"mi-parallel-script-task", @mi_start_body},
      {"CallActivityBasic", %{}},
      {"CapDoaOversize", %{"payload" => %{"ok" => true}}},
      {"CapSendOversize", %{"payload" => %{"ok" => true}}}
    ]

    LoadHelpers.measure(
      "#{prefix}_exec",
      fn ->
        for index <- 1..count do
          {process_model_id, body} = Enum.at(starters, rem(index - 1, 6))
          {201, _} = http_start_with_retry(process_model_id, body)
        end

        await_ms = max(120_000, count * 80)
        {:ok, _} = CompletionCounter.await(counter, count, await_ms)
      end,
      id: "#{prefix}_exec",
      kind: :hardening,
      process_count: count
    )

    exec_metrics = %{
      flow_node_instances: LoadHelpers.source_latencies_ms(exec_collector, "flow_node_instances"),
      data_object_writes: LoadHelpers.source_latencies_ms(exec_collector, "data_object_writes"),
      data_objects: LoadHelpers.source_latencies_ms(exec_collector, "data_objects"),
      messages: LoadHelpers.source_latencies_ms(exec_collector, "messages")
    }

    LoadHelpers.stop_source_query_collector(exec_collector)
    CompletionCounter.stop(counter)

    for _ <- 1..five_deep_roots do
      {201, _} = http_start_with_retry("CallActivityDepth5", %{})
    end

    await_waiting_user_tasks(five_deep_roots, 180_000)

    resume_collector = LoadHelpers.start_source_query_collector()

    LoadHelpers.measure(
      "#{prefix}_resume_input_token",
      fn ->
        LoadHelpers.terminate_all_process_instances()
        {:ok, _resumed} = ResumeRunner.resume_all()
      end,
      id: "#{prefix}_resume_input_token",
      kind: :hardening,
      process_count: five_deep_roots,
      kpi_kind: :resume
    )

    resume_metrics =
      LoadHelpers.source_latencies_ms(resume_collector, "flow_node_instances")

    LoadHelpers.stop_source_query_collector(resume_collector)

    graphql_samples =
      Enum.map(1..40, fn index ->
        {elapsed_us, {200, body}} =
          :timer.tc(fn -> http_graphql(@graphql_tokens_query, %{}, @admin_claims) end)

        refute Map.get(body, "errors")
        {index, elapsed_us / 1000}
      end)
      |> Enum.drop(10)
      |> Enum.map(fn {_index, milliseconds} -> milliseconds end)

    graphql_metrics = %{
      p50: percentile(graphql_samples, 0.50),
      p95: percentile(graphql_samples, 0.95),
      count: length(graphql_samples)
    }

    LoadHelpers.measure(
      "#{prefix}_graphql_tokens",
      fn -> :ok end,
      id: "#{prefix}_graphql_tokens",
      kind: :hardening,
      process_count: 20,
      latency_samples_milliseconds: graphql_samples
    )

    %{exec: exec_metrics, resume: resume_metrics, graphql: graphql_metrics}
  end

  defp deploy_wave_fixtures do
    {201, _} = http_deploy("linear_start_end.bpmn")
    {201, _} = http_deploy("parallel_gateway_two_branches.bpmn")
    {201, _} = http_deploy("mi_parallel_script_task.bpmn")
    {201, _} = http_deploy("call_activity_child.bpmn")
    {201, _} = http_deploy("call_activity_basic.bpmn")
    {201, _} = http_deploy("cap_doa_oversize.bpmn")
    {201, _} = http_deploy("cap_send_oversize.bpmn")
    {201, _} = http_deploy("call_activity_depth_5_leaf.bpmn")
    {201, _} = http_deploy("call_activity_depth_5_l4.bpmn")
    {201, _} = http_deploy("call_activity_depth_5_l3.bpmn")
    {201, _} = http_deploy("call_activity_depth_5_l2.bpmn")
    {201, _} = http_deploy("call_activity_depth_5_l1.bpmn")
  end

  defp assert_gate(lz4, pglz) do
    pairs = [
      {"write_result/flow_node_instances", lz4.exec.flow_node_instances,
       pglz.exec.flow_node_instances},
      {"doa/data_object_writes", merge_doa(lz4.exec), merge_doa(pglz.exec)},
      {"publish/messages", lz4.exec.messages, pglz.exec.messages},
      {"resume/flow_node_instances", lz4.resume, pglz.resume},
      {"graphql/tokens", lz4.graphql, pglz.graphql}
    ]

    Enum.each(pairs, fn {label, lz4_metric, pglz_metric} ->
      IO.puts(
        "[BENCH] jsonb_gate #{label} lz4_p50=#{lz4_metric.p50} lz4_p95=#{lz4_metric.p95} " <>
          "pglz_p50=#{pglz_metric.p50} pglz_p95=#{pglz_metric.p95} " <>
          "lz4_n=#{lz4_metric.count} pglz_n=#{pglz_metric.count}"
      )

      minimum_samples = if label == "graphql/tokens", do: 20, else: 30

      if lz4_metric.count >= minimum_samples and pglz_metric.count >= minimum_samples do
        # query_time_ms is integer milliseconds; 0 vs 1 is clock resolution, not LZ4.
        millisecond_noise? = lz4_metric.p95 < 2.0 and pglz_metric.p95 < 2.0

        # GraphQL wall-clock includes Absinthe + HTTP. Sub-5ms deltas are
        # scheduler jitter, not JSONB compression (pg_column_size is identical
        # on both waves for this fixture).
        graphql_jitter? =
          label == "graphql/tokens" and
            abs(lz4_metric.p50 - pglz_metric.p50) < 5.0 and
            abs(lz4_metric.p95 - pglz_metric.p95) < 5.0

        if not millisecond_noise? and not graphql_jitter? and
             (lz4_metric.p50 > pglz_metric.p50 * 1.10 or
                lz4_metric.p95 > pglz_metric.p95 * 1.10) do
          flunk(
            "LZ4 is >10% slower than PGLZ on #{label}: " <>
              "lz4 p50=#{lz4_metric.p50} p95=#{lz4_metric.p95} " <>
              "pglz p50=#{pglz_metric.p50} p95=#{pglz_metric.p95}"
          )
        end
      else
        flunk(
          "#{label} sample count below #{minimum_samples} (lz4=#{lz4_metric.count} pglz=#{pglz_metric.count})"
        )
      end
    end)
  end

  defp merge_doa(exec) do
    writes = exec.data_object_writes
    objects = exec.data_objects

    %{
      p50: max(writes.p50, objects.p50),
      p95: max(writes.p95, objects.p95),
      count: writes.count + objects.count
    }
  end

  defp warmup_graphql_token_query do
    Enum.each(1..15, fn _index ->
      {200, body} = http_graphql(@graphql_tokens_query, %{}, @admin_claims)
      refute Map.get(body, "errors")
    end)
  end

  defp await_waiting_user_tasks(expected, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_waiting_user_tasks(expected, deadline)
  end

  defp do_await_waiting_user_tasks(expected, deadline) do
    %{rows: [[count]]} =
      EvilEngine.Persistence.Repo.query!("""
      SELECT count(*) FROM flow_node_instances
       WHERE flow_node_type = 'user_task' AND state = 'waiting'
      """)

    cond do
      count >= expected ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("waiting user tasks #{count} never reached #{expected}")

      true ->
        Process.sleep(100)
        do_await_waiting_user_tasks(expected, deadline)
    end
  end

  defp http_start_with_retry(process_model_id, body) do
    DbAssertions.with_sandbox_retry(fn -> http_start(process_model_id, body) end)
  end

  defp percentile(samples, quantile) do
    sorted = Enum.sort(samples)

    case sorted do
      [] -> 0.0
      _ -> Enum.at(sorted, min(trunc(length(sorted) * quantile), length(sorted) - 1)) / 1.0
    end
  end
end

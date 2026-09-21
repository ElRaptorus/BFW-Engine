defmodule BfwEngine.Load.PayloadCapChaosLoadTest do
  @moduledoc """
  Item 5 — 5% oversize mix under load. Opt-in via `mix test.load.hardening`.
  """
  use BfwEngine.ExecutionCase, async: false

  @moduletag :load
  @moduletag :hardening
  # ExUnit capture_log retains every warning (and, when the capture handler
  # opens debug, Ecto SQL with 64 KiB params). That buffer is not engine RSS.
  @moduletag capture_log: false

  alias BfwEngine.Persistence.Repo
  alias BfwEngine.Test.EventCollector
  alias BfwEngine.Test.LoadHelpers
  alias BfwEngine.Test.PayloadCapFixtures

  @memory_slack_bytes 32 * 1024 * 1024

  setup %{collector: collector} do
    EventCollector.silence(collector)
    previous_log_level = Logger.level()
    Logger.configure(level: :error)

    on_exit(fn ->
      Logger.configure(level: previous_log_level)
      LoadHelpers.terminate_all_process_instances()
    end)

    :ok
  end

  @tag timeout: 1_200_000
  test "payload_cap_chaos_5pct keeps memory flat and never inserts oversize messages" do
    chaos_seconds = String.to_integer(System.get_env("BFE_LOAD_CHAOS_SECONDS") || "600")

    {201, _} = http_deploy("linear_start_end.bpmn")
    {201, _} = http_deploy("user_task_simple.bpmn")
    {201, _} = http_deploy("message_start_event.bpmn")

    at_limit = PayloadCapFixtures.exactly_at_limit_payload()
    oversize = PayloadCapFixtures.oversize_payload()

    Process.put(:waiting_user_task_ids, [])

    started_at = System.monotonic_time(:millisecond)
    deadline = started_at + chaos_seconds * 1000
    memory_samples = []
    last_memory_sample_at = started_at
    index = 0

    {elapsed_ms, {final_index, memory_samples}} =
      LoadHelpers.measure(
        "payload_cap_chaos_5pct",
        fn ->
          run_chaos_loop(
            deadline,
            started_at,
            last_memory_sample_at,
            memory_samples,
            index,
            at_limit,
            oversize
          )
        end,
        id: "payload_cap_chaos_5pct",
        kind: :hardening,
        process_count: 0
      )

    assert elapsed_ms >= chaos_seconds * 1000 - 2_000
    assert final_index > 0

    warmed =
      Enum.filter(memory_samples, fn {sampled_at, _bytes} ->
        sampled_at - started_at >= 15_000
      end)

    if warmed != [] do
      {_t0, first_bytes} = List.first(warmed)
      {_t1, last_bytes} = List.last(warmed)

      assert last_bytes <= first_bytes + @memory_slack_bytes,
             "memory grew from #{first_bytes} to #{last_bytes} (slack #{@memory_slack_bytes})"
    end

    registered = LoadHelpers.count_registered_process_instances()

    assert registered < final_index,
           "registered PIs leaked: #{registered} after #{final_index} ops"
  end

  defp run_chaos_loop(
         deadline,
         started_at,
         last_memory_sample_at,
         memory_samples,
         index,
         at_limit,
         oversize
       ) do
    now = System.monotonic_time(:millisecond)

    if now >= deadline do
      {index, memory_samples}
    else
      oversize? = rem(index, 20) == 0
      payload = if oversize?, do: oversize, else: at_limit
      op = rem(index, 3)

      case op do
        0 -> chaos_start(payload, oversize?)
        1 -> chaos_trigger(payload, oversize?)
        2 -> chaos_finish(payload, oversize?)
      end

      {last_memory_sample_at, memory_samples} =
        maybe_sample_memory(now, last_memory_sample_at, memory_samples)

      target_elapsed = div((index + 1) * 1000, 50)
      actual_elapsed = now - started_at
      sleep_ms = target_elapsed - actual_elapsed
      if sleep_ms > 0, do: Process.sleep(sleep_ms)

      run_chaos_loop(
        deadline,
        started_at,
        last_memory_sample_at,
        memory_samples,
        index + 1,
        at_limit,
        oversize
      )
    end
  end

  defp chaos_start(payload, oversize?) do
    process_instances_before = table_count("process_instances")
    {status, _body} = http_start("LinearStartEnd", %{"payload" => payload})

    if oversize? do
      assert status == 413
      assert table_count("process_instances") == process_instances_before
    else
      assert status == 201
    end
  end

  defp chaos_trigger(payload, oversize?) do
    messages_before = table_count("messages")
    {status, _body} = http_trigger_message("trigger-process", payload)

    if oversize? do
      assert status == 413
      assert table_count("messages") == messages_before
    else
      assert status in [200, 201, 204]
    end
  end

  defp chaos_finish(payload, oversize?) do
    flow_node_instance_id = next_waiting_user_task_id()

    {status, _body} = http_finish_user_task(flow_node_instance_id, payload)

    if oversize? do
      assert status == 413

      Process.put(:waiting_user_task_ids, [
        flow_node_instance_id | Process.get(:waiting_user_task_ids)
      ])
    else
      assert status == 204
    end
  end

  defp next_waiting_user_task_id do
    case Process.get(:waiting_user_task_ids) do
      [flow_node_instance_id | rest] ->
        Process.put(:waiting_user_task_ids, rest)
        flow_node_instance_id

      _empty ->
        {201, body} = http_start("UserTaskSimple")
        process_instance_id = body["processInstanceId"]
        user_task = poll_fni_state(process_instance_id, "user_task", "waiting")
        user_task.id
    end
  end

  defp maybe_sample_memory(now, last_memory_sample_at, memory_samples) do
    if now - last_memory_sample_at >= 5_000 do
      sample = {now, sampled_runtime_memory_bytes()}
      {now, memory_samples ++ [sample]}
    else
      {last_memory_sample_at, memory_samples}
    end
  end

  defp sampled_runtime_memory_bytes do
    # Distribution samples sit in `:prometheus_metrics_dist` until scrape
    # (`:ets.take/2`). Production Prometheus scrapes `/metrics`; this test
    # does not, so drain here or BEAM total tracks observability, not the cap.
    _exposition = TelemetryMetricsPrometheus.Core.scrape()
    Enum.each(Process.list(), &:erlang.garbage_collect/1)
    :erlang.memory()[:total]
  end

  defp table_count(table_name) do
    %{rows: [[count]]} = Repo.query!("SELECT count(*) FROM #{table_name}")
    count
  end
end

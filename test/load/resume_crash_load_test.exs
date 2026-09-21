defmodule BfwEngine.Load.ResumeCrashLoadTest do
  @moduledoc """
  Item 7 — resume-after-crash at scale. Opt-in via `mix test.load.hardening`.
  """
  use BfwEngine.ExecutionCase, async: false

  @moduletag :load
  @moduletag :hardening

  alias BfwEngine.Execution.ResumeRunner
  alias BfwEngine.Persistence.Repo
  alias BfwEngine.Test.DbAssertions
  alias BfwEngine.Test.LoadHelpers

  setup do
    on_exit(fn -> LoadHelpers.terminate_all_process_instances() end)
    :ok
  end

  @tag timeout: 1_200_000
  test "resume after in-process crash preserves input_token, joins, and has no active_tokens table" do
    {201, _} = http_deploy("user_task_simple.bpmn")
    {201, _} = http_deploy("parallel_gateway_three_user_tasks.bpmn")
    {201, _} = http_deploy("call_activity_depth_5_leaf.bpmn")
    {201, _} = http_deploy("call_activity_depth_5_l4.bpmn")
    {201, _} = http_deploy("call_activity_depth_5_l3.bpmn")
    {201, _} = http_deploy("call_activity_depth_5_l2.bpmn")
    {201, _} = http_deploy("call_activity_depth_5_l1.bpmn")

    LoadHelpers.measure(
      "resume_crash_user_task_200",
      fn ->
        for _ <- 1..200 do
          {201, _} = http_start_with_retry("UserTaskSimple")
        end

        await_waiting_flow_nodes("UserTask_1", 200, 180_000)
      end,
      id: "resume_crash_user_task_200",
      kind: :hardening,
      process_count: 200
    )

    three_branch_ids =
      LoadHelpers.measure(
        "resume_crash_parallel_join_50",
        fn ->
          ids =
            for _ <- 1..50 do
              {201, body} = http_start_with_retry("ParallelGatewayThreeUserTasks")
              body["processInstanceId"]
            end

          await_waiting_flow_nodes("UserTask_A", 50, 180_000)
          finish_named_user_tasks("UserTask_A")
          finish_named_user_tasks("UserTask_B")
          await_pending_arrivals(100, 60_000)
          ids
        end,
        id: "resume_crash_parallel_join_50",
        kind: :hardening,
        process_count: 50
      )
      |> elem(1)

    LoadHelpers.measure(
      "resume_crash_ca_depth5_100",
      fn ->
        for _ <- 1..100 do
          {201, _} = http_start_with_retry("CallActivityDepth5")
        end

        await_waiting_flow_nodes("Activity_1", 100, 180_000, "user_task")
      end,
      id: "resume_crash_ca_depth5_100",
      kind: :hardening,
      process_count: 100
    )

    token_snapshot = snapshot_active_waiting_tokens()
    pending_before = table_count("gateway_pending_arrivals")
    running_before = running_process_instance_count()

    LoadHelpers.terminate_all_process_instances()
    assert LoadHelpers.count_registered_process_instances() == 0
    assert running_process_instance_count() == running_before

    %{rows: [[root_count]]} =
      Repo.query!("""
      SELECT count(*) FROM process_instances
       WHERE state = 'running' AND parent_process_instance_id IS NULL
      """)

    {:ok, resumed_count} = ResumeRunner.resume_all()
    assert resumed_count == root_count

    await_waiting_flow_nodes("UserTask_1", 200, 180_000)
    await_waiting_flow_nodes("UserTask_C", 50, 180_000)
    await_waiting_flow_nodes("Activity_1", 100, 180_000, "user_task")

    Enum.each(token_snapshot, fn {flow_node_instance_id, input_token} ->
      %{rows: [[reloaded]]} =
        Repo.query!(
          "SELECT input_token FROM flow_node_instances WHERE id = $1",
          [flow_node_instance_id]
        )

      assert reloaded == input_token
    end)

    assert table_count("gateway_pending_arrivals") == pending_before

    Enum.each(three_branch_ids, fn process_instance_id ->
      %{rows: [[count]]} =
        Repo.query!(
          """
          SELECT count(*) FROM gateway_pending_arrivals
           WHERE process_instance_id::text = $1
          """,
          [process_instance_id]
        )

      assert count == 2
    end)

    finish_named_user_tasks("UserTask_C")

    Enum.each(three_branch_ids, fn process_instance_id ->
      wait_for_process_instance(process_instance_id, 30_000)
      assert_pi_state!(process_instance_id, "finished")
    end)

    %{rows: [[regclass]]} = Repo.query!("SELECT to_regclass('public.active_tokens')")
    assert is_nil(regclass)
  end

  defp snapshot_active_waiting_tokens do
    %{rows: rows} =
      Repo.query!("""
      SELECT id, input_token
        FROM flow_node_instances
       WHERE state IN ('active', 'waiting')
      """)

    Map.new(rows, fn [id, token] -> {id, token} end)
  end

  defp finish_named_user_tasks(flow_node_id) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT id::text FROM flow_node_instances
         WHERE flow_node_id = $1 AND state = 'waiting'
        """,
        [flow_node_id]
      )

    Enum.each(rows, fn [flow_node_instance_id] ->
      {204, _} = http_finish_user_task(flow_node_instance_id, %{"approved" => true})
    end)
  end

  defp await_waiting_flow_nodes(flow_node_id, expected, timeout, flow_node_type \\ nil) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_waiting_flow_nodes(flow_node_id, expected, deadline, flow_node_type)
  end

  defp do_await_waiting_flow_nodes(flow_node_id, expected, deadline, flow_node_type) do
    %{rows: [[count]]} =
      case flow_node_type do
        nil ->
          Repo.query!(
            """
            SELECT count(*) FROM flow_node_instances
             WHERE flow_node_id = $1 AND state = 'waiting'
            """,
            [flow_node_id]
          )

        type ->
          Repo.query!(
            """
            SELECT count(*) FROM flow_node_instances
             WHERE flow_node_id = $1 AND flow_node_type = $2 AND state = 'waiting'
            """,
            [flow_node_id, type]
          )
      end

    cond do
      count >= expected ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("waiting #{flow_node_id} count #{count} never reached #{expected}")

      true ->
        Process.sleep(50)
        do_await_waiting_flow_nodes(flow_node_id, expected, deadline, flow_node_type)
    end
  end

  defp await_pending_arrivals(expected, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_pending_arrivals(expected, deadline)
  end

  defp do_await_pending_arrivals(expected, deadline) do
    count = table_count("gateway_pending_arrivals")

    cond do
      count >= expected ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("gateway_pending_arrivals #{count} never reached #{expected}")

      true ->
        Process.sleep(50)
        do_await_pending_arrivals(expected, deadline)
    end
  end

  defp running_process_instance_count do
    %{rows: [[count]]} =
      Repo.query!("SELECT count(*) FROM process_instances WHERE state = 'running'")

    count
  end

  defp table_count(table_name) do
    %{rows: [[count]]} = Repo.query!("SELECT count(*) FROM #{table_name}")
    count
  end

  defp http_start_with_retry(process_model_id, body \\ %{}) do
    DbAssertions.with_sandbox_retry(fn -> http_start(process_model_id, body) end)
  end
end

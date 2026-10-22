defmodule BfwEngine.Conformance.ConformanceTest do
  @moduledoc """
  YAML-driven conformance test suite.

  Specs in `test/conformance/` are the engine-independent contract: auto-tier
  specs run deploy → start → assert, and specs with a `steps:` list (or an
  `expected.start_error`) run through `ConformanceRunner.run_interactive/1`
  (vocabulary: `docs/architecture/testing.md`). The few specs marked
  `engine_internal: true` need Elixir internals and keep a hand-written test
  here.
  """
  use BfwEngine.ExecutionCase, async: false

  alias BfwEngine.Api
  alias BfwEngine.Auth.ProviderRegistry
  alias BfwEngine.Test.ConformanceRunner, as: Runner
  alias BfwEngine.Test.ConformanceSteps
  alias BfwEngine.Test.ServiceReset

  @moduletag :conformance

  defmodule FakeConformanceAuthProvider do
    @behaviour BfwEngine.Plugin.AuthProvider
    alias BfwEngine.Types.Identity

    @impl true
    def verify_and_resolve("valid-conformance-" <> user_id) do
      {:ok,
       %Identity{
         id: "conformance-#{user_id}",
         roles: ["admin"],
         groups: [],
         claims: %{
           "sub" => "conformance-#{user_id}",
           "provider" => "conformance-fake",
           "deploy_bpmn" => true,
           "lane:default" => "write"
         }
       }}
    end

    def verify_and_resolve(_token), do: {:error, :invalid_token}
  end

  setup do
    ConformanceSteps.load_example_plugin()
    :ok
  end

  for yaml_file <- Path.wildcard("test/conformance/C*.yaml") do
    spec = YamlElixir.read_from_file!(yaml_file)
    basename = Path.basename(yaml_file, ".yaml")

    declarative? =
      Map.has_key?(spec, "steps") or get_in(spec, ["expected", "start_error"]) == true

    cond do
      spec["engine_internal"] == true ->
        :ok

      spec["tier"] == "auto" ->
        @spec_data spec

        test "#{basename}: #{spec["name"]}" do
          Runner.run_auto(@spec_data)
        end

      declarative? ->
        @spec_data spec

        test "#{basename}: #{spec["name"]}" do
          Runner.run_interactive(@spec_data)
        end

      spec["type"] == "dmn" ->
        # Executed by dmn_conformance_test.exs.
        :ok

      true ->
        raise "conformance spec #{basename} is neither auto, declarative (steps / start_error), " <>
                "engine_internal, nor a DMN spec; it would never run"
    end
  end

  # ===================================================================
  # ENGINE-INTERNAL — specs marked `engine_internal: true`
  # ===================================================================

  test "C70: PI retry — checkpoint resets Data Object writes" do
    {201, _} = http_deploy("retry_checkpoint_data_objects.bpmn")
    {201, body} = http_start("RetryCheckpointDataObjects")
    process_instance_id = body["processInstanceId"]

    {:ok, _process_instance} =
      await_process_instance_state(process_instance_id, "fatal", timeout: 15_000)

    do_snapshot_before = fetch_data_object(process_instance_id, "DO_counter")
    assert do_snapshot_before != nil, "DataObject DO_counter must exist after initial run"

    assert do_snapshot_before.value["step"] == 2,
           "Before retry, DO_counter should reflect ScriptTask_B's write (step 2)"

    writes_before = fetch_data_object_writes(process_instance_id, "DO_counter")

    assert length(writes_before) == 2,
           "Before retry, there should be 2 DataObjectWrite audit rows (one per ScriptTask)"

    flow_node_instances = fetch_flow_node_instances(process_instance_id)
    script_task_a_fni = Enum.find(flow_node_instances, &(&1.flow_node_id == "ScriptTask_A"))
    assert script_task_a_fni != nil, "ScriptTask_A FNI must exist"

    {204, nil} =
      http_retry_process_instance(process_instance_id, %{
        "resetToFlowNodeInstanceId" => script_task_a_fni.id
      })

    {:ok, _pid} = poll_pi_alive(process_instance_id, 5_000)
    wait_for_process_instance(process_instance_id, 15_000)

    assert_pi_state!(process_instance_id, "fatal")

    do_snapshot_after = fetch_data_object(process_instance_id, "DO_counter")
    assert do_snapshot_after != nil, "DataObject DO_counter must still exist after retry"

    assert do_snapshot_after.value["step"] == 2,
           "After retry and re-execution, DO_counter should be at step 2 again"

    writes_after = fetch_data_object_writes(process_instance_id, "DO_counter")

    rollback_boundary_write =
      Enum.find(writes_before, &(&1.flow_node_instance_id == script_task_a_fni.id))

    assert rollback_boundary_write != nil,
           "ScriptTask_A's original write must survive the checkpoint rollback"

    writes_from_deleted_fnis =
      Enum.filter(writes_after, fn write ->
        write.created_at > rollback_boundary_write.created_at and
          write.id in Enum.map(writes_before, & &1.id)
      end)

    refute Enum.any?(writes_from_deleted_fnis),
           "DataObjectWrite rows from deleted FNIs (ScriptTask_B) must not survive rollback"

    assert length(writes_after) >= 3,
           "After retry, expect at least 3 writes: original A + re-executed A + re-executed B"
  end

  test "C78: Custom Auth Provider plugin handles authentication end-to-end" do
    {201, _} = http_deploy("linear_start_end.bpmn")

    ProviderRegistry.register_provider(FakeConformanceAuthProvider)
    on_exit(fn -> ServiceReset.provider_registry() end)

    start_body = Jason.encode!(%{})

    conn =
      Plug.Test.conn(:post, "/processes/LinearStartEnd/start", start_body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("authorization", "Bearer valid-conformance-user1")
      |> route()

    assert conn.status == 201
    response = Jason.decode!(conn.resp_body)
    process_instance_id = response["processInstanceId"]

    wait_for_process_instance(process_instance_id)
    assert_pi_state!(process_instance_id, "finished")
  end

  test "C79: Custom Auth Provider rejects invalid token (401)" do
    {201, _} = http_deploy("linear_start_end.bpmn")

    ProviderRegistry.register_provider(FakeConformanceAuthProvider)
    on_exit(fn -> ServiceReset.provider_registry() end)

    start_body = Jason.encode!(%{})

    conn =
      Plug.Test.conn(:post, "/processes/LinearStartEnd/start", start_body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("authorization", "Bearer totally-invalid-token")
      |> route()

    assert conn.status == 401
  end

  @tag :slow
  test "C117: Pending signal TTL expiry — expired signal not delivered" do
    Application.put_env(:bfw_engine, :signal_pending_ttl, "PT1S")

    on_exit(fn ->
      Application.put_env(:bfw_engine, :signal_pending_ttl, "PT60S")
    end)

    identity = %BfwEngine.Types.Identity{
      id: "test-user",
      roles: ["admin"],
      groups: [],
      claims: %{"trigger_signal" => "all"}
    }

    {:ok, publish_result} = Api.publish_signal("test-signal", identity)
    assert publish_result.pending == true

    Process.sleep(2_000)

    spec = Runner.load_spec("C117_signal_pending_ttl_expired.yaml")
    {201, _} = http_deploy(spec["fixture"])
    {201, start_body} = http_start(spec["process_model_id"], %{"payload" => %{}})
    process_instance_id = start_body["processInstanceId"]

    {:ok, waiting_fni} =
      await_waiting_flow_node_instance(process_instance_id, "intermediate_catch_event",
        timeout: 10_000
      )

    assert waiting_fni != nil
  end

  test "C88: Timer Start disable/enable — disable prevents PI, re-enable creates PI" do
    spec = Runner.load_spec("C88_timer_start_disable_enable.yaml")
    process_model_id = spec["process_model_id"]

    {201, _deploy_result} = http_deploy(spec["fixture"])
    deploy_claims = %{"deploy_bpmn" => true}

    timer_schedule = await_conformance_timer_schedule!(process_model_id, deploy_claims)
    schedule_id = timer_schedule["id"]
    process_version_id = timer_schedule["processVersionId"]
    assert is_binary(process_version_id)

    disable_conn =
      Plug.Test.conn(:put, "/timer-schedules/#{schedule_id}/disable")
      |> Plug.Conn.put_req_header("authorization", "Bearer #{sign_jwt(deploy_claims)}")
      |> route()

    assert disable_conn.status == 200

    show_body = await_conformance_timer_schedule_enabled!(schedule_id, false, deploy_claims)
    assert show_body["enabled"] == false

    enable_conn =
      Plug.Test.conn(:put, "/timer-schedules/#{schedule_id}/enable")
      |> Plug.Conn.put_req_header("authorization", "Bearer #{sign_jwt(deploy_claims)}")
      |> route()

    assert enable_conn.status == 200

    assert await_conformance_process_instance_for_version(process_version_id)
  end

  defp await_conformance_timer_schedule!(process_model_id, claims, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_conformance_timer_schedule(process_model_id, claims, deadline)
  end

  defp do_await_conformance_timer_schedule(process_model_id, claims, deadline) do
    schedules_conn =
      Plug.Test.conn(:get, "/timer-schedules")
      |> Plug.Conn.put_req_header("authorization", "Bearer #{sign_jwt(claims)}")
      |> route()

    timer_schedule =
      if schedules_conn.status == 200 do
        schedules_conn.resp_body
        |> Jason.decode!()
        |> Map.get("data", [])
        |> Enum.find(fn schedule -> schedule["processModelId"] == process_model_id end)
      else
        nil
      end

    cond do
      timer_schedule != nil ->
        timer_schedule

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("timer schedule for process #{process_model_id} did not appear")

      true ->
        Process.sleep(50)
        do_await_conformance_timer_schedule(process_model_id, claims, deadline)
    end
  end

  defp await_conformance_timer_schedule_enabled!(schedule_id, enabled, claims, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_conformance_timer_schedule_enabled(schedule_id, enabled, claims, deadline)
  end

  defp do_await_conformance_timer_schedule_enabled(schedule_id, enabled, claims, deadline) do
    show_conn =
      Plug.Test.conn(:get, "/timer-schedules/#{schedule_id}")
      |> Plug.Conn.put_req_header("authorization", "Bearer #{sign_jwt(claims)}")
      |> route()

    show_body =
      if show_conn.status == 200 do
        show_conn.resp_body
        |> Jason.decode!()
        |> Map.get("data")
      else
        nil
      end

    cond do
      is_map(show_body) and show_body["enabled"] == enabled ->
        show_body

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("timer schedule #{schedule_id} did not reach enabled=#{enabled}")

      true ->
        Process.sleep(50)
        do_await_conformance_timer_schedule_enabled(schedule_id, enabled, claims, deadline)
    end
  end

  defp await_conformance_process_instance_for_version(process_version_id, timeout \\ 10_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_conformance_process_instance_for_version(process_version_id, deadline)
  end

  defp do_await_conformance_process_instance_for_version(process_version_id, deadline) do
    require Ash.Query

    process_instances =
      BfwEngine.Persistence.Resources.ProcessInstance
      |> Ash.Query.filter(process_version_id == ^process_version_id)
      |> Ash.Query.limit(1)
      |> Ash.read!(domain: BfwEngine.Persistence.Api, authorize?: false)

    cond do
      process_instances != [] ->
        hd(process_instances).id

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("no process instance created for version #{process_version_id}")

      true ->
        Process.sleep(50)
        do_await_conformance_process_instance_for_version(process_version_id, deadline)
    end
  end
end

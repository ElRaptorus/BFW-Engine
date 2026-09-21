defmodule BfwEngine.Integration.Execution.PayloadCapBoundariesTest do
  @moduledoc """
  Layer A CAP-* matrix with real persistence.

  CAP-PI-START is covered by `test/integration/start_endpoint_test.exs` B7
  (HTTP 413 on oversize start payload). CAP-TRIGGER-MSG is covered by
  `test/integration/execution/message_events_test.exs` F7 (HTTP 413, no
  `messages` row). This file covers write_result / DOA / publish / user-task
  finish / exactly-at-limit / configurable Application env.
  """
  use BfwEngine.ExecutionCase, async: false

  require Ash.Query

  alias BfwEngine.Execution
  alias BfwEngine.Persistence.Api, as: Domain
  alias BfwEngine.Persistence.Repo
  alias BfwEngine.Persistence.Resources.DataObject
  alias BfwEngine.Persistence.Resources.DataObjectWrite
  alias BfwEngine.Plugins.Loader
  alias BfwEngine.Test.EventCollector
  alias BfwEngine.Test.ExamplePlugin
  alias BfwEngine.Test.PayloadCapFixtures
  alias BfwEngine.Types.Event

  setup do
    Application.put_env(
      :core_execution,
      :service_task_dispatch,
      BfwEngine.Plugins.RegistryDispatch
    )

    facade = Loader.facade_for_plugin("evil:test_payload_cap")
    ExamplePlugin.on_load(facade)
    :ok
  end

  describe "CAP-WRITE-RESULT" do
    test "oversize finish_async fatals the FNI and PI with no downstream FNI", %{
      collector: collector
    } do
      process_instance_id =
        http_deploy_and_start("service_task_async_park.bpmn", "ServiceTaskAsyncPark")

      service_task_fni = poll_fni_state(process_instance_id, "service_task", "waiting")

      result =
        Execution.finish_async_service_task(
          service_task_fni.id,
          PayloadCapFixtures.oversize_payload()
        )

      assert match?({:error, :payload_too_large, %{field: :fni_output}}, result) or
               match?({:error, :payload_too_large, _details}, result) or
               match?({:error, {:payload_too_large, %{field: :fni_output}}}, result) or
               match?({:error, {:payload_too_large, _details}}, result)

      poll_pi_state(process_instance_id, "fatal")
      fatal_fni = poll_fni_state(process_instance_id, "service_task", "fatal")
      assert fatal_fni.id == service_task_fni.id

      flow_node_instances = fetch_flow_node_instances(process_instance_id)

      refute Enum.any?(flow_node_instances, fn flow_node_instance ->
               flow_node_instance.flow_node_type == "end_event"
             end)

      refute has_payload_too_large_event?(collector)
    end
  end

  describe "CAP-WRITE-DO" do
    test "oversize DOA value fatals without writing data objects", %{collector: collector} do
      {201, _} = http_deploy("cap_doa_oversize.bpmn")

      {201, body} =
        http_start("CapDoaOversize", %{
          "payload" => PayloadCapFixtures.mint_payload(40_000)
        })

      process_instance_id = body["processInstanceId"]
      poll_pi_state(process_instance_id, "fatal")
      poll_fni_state(process_instance_id, "service_task", "fatal")

      assert data_object_count(process_instance_id) == 0
      assert data_object_write_count(process_instance_id) == 0

      refute Enum.any?(EventCollector.get_events(collector), fn event ->
               match?(%Event.DataObjectWritten{}, event)
             end)

      refute has_payload_too_large_event?(collector)
    end
  end

  describe "CAP-PUBLISH-MSG" do
    test "oversize send mapping does not insert a messages row" do
      {201, _} = http_deploy("cap_send_oversize.bpmn")
      messages_before = message_count()

      {201, body} =
        http_start("CapSendOversize", %{
          "payload" => PayloadCapFixtures.mint_payload(20_000)
        })

      process_instance_id = body["processInstanceId"]
      poll_pi_state(process_instance_id, "fatal")
      poll_fni_state(process_instance_id, "send_task", "fatal")

      assert message_count() == messages_before
    end
  end

  describe "CAP-TASK-FINISH" do
    test "oversize user-task result returns 413 and leaves the FNI waiting" do
      process_instance_id =
        http_deploy_and_start("user_task_simple.bpmn", "UserTaskSimple")

      user_task_fni = poll_fni_state(process_instance_id, "user_task", "waiting")

      {413, body} =
        http_finish_user_task(user_task_fni.id, PayloadCapFixtures.oversize_payload())

      assert body["error"] == "payload_too_large"

      still_waiting = poll_fni_state(process_instance_id, "user_task", "waiting")
      assert still_waiting.id == user_task_fni.id
      assert_pi_state!(process_instance_id, "running")
    end
  end

  describe "CAP-EXACTLY-AT-LIMIT" do
    test "65536 succeeds on write_result, DOA, publish, start, finish; 65537 still fails" do
      at_limit = PayloadCapFixtures.exactly_at_limit_payload()
      oversize = PayloadCapFixtures.oversize_payload()

      {201, _} = http_deploy("linear_start_end.bpmn")

      {201, _} = http_start("LinearStartEnd", %{"payload" => at_limit})

      {201, _} = http_deploy("service_task_async_park.bpmn")
      {201, park_body} = http_start("ServiceTaskAsyncPark")
      park_process_instance_id = park_body["processInstanceId"]
      park_fni = poll_fni_state(park_process_instance_id, "service_task", "waiting")
      assert :ok = Execution.finish_async_service_task(park_fni.id, at_limit)
      wait_for_process_instance(park_process_instance_id, 10_000)
      assert_pi_state!(park_process_instance_id, "finished")

      {201, _} = http_deploy("cap_doa_oversize.bpmn")

      {201, doa_body} =
        http_start("CapDoaOversize", %{"payload" => %{"ok" => true}})

      wait_for_process_instance(doa_body["processInstanceId"], 10_000)
      assert_pi_state!(doa_body["processInstanceId"], "finished")
      assert data_object_count(doa_body["processInstanceId"]) == 1

      {201, _} = http_deploy("send_receive_task.bpmn")

      {201, send_body} =
        http_start("SendReceiveTask", %{"payload" => at_limit})

      send_process_instance_id = send_body["processInstanceId"]
      poll_fni_state(send_process_instance_id, "receive_task", "waiting")
      assert message_count() >= 1

      {201, _} = http_deploy("user_task_simple.bpmn")
      {201, user_body} = http_start("UserTaskSimple")
      user_process_instance_id = user_body["processInstanceId"]
      user_task_fni = poll_fni_state(user_process_instance_id, "user_task", "waiting")
      {204, _} = http_finish_user_task(user_task_fni.id, at_limit)
      wait_for_process_instance(user_process_instance_id, 10_000)
      assert_pi_state!(user_process_instance_id, "finished")

      {413, _} = http_start("LinearStartEnd", %{"payload" => oversize})
    end
  end

  describe "CAP-CONFIGURABLE" do
    test "raising Application env to 131072 lets 65537 through and rejects 131073" do
      previous = Application.get_env(:core_execution, :token_max_bytes)

      Application.put_env(:core_execution, :token_max_bytes, 131_072)

      on_exit(fn ->
        if previous do
          Application.put_env(:core_execution, :token_max_bytes, previous)
        else
          Application.delete_env(:core_execution, :token_max_bytes)
        end
      end)

      {201, _} = http_deploy("linear_start_end.bpmn")

      {201, _} =
        http_start("LinearStartEnd", %{
          "payload" => PayloadCapFixtures.mint_payload(65_537)
        })

      {413, body} =
        http_start("LinearStartEnd", %{
          "payload" => PayloadCapFixtures.mint_payload(131_073)
        })

      assert body["error"] == "payload_too_large"
    end
  end

  defp has_payload_too_large_event?(collector) do
    EventCollector.get_events(collector)
    |> Enum.any?(fn event ->
      event.__struct__
      |> Module.split()
      |> List.last()
      |> String.contains?("PayloadTooLarge")
    end)
  end

  defp data_object_count(process_instance_id) do
    DataObject
    |> Ash.Query.filter(process_instance_id == ^process_instance_id)
    |> Ash.read!(domain: Domain, authorize?: false)
    |> length()
  end

  defp data_object_write_count(process_instance_id) do
    DataObjectWrite
    |> Ash.Query.filter(process_instance_id == ^process_instance_id)
    |> Ash.read!(domain: Domain, authorize?: false)
    |> length()
  end

  defp message_count do
    %{rows: [[count]]} = Repo.query!("SELECT count(*) FROM messages")
    count
  end
end

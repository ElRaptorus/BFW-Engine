defmodule BfwEngine.Integration.ListWaitingServiceTasksTest do
  @moduledoc """
  A parked Service Task is listed with the mapped input token, and a
  waiting User Task is not.
  """

  use BfwEngine.ExecutionCase, async: false

  alias BfwEngine.Api
  alias BfwEngine.Plugins.Loader
  alias BfwEngine.Test.ExamplePlugin

  setup do
    Application.put_env(
      :core_execution,
      :service_task_dispatch,
      BfwEngine.Plugins.RegistryDispatch
    )

    ExamplePlugin.on_load(Loader.facade_for_plugin("test:list_waiting"))

    service_version_id = gen_version_id()
    user_version_id = gen_version_id()
    deploy_fixture("service_task_mapped_park.bpmn", service_version_id)
    deploy_fixture("user_task_simple.bpmn", user_version_id)

    on_exit(fn ->
      Application.put_env(
        :core_execution,
        :service_task_dispatch,
        BfwEngine.Execution.ServiceTaskDispatch.NoOp
      )
    end)

    {:ok, service_version_id: service_version_id, user_version_id: user_version_id}
  end

  test "returns the mapped payload for a waiting service task and drops other work", %{
    service_version_id: service_version_id,
    user_version_id: user_version_id
  } do
    {:ok, service_pid, service_process_instance_id} =
      start_process(service_version_id, payload: %{"amount" => 21})

    {:ok, _user_pid, user_process_instance_id} = start_process(user_version_id)

    assert {:ok, _service_flow_node_instance} =
             await_waiting_fni_by_node_id(service_process_instance_id, "ServiceTask_Park")

    assert {:ok, _user_flow_node_instance} =
             await_waiting_fni_by_node_id(user_process_instance_id, "UserTask_1")

    assert {:ok, []} = Api.list_waiting_service_tasks([])
    assert {:ok, []} = Api.list_waiting_service_tasks(["other_implementation"])

    assert {:ok, [waiting]} = Api.list_waiting_service_tasks(["async_park"])
    assert waiting.flow_node_id == "ServiceTask_Park"
    assert waiting.process_instance_id == service_process_instance_id
    assert waiting.implementation == "async_park"
    assert waiting.input_token == %{"amount" => 42}
    assert is_binary(waiting.flow_node_instance_id)
    refute waiting.process_instance_id == user_process_instance_id

    assert :ok = Api.finish_async_service_task(waiting.flow_node_instance_id, %{"ok" => true})
    wait_for_stop(service_pid)

    assert {:ok, []} = Api.list_waiting_service_tasks(["async_park"])
  end

  test "retry maps the entering token once", %{service_version_id: service_version_id} do
    ExamplePlugin.AsyncParkPayloads.reset()

    {:ok, _pid, process_instance_id} =
      start_process(service_version_id, payload: %{"amount" => 21})

    assert {:ok, waiting} =
             await_waiting_fni_by_node_id(process_instance_id, "ServiceTask_Park")

    assert waiting.input_token == %{"amount" => 21}
    assert waiting.type_properties["mapped_input"] == %{"amount" => 42}

    assert :ok = Api.fail_async_service_task(waiting.id, "PARK_FAILED", "park failed for retry")
    assert %{state: "fatal"} = poll_pi_state(process_instance_id, "fatal")

    assert :ok =
             Api.retry_process_instance(
               process_instance_id,
               %{},
               %BfwEngine.Types.Identity{id: "test-user", roles: ["admin"], groups: []},
               skip_claims: true
             )

    assert {:ok, retried} =
             await_waiting_fni_by_node_id(process_instance_id, "ServiceTask_Park")

    assert retried.input_token == %{"amount" => 21}
    assert ExamplePlugin.AsyncParkPayloads.list() == [%{"amount" => 42}, %{"amount" => 42}]
  end

  test "falls back to the stored input token when mapped_input is absent", %{
    service_version_id: service_version_id
  } do
    {:ok, _process_instance_pid, process_instance_id} =
      start_process(service_version_id, payload: %{"amount" => 21})

    assert {:ok, waiting} =
             await_waiting_fni_by_node_id(process_instance_id, "ServiceTask_Park")

    flow_node_instance =
      Ash.get!(BfwEngine.Persistence.Resources.FlowNodeInstance, waiting.id,
        domain: BfwEngine.Persistence.Api,
        authorize?: false
      )

    type_properties =
      (flow_node_instance.type_properties || %{})
      |> Map.delete("mapped_input")
      |> Map.delete(:mapped_input)

    Ash.update!(flow_node_instance, %{type_properties: type_properties},
      domain: BfwEngine.Persistence.Api,
      authorize?: false,
      action: :update_waiting
    )

    assert {:ok, waiting_rows} = Api.list_waiting_service_tasks(["async_park"])

    listed =
      Enum.find(waiting_rows, fn row -> row.process_instance_id == process_instance_id end)

    assert listed.input_token == %{"amount" => 21}
  end

  defp wait_for_stop(pid, timeout \\ 3_000) do
    reference = Process.monitor(pid)

    receive do
      {:DOWN, ^reference, :process, ^pid, _reason} -> :ok
    after
      timeout -> flunk("Process instance did not stop within #{timeout}ms")
    end
  end
end

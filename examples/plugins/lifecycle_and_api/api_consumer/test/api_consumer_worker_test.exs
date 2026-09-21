defmodule Examples.Plugins.ApiConsumer.WorkerTest do
  use ExUnit.Case

  alias BfwEngine.EngineFacade
  alias BfwEngine.Types.Identity
  alias Examples.Plugins.ApiConsumer.Worker

  test "runs orchestration callbacks in the documented order" do
    {:ok, calls_agent} = Agent.start_link(fn -> [] end)

    append_event = fn event ->
      Agent.update(calls_agent, fn events -> events ++ [event] end)
    end

    identity = %Identity{
      id: "plugin:api-consumer-test",
      roles: ["plugin"],
      groups: ["reviewers"]
    }

    process_version_resource = %{id: "process-version-stub"}
    process_model_id = "api-demo-process"

    facade = %EngineFacade{
      engine_id: "test-engine-id",
      engine_name: "test-engine-name",
      version: "0.0.0-test",
      processes: %EngineFacade.Processes{
        deploy: fn _deploy_batch ->
          append_event.(:processes_deploy)
          {:ok, [%{process_model_id: process_model_id, version: "1.0.0"}]}
        end,
        get_latest_version: fn ^process_model_id ->
          append_event.(:processes_get_latest_version)
          {:ok, process_version_resource}
        end,
        start: fn start_arguments ->
          append_event.({:processes_start, Keyword.fetch!(start_arguments, :process_instance_id)})
          {:ok, self()}
        end
      },
      process_instances: %EngineFacade.ProcessInstances{
        get: fn process_instance_id ->
          append_event.({:process_instances_get, process_instance_id})
          {:ok, %{id: process_instance_id, state: :running}}
        end
      },
      user_tasks: %EngineFacade.UserTasks{
        finish: fn flow_node_instance_id, result_map, identity_argument ->
          append_event.(
            {:user_tasks_finish, flow_node_instance_id, result_map, identity_argument}
          )

          :ok
        end
      }
    }

    {:ok, worker_pid} =
      Worker.start_link(
        facade: facade,
        demo_user_task_flow_node_instance_id: "FlowNodeInstance_UserTask_demo",
        demo_identity: identity
      )

    Process.sleep(150)

    events = Agent.get(calls_agent, & &1)
    started_process_instance_id = find_started_process_id(events)

    assert :processes_deploy = List.first(events)

    assert :processes_get_latest_version in events
    assert {:processes_start, started_process_instance_id} in events
    assert {:process_instances_get, started_process_instance_id} in events

    assert {:user_tasks_finish, "FlowNodeInstance_UserTask_demo", %{"approved" => true}, identity} in events

    assert List.last(events) ==
             {:process_instances_get, started_process_instance_id}

    GenServer.stop(worker_pid, :normal, 5_000)
  end

  defp find_started_process_id(events) do
    case Enum.find(events, &match?({:processes_start, _}, &1)) do
      {:processes_start, process_instance_id} -> process_instance_id
      nil -> flunk("missing processes_start event")
    end
  end
end

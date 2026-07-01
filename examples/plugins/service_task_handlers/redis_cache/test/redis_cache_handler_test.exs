defmodule Examples.ServiceTaskHandlers.RedisCache.RedisCacheHandlerTest do
  use ExUnit.Case

  alias EvilEngine.BPMN.Model.FlowNode
  alias EvilEngine.BPMN.Model.FlowNodeData.ServiceTask, as: ServiceTaskData
  alias EvilEngine.Execution.HandlerContext
  alias EvilEngine.Types.Token

  alias Examples.ServiceTaskHandlers.RedisCache.RedisCacheConnection
  alias Examples.ServiceTaskHandlers.RedisCache.RedisCacheFacadeStore
  alias Examples.ServiceTaskHandlers.RedisCache.RedisCacheHandler

  setup do
    :ok = RedisCacheConnection.ensure_started()
    Agent.update(RedisCacheConnection, fn _state -> %{key_value_entries: %{}} end)

    test_pid = self()

    mock_facade = %{
      service_tasks: %{
        finish_async: fn flow_node_instance_id, result ->
          send(test_pid, {:finish_async, flow_node_instance_id, result})
          :ok
        end,
        fail_async: fn flow_node_instance_id, code, message ->
          send(test_pid, {:fail_async, flow_node_instance_id, code, message})
          :ok
        end
      }
    }

    RedisCacheFacadeStore.put(mock_facade)
    :ok
  end

  test "set stores a value and get retrieves it (async)" do
    flow_node = %FlowNode{
      id: "Task_redis",
      type: :service_task,
      type_data: %ServiceTaskData{implementation: "redis_cache"}
    }

    handler_context = %HandlerContext{
      flow_node_instance_id: "fni-set",
      process_instance_id: "process-instance-1"
    }

    set_token = %Token{
      id: "token-set",
      process_instance_id: "process-instance-1",
      payload: %{"operation" => "set", "key" => "session", "value" => "abc"}
    }

    assert {:async, "fni-set"} =
             RedisCacheHandler.handle_enter(flow_node, set_token, handler_context)

    assert_receive {:finish_async, "fni-set", set_output}, 1_000
    assert set_output["operation"] == "set"
    assert set_output["redis_status"] == "OK"

    get_context = %HandlerContext{
      flow_node_instance_id: "fni-get",
      process_instance_id: "process-instance-1"
    }

    get_token = %Token{
      id: "token-get",
      process_instance_id: "process-instance-1",
      payload: %{"operation" => "get", "key" => "session"}
    }

    assert {:async, "fni-get"} =
             RedisCacheHandler.handle_enter(flow_node, get_token, get_context)

    assert_receive {:finish_async, "fni-get", get_output}, 1_000
    assert get_output["value"] == "abc"
  end

  test "returns error synchronously on unknown operation" do
    flow_node = %FlowNode{
      id: "Task_redis",
      type: :service_task,
      type_data: %ServiceTaskData{implementation: "redis_cache"}
    }

    token = %Token{
      id: "token-bad",
      process_instance_id: "process-instance-1",
      payload: %{"operation" => "merge", "key" => "x"}
    }

    handler_context = %HandlerContext{
      flow_node_instance_id: "flow-node-instance-1",
      process_instance_id: "process-instance-1"
    }

    assert {:error, :unknown_cache_operation} =
             RedisCacheHandler.handle_enter(flow_node, token, handler_context)
  end
end

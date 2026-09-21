defmodule Examples.ServiceTaskHandlers.Echo.EchoHandlerTest do
  use ExUnit.Case

  alias BfwEngine.BPMN.Model.FlowNode
  alias BfwEngine.BPMN.Model.FlowNodeData.ServiceTask, as: ServiceTaskData
  alias BfwEngine.Execution.HandlerContext
  alias BfwEngine.Types.Token

  alias Examples.ServiceTaskHandlers.Echo.EchoFacadeStore
  alias Examples.ServiceTaskHandlers.Echo.EchoHandler

  setup do
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

    EchoFacadeStore.put(mock_facade)
    :ok
  end

  test "handle_enter returns {:async, fni_id} and completes via facade" do
    flow_node = %FlowNode{
      id: "Task_echo",
      type: :service_task,
      type_data: %ServiceTaskData{implementation: "echo"}
    }

    token = %Token{
      id: "token-1",
      process_instance_id: "process-instance-1",
      payload: %{"message" => "hello"}
    }

    handler_context = %HandlerContext{
      flow_node_instance_id: "flow-node-instance-1",
      process_instance_id: "process-instance-1"
    }

    assert {:async, "flow-node-instance-1"} =
             EchoHandler.handle_enter(flow_node, token, handler_context)

    assert_receive {:finish_async, "flow-node-instance-1", output}, 1_000
    assert output["handled_by"] == "echo"
    assert output["input"] == %{"message" => "hello"}
  end
end

defmodule Examples.ServiceTaskHandlers.RabbitmqRoundtrip.RabbitmqHandlerTest do
  use ExUnit.Case

  alias EvilEngine.BPMN.Model.FlowNode
  alias EvilEngine.BPMN.Model.FlowNodeData.ServiceTask, as: ServiceTaskData
  alias EvilEngine.Execution.HandlerContext
  alias EvilEngine.Types.Token

  alias Examples.ServiceTaskHandlers.RabbitmqRoundtrip.RabbitmqHandler

  setup do
    previous = Process.get(:examples_rabbitmq_roundtrip_capture)
    on_exit(fn -> restore_capture(previous) end)
    :ok
  end

  test "handle_enter returns async tuple and publishes with correlation id" do
    capture_process = self()
    Process.put(:examples_rabbitmq_roundtrip_capture, capture_process)

    flow_node = %FlowNode{
      id: "Task_rabbitmq",
      type: :service_task,
      type_data: %ServiceTaskData{implementation: "rabbitmq"}
    }

    token = %Token{
      id: "token-1",
      process_instance_id: "process-instance-1",
      payload: %{"message" => %{"orderId" => 99}}
    }

    handler_context = %HandlerContext{
      flow_node_instance_id: "flow-node-instance-rabbit",
      process_instance_id: "process-instance-1"
    }

    assert {:async, "flow-node-instance-rabbit"} =
             RabbitmqHandler.handle_enter(flow_node, token, handler_context)

    assert_receive {:published, %{correlation_id: "flow-node-instance-rabbit", payload: %{"orderId" => 99}}}
  end

  defp restore_capture(nil), do: Process.delete(:examples_rabbitmq_roundtrip_capture)
  defp restore_capture(value), do: Process.put(:examples_rabbitmq_roundtrip_capture, value)
end

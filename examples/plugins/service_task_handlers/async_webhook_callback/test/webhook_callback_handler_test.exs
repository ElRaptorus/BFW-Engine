defmodule Examples.ServiceTaskHandlers.WebhookCallback.WebhookCallbackHandlerTest do
  use ExUnit.Case

  alias BfwEngine.BPMN.Model.FlowNode
  alias BfwEngine.BPMN.Model.FlowNodeData.ServiceTask, as: ServiceTaskData
  alias BfwEngine.Execution.HandlerContext
  alias BfwEngine.Types.Token

  alias Examples.ServiceTaskHandlers.WebhookCallback.WebhookCallbackHandler

  test "handle_enter returns async tuple with flow node instance id" do
    flow_node = %FlowNode{
      id: "Task_webhook",
      type: :service_task,
      type_data: %ServiceTaskData{implementation: "webhook_callback"}
    }

    token = %Token{
      id: "token-1",
      process_instance_id: "process-instance-1",
      payload: %{"callback_url" => "https://partner.example/hooks/invoice"}
    }

    handler_context = %HandlerContext{
      flow_node_instance_id: "flow-node-instance-webhook",
      process_instance_id: "process-instance-1"
    }

    assert {:async, "flow-node-instance-webhook"} =
             WebhookCallbackHandler.handle_enter(flow_node, token, handler_context)
  end
end

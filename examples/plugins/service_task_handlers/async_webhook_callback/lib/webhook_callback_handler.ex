defmodule Examples.ServiceTaskHandlers.WebhookCallback.WebhookCallbackHandler do
  @moduledoc """
  Parks the Flow Node Instance in `waiting` until an external system calls back into
  the engine through `EngineFacade.ServiceTasks.finish_async/2` or `fail_async/3`.
  """

  @behaviour EvilEngine.Plugin.ServiceTaskHandler

  require Logger

  @doc "Parks the flow node instance asynchronously until an external caller finishes it via the facade."
  @impl true
  def handle_enter(_flow_node, token, handler_context) do
    flow_node_instance_id = handler_context.flow_node_instance_id
    callback_url = Map.get(token.payload, "callback_url", "https://example.com/webhook")

    Logger.info(
      "Webhook callback example parked flow node instance #{flow_node_instance_id} expecting POST at #{callback_url}"
    )

    {:async, flow_node_instance_id}
  end
end

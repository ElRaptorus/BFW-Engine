defmodule Examples.ServiceTaskHandlers.Echo.EchoHandler do
  @moduledoc """
  Minimal async Service Task handler that copies the input token
  payload into the output with a small trace field.

  Spawns a Task that immediately completes the FNI via the facade,
  demonstrating the simplest possible async handler pattern.
  """

  @behaviour EvilEngine.Plugin.ServiceTaskHandler

  @doc "Echoes the input token payload by spawning async completion."
  @impl true
  def handle_enter(_flow_node, token, handler_context) do
    flow_node_instance_id = handler_context.flow_node_instance_id
    facade = Examples.ServiceTaskHandlers.Echo.EchoFacadeStore.get()

    Task.start(fn ->
      facade.service_tasks.finish_async.(flow_node_instance_id, %{
        "handled_by" => "echo",
        "input" => token.payload
      })
    end)

    {:async, flow_node_instance_id}
  end
end

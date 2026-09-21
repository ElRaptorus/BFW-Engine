defmodule Examples.ServiceTaskHandlers.NodeScript.NodeScriptHandlerTest do
  use ExUnit.Case, async: false

  alias BfwEngine.BPMN.Model.FlowNode
  alias BfwEngine.BPMN.Model.FlowNodeData.ServiceTask, as: ServiceTaskData
  alias BfwEngine.Execution.HandlerContext
  alias BfwEngine.Types.Token

  alias Examples.ServiceTaskHandlers.NodeScript.NodeScriptFacadeStore
  alias Examples.ServiceTaskHandlers.NodeScript.NodeScriptHandler

  @scripts_directory Path.expand("../scripts", __DIR__)

  setup do
    previous_directory = Application.get_env(:node_script_example, :allowed_scripts_directory)
    previous_timeout = Application.get_env(:node_script_example, :timeout_milliseconds)

    Application.put_env(:node_script_example, :allowed_scripts_directory, @scripts_directory)
    Application.put_env(:node_script_example, :timeout_milliseconds, 10_000)

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

    NodeScriptFacadeStore.put(mock_facade)

    on_exit(fn ->
      restore_env(:node_script_example, :allowed_scripts_directory, previous_directory)
      restore_env(:node_script_example, :timeout_milliseconds, previous_timeout)
    end)

    :ok
  end

  test "handle_enter returns {:async, fni_id} and finish_async with echo.js output" do
    if System.find_executable("node") == nil or System.find_executable("sh") == nil do
      IO.warn("skipping node_script happy-path test: node or sh not installed")
    else
      assert {:async, "flow-node-instance-1"} =
               NodeScriptHandler.handle_enter(flow_node(), token(%{"message" => "hello"}), handler_context())

      assert_receive {:finish_async, "flow-node-instance-1", output}, 5_000
      assert output["handled_by"] == "node_script"
      assert output["input"]["message"] == "hello"
    end
  end

  defp flow_node do
    %FlowNode{
      id: "Task_node",
      type: :service_task,
      type_data: %ServiceTaskData{implementation: "node_script"}
    }
  end

  defp token(payload) do
    %Token{
      id: "token-1",
      process_instance_id: "process-instance-1",
      payload: payload
    }
  end

  defp handler_context do
    %HandlerContext{
      flow_node_instance_id: "flow-node-instance-1",
      process_instance_id: "process-instance-1"
    }
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end

defmodule Examples.ServiceTaskHandlers.PythonScript.PythonScriptHandlerTest do
  use ExUnit.Case, async: false

  alias BfwEngine.BPMN.Model.FlowNode
  alias BfwEngine.BPMN.Model.FlowNodeData.ServiceTask, as: ServiceTaskData
  alias BfwEngine.Execution.HandlerContext
  alias BfwEngine.Types.Token

  alias Examples.ServiceTaskHandlers.PythonScript.PythonScriptFacadeStore
  alias Examples.ServiceTaskHandlers.PythonScript.PythonScriptHandler

  @scripts_directory Path.expand("../scripts", __DIR__)

  setup do
    previous_directory = Application.get_env(:python_script_example, :allowed_scripts_directory)
    previous_timeout = Application.get_env(:python_script_example, :timeout_milliseconds)

    Application.put_env(:python_script_example, :allowed_scripts_directory, @scripts_directory)
    Application.put_env(:python_script_example, :timeout_milliseconds, 10_000)

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

    PythonScriptFacadeStore.put(mock_facade)

    on_exit(fn ->
      restore_env(:python_script_example, :allowed_scripts_directory, previous_directory)
      restore_env(:python_script_example, :timeout_milliseconds, previous_timeout)
    end)

    :ok
  end

  test "handle_enter returns {:async, fni_id} and finish_async with echo.py output" do
    if System.find_executable("python3") == nil or System.find_executable("sh") == nil do
      IO.warn("skipping python_script happy-path test: python3 or sh not installed")
    else
      assert {:async, "flow-node-instance-1"} =
               PythonScriptHandler.handle_enter(flow_node(), token(%{"message" => "hello"}), handler_context())

      assert_receive {:finish_async, "flow-node-instance-1", output}, 5_000
      assert output["handled_by"] == "python_script"
      assert output["input"]["message"] == "hello"
    end
  end

  test "fail_async with script_failed when the script exits non-zero" do
    if System.find_executable("python3") == nil or System.find_executable("sh") == nil do
      IO.warn("skipping python_script failure test: python3 or sh not installed")
    else
      assert {:async, "flow-node-instance-1"} =
               PythonScriptHandler.handle_enter(
                 flow_node(),
                 token(%{"script" => "fail.py"}),
                 handler_context()
               )

      assert_receive {:fail_async, "flow-node-instance-1", "script_failed", message}, 5_000
      assert is_binary(message)
    end
  end

  defp flow_node do
    %FlowNode{
      id: "Task_python",
      type: :service_task,
      type_data: %ServiceTaskData{implementation: "python_script"}
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

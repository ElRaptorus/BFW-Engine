defmodule Examples.ServiceTaskHandlers.NodeScript.NodeScriptHandler do
  @moduledoc """
  Async Service Task handler that runs an allowlisted Node.js script with JSON
  on stdin and completes via `finish_async` / `fail_async`.
  """

  @behaviour EvilEngine.Plugin.ServiceTaskHandler

  alias Examples.Plugins.Shared.ScriptSandbox
  alias Examples.ServiceTaskHandlers.NodeScript.NodeScriptFacadeStore

  @default_script "echo.js"

  @doc "Parks the FNI and runs the allowlisted Node.js script asynchronously."
  @impl true
  def handle_enter(_flow_node, token, handler_context) do
    flow_node_instance_id = handler_context.flow_node_instance_id
    facade = NodeScriptFacadeStore.get()
    payload = token.payload || %{}
    script_path = script_path_from_payload(payload)

    Task.start(fn ->
      complete_from_sandbox(facade, flow_node_instance_id, script_path, payload)
    end)

    {:async, flow_node_instance_id}
  end

  defp script_path_from_payload(payload) when is_map(payload) do
    cond do
      is_binary(payload["script"]) and payload["script"] != "" -> payload["script"]
      is_binary(payload[:script]) and payload[:script] != "" -> payload[:script]
      true -> @default_script
    end
  end

  defp complete_from_sandbox(facade, flow_node_instance_id, script_path, payload) do
    case ScriptSandbox.execute(script_path, payload, execution_options()) do
      {:ok, result} when is_map(result) ->
        facade.service_tasks.finish_async.(flow_node_instance_id, result)

      {:ok, _non_map} ->
        facade.service_tasks.fail_async.(
          flow_node_instance_id,
          "invalid_script_output",
          "Node.js script stdout must decode to a JSON object."
        )

      {:error, :execution_timeout} ->
        facade.service_tasks.fail_async.(
          flow_node_instance_id,
          "execution_timeout",
          "Node.js script exceeded the configured timeout."
        )

      {:error, {:script_failed, exit_status, output_binary}} ->
        facade.service_tasks.fail_async.(
          flow_node_instance_id,
          "script_failed",
          "Node.js script exited with status #{exit_status}: #{truncate_output(output_binary)}"
        )

      {:error, :node_not_found} ->
        facade.service_tasks.fail_async.(
          flow_node_instance_id,
          "interpreter_not_found",
          "The node interpreter was not found on PATH."
        )

      {:error, reason} ->
        facade.service_tasks.fail_async.(
          flow_node_instance_id,
          "script_path_rejected",
          "Node.js script could not be executed: #{inspect(reason)}"
        )
    end
  end

  defp execution_options do
    allowed_scripts_directory =
      Application.get_env(
        :node_script_example,
        :allowed_scripts_directory,
        Path.expand("scripts", Path.dirname(__DIR__))
      )

    timeout_milliseconds =
      Application.get_env(:node_script_example, :timeout_milliseconds, 30_000)

    [
      allowed_scripts_directory: allowed_scripts_directory,
      timeout_milliseconds: timeout_milliseconds
    ]
  end

  defp truncate_output(output_binary) when is_binary(output_binary) do
    String.slice(output_binary, 0, 500)
  end

  defp truncate_output(_output), do: ""
end

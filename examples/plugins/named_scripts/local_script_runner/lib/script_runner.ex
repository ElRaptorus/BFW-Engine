defmodule Examples.Plugins.LocalScriptRunner.ScriptRunner do
  @moduledoc """
  Named script `local_script` that shells out to files described by `flow_node.type_data.script`.
  """

  @behaviour EvilEngine.Plugin.NamedScript

  alias Examples.Plugins.LocalScriptRunner.ScriptSandbox

  @doc "Runs the script path from flow node type data against the token payload via the sandbox helper."
  @impl true
  def handle_enter(flow_node, payload, _context) when is_map(payload) do
    type_data = Map.get(flow_node, :type_data, %{})

    script_path =
      cond do
        is_binary(type_data[:script]) and type_data[:script] != "" ->
          type_data[:script]

        is_binary(type_data["script"]) and type_data["script"] != "" ->
          type_data["script"]

        true ->
          nil
      end

    if is_binary(script_path) do
      ScriptSandbox.execute(script_path, payload, execution_options())
    else
      {:error, :missing_inline_script_path}
    end
  end

  defp execution_options do
    allowed_scripts_directory =
      Application.get_env(
        :local_script_runner_example,
        :allowed_scripts_directory,
        Path.join(File.cwd!(), "scripts")
      )

    timeout_milliseconds =
      Application.get_env(
        :local_script_runner_example,
        :timeout_milliseconds,
        30_000
      )

    [
      allowed_scripts_directory: allowed_scripts_directory,
      timeout_milliseconds: timeout_milliseconds
    ]
  end
end

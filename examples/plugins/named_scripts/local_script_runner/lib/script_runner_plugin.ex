defmodule Examples.Plugins.LocalScriptRunner.ScriptRunnerPlugin do
  @moduledoc """
  Registers the `local_script` named script entry point.
  """

  @behaviour EvilEngine.Plugin

  alias Examples.Plugins.LocalScriptRunner.ScriptRunner

  @doc "Registers the local_script named script module with the engine facade."
  @impl true
  def on_load(facade) do
    case facade.register_named_script.("local_script", ScriptRunner) do
      :ok -> :ok
      {:error, reason} -> {:error, {:register_named_script_failed, reason}}
    end
  end

  @doc "Performs no extra work once every plugin has finished loading."
  @impl true
  def on_ready(_facade), do: :ok
end

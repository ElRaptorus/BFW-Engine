defmodule BfwEngine.Plugins.ScriptRegistryDispatch do
  @moduledoc """
  Script Task dispatch adapter backed by the Plugin Registry.

  Implements `BfwEngine.Execution.ScriptDispatch` by looking up
  `:named_script` capabilities in the Registry and matching
  on `script_key`.
  """

  @behaviour BfwEngine.Execution.ScriptDispatch

  alias BfwEngine.Plugins.Registry

  @impl true
  def lookup_script(script_ref) do
    Registry.list_capabilities(:named_script)
    |> Enum.find(fn cap -> cap.descriptor.script_key == script_ref end)
    |> case do
      nil -> {:error, :not_found}
      cap -> {:ok, cap.descriptor.module}
    end
  end
end

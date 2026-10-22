defmodule BfwEngine.Execution.ScriptDispatch do
  @moduledoc """
  Behaviour defining how Script Tasks look up their named-script plugin.

  `BfwEngine.Execution` defines this contract; the actual implementation
  lives in `BfwEngine.Plugins` as `ScriptRegistryDispatch` and is wired
  via application config (`:bfw_engine, :script_dispatch`). This
  preserves the dependency direction (Core never imports Peripheral).
  """

  @callback lookup_script(script_ref :: String.t()) ::
              {:ok, module()} | {:error, :not_found}

  @doc "Returns the configured dispatch adapter module."
  @spec adapter() :: module()
  def adapter do
    Application.get_env(:bfw_engine, :script_dispatch, __MODULE__.NoOp)
  end
end

defmodule BfwEngine.Execution.ScriptDispatch.NoOp do
  @moduledoc "No-op adapter for tests without a plugin registry."

  @behaviour BfwEngine.Execution.ScriptDispatch

  @impl true
  def lookup_script(_script_ref), do: {:error, :not_found}
end

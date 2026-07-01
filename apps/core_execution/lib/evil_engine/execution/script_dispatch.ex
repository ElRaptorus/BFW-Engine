defmodule EvilEngine.Execution.ScriptDispatch do
  @moduledoc """
  Behaviour defining how Script Tasks look up their named-script plugin.

  `core_execution` defines this contract; the actual implementation
  lives in `peripheral_plugins` as `ScriptRegistryDispatch` and is wired
  via application config (`:core_execution, :script_dispatch`). This
  preserves the dependency direction (Core never imports Peripheral).
  """

  @callback lookup_script(script_ref :: String.t()) ::
              {:ok, module()} | {:error, :not_found}

  @doc "Returns the configured dispatch adapter module."
  @spec adapter() :: module()
  def adapter do
    Application.get_env(:core_execution, :script_dispatch, __MODULE__.NoOp)
  end
end

defmodule EvilEngine.Execution.ScriptDispatch.NoOp do
  @moduledoc "No-op adapter for tests without a plugin registry."

  @behaviour EvilEngine.Execution.ScriptDispatch

  @impl true
  def lookup_script(_script_ref), do: {:error, :not_found}
end

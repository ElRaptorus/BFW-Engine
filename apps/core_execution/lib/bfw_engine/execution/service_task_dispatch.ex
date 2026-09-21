defmodule BfwEngine.Execution.ServiceTaskDispatch do
  @moduledoc """
  Behaviour defining how Service Tasks look up their plugin handler.

  `core_execution` defines this contract; the actual implementation
  lives in `peripheral_plugins` as `RegistryDispatch` and is wired via
  application config (`:core_execution, :service_task_dispatch`). This
  preserves the dependency direction (Core never imports Peripheral).
  """

  @callback lookup_handler(implementation :: String.t()) ::
              {:ok, module()} | {:error, :not_found}

  @doc "Returns the configured dispatch adapter module."
  @spec adapter() :: module()
  def adapter do
    Application.get_env(:core_execution, :service_task_dispatch, __MODULE__.NoOp)
  end
end

defmodule BfwEngine.Execution.ServiceTaskDispatch.NoOp do
  @moduledoc "No-op adapter for tests without a plugin registry."

  @behaviour BfwEngine.Execution.ServiceTaskDispatch

  @impl true
  def lookup_handler(_implementation), do: {:error, :not_found}
end

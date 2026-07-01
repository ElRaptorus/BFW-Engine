defmodule EvilEngine.Plugins.RegistryDispatch do
  @moduledoc """
  Service Task dispatch adapter backed by the Plugin Registry.

  Implements `EvilEngine.Execution.ServiceTaskDispatch` by looking up
  `:service_task_handler` capabilities in the Registry and matching
  on `implementation`.
  """

  @behaviour EvilEngine.Execution.ServiceTaskDispatch

  alias EvilEngine.Plugins.Registry

  @impl true
  def lookup_handler(implementation) do
    Registry.list_capabilities(:service_task_handler)
    |> Enum.find(fn cap -> cap.descriptor.implementation == implementation end)
    |> case do
      nil -> {:error, :not_found}
      cap -> {:ok, cap.descriptor.module}
    end
  end
end

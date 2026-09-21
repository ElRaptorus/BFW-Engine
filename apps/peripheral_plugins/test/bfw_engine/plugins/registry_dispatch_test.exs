defmodule BfwEngine.Plugins.RegistryDispatchTest do
  use ExUnit.Case, async: false

  alias BfwEngine.Plugins.Registry
  alias BfwEngine.Plugins.RegistryDispatch

  setup do
    {:ok, _} = Application.ensure_all_started(:peripheral_plugins)
    :ok
  end

  describe "lookup_handler/1" do
    test "returns {:ok, module} when a service_task_handler matches implementation" do
      plugin_name = "registry-dispatch-plugin-#{System.unique_integer([:positive])}"
      implementation = "registry-dispatch-type-#{System.unique_integer([:positive])}"

      :ok = Registry.register_plugin(plugin_name, __MODULE__)

      handler_module = BfwEngine.Plugins.Builtin.HttpServiceTaskHandler

      :ok =
        Registry.register_capability(plugin_name, :service_task_handler, %{
          implementation: implementation,
          module: handler_module
        })

      assert {:ok, handler_module} == RegistryDispatch.lookup_handler(implementation)
    end

    test "returns {:error, :not_found} when no handler matches" do
      missing_key = "no-handler-#{System.unique_integer([:positive])}"
      assert {:error, :not_found} == RegistryDispatch.lookup_handler(missing_key)
    end
  end
end

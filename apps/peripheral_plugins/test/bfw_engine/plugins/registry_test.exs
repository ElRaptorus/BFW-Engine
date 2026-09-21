defmodule BfwEngine.Plugins.RegistryTest.ValidServiceTaskHandler do
  @moduledoc false
  @behaviour BfwEngine.Plugin.ServiceTaskHandler

  @impl true
  def handle_enter(_flow_node, _token, _context), do: {:async, "stub-fni"}
end

defmodule BfwEngine.Plugins.RegistryTest.InvalidHandler do
  @moduledoc false
end

defmodule BfwEngine.Plugins.RegistryTest do
  use ExUnit.Case, async: false

  alias BfwEngine.Plugins.Registry

  @valid_handler BfwEngine.Plugins.RegistryTest.ValidServiceTaskHandler
  @invalid_handler BfwEngine.Plugins.RegistryTest.InvalidHandler

  setup do
    case Registry.start_link() do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    Registry.reset_state()
    :ok
  end

  describe "register_plugin/3" do
    test "registers a plugin and lists it" do
      assert :ok = Registry.register_plugin("test-plugin", __MODULE__, %{version: "1.0"})

      [plugin] = Registry.list_plugins()
      assert plugin.name == "test-plugin"
      assert plugin.module == __MODULE__
      assert plugin.status == :loaded
    end

    test "lists plugins in registration order" do
      :ok = Registry.register_plugin("alpha", __MODULE__)
      :ok = Registry.register_plugin("beta", __MODULE__)

      names = Registry.list_plugins() |> Enum.map(& &1.name)
      assert names == ["alpha", "beta"]
    end
  end

  describe "register_capability/3" do
    test "registers a unique capability" do
      :ok = Registry.register_plugin("my-plugin", __MODULE__)

      assert :ok =
               Registry.register_capability(
                 "my-plugin",
                 :service_task_handler,
                 %{implementation: "http"}
               )

      caps = Registry.list_capabilities(:service_task_handler)
      assert length(caps) == 1
      assert hd(caps).plugin_name == "my-plugin"
    end

    test "detects conflict on duplicate unique key" do
      :ok = Registry.register_plugin("first", __MODULE__)
      :ok = Registry.register_plugin("second", __MODULE__)

      :ok =
        Registry.register_capability("first", :service_task_handler, %{implementation: "http"})

      assert {:error, :conflict, "first"} =
               Registry.register_capability("second", :service_task_handler, %{
                 implementation: "http"
               })
    end

    test "allows multiple event_sinks (no conflict key)" do
      :ok = Registry.register_plugin("p1", __MODULE__)
      :ok = Registry.register_plugin("p2", __MODULE__)

      :ok = Registry.register_capability("p1", :event_sink, %{name: "console"})
      :ok = Registry.register_capability("p2", :event_sink, %{name: "database"})

      assert length(Registry.list_capabilities(:event_sink)) == 2
    end

    test "conflict detection for each capability type with unique keys" do
      :ok = Registry.register_plugin("a", __MODULE__)
      :ok = Registry.register_plugin("b", __MODULE__)

      for {cap_type, descriptor} <- [
            {:named_script, %{script_key: "validate"}},
            {:rest_api_extension, %{prefix: "/custom"}}
          ] do
        :ok = Registry.register_capability("a", cap_type, descriptor)
        assert {:error, :conflict, "a"} = Registry.register_capability("b", cap_type, descriptor)
      end
    end
  end

  describe "rest_api_extension reserved prefixes" do
    setup do
      :ok = Registry.register_plugin("ext-plugin", __MODULE__)
      :ok
    end

    test "rejects /processes" do
      assert {:error, :reserved_prefix} =
               Registry.register_capability("ext-plugin", :rest_api_extension, %{
                 prefix: "/processes"
               })
    end

    test "rejects /escalations" do
      assert {:error, :reserved_prefix} =
               Registry.register_capability("ext-plugin", :rest_api_extension, %{
                 prefix: "/escalations"
               })
    end

    test "rejects a nested reserved prefix" do
      assert {:error, :reserved_prefix} =
               Registry.register_capability("ext-plugin", :rest_api_extension, %{
                 prefix: "/processes/extra"
               })
    end

    test "accepts a non-reserved prefix" do
      assert :ok =
               Registry.register_capability("ext-plugin", :rest_api_extension, %{
                 prefix: "/echo-ext"
               })

      caps = Registry.list_capabilities(:rest_api_extension)
      assert hd(caps).descriptor.prefix == "/echo-ext"
    end
  end

  describe "lookup_rest_api_extension/1" do
    setup do
      :ok = Registry.register_plugin("lookup-plugin", __MODULE__)
      :ok
    end

    test "returns the longest matching prefix" do
      :ok =
        Registry.register_capability("lookup-plugin", :rest_api_extension, %{
          prefix: "/echo-ext"
        })

      :ok = Registry.register_plugin("lookup-plugin-v2", __MODULE__)

      :ok =
        Registry.register_capability("lookup-plugin-v2", :rest_api_extension, %{
          prefix: "/echo-ext/v2"
        })

      assert {:ok, %{prefix: "/echo-ext/v2", plugin_name: "lookup-plugin-v2"}} =
               Registry.lookup_rest_api_extension("/echo-ext/v2/ping")

      assert {:ok, %{prefix: "/echo-ext", plugin_name: "lookup-plugin"}} =
               Registry.lookup_rest_api_extension("/echo-ext/ping")

      assert :error = Registry.lookup_rest_api_extension("/other")
    end
  end

  describe "list_capabilities/1" do
    test "returns empty list for unregistered type" do
      assert Registry.list_capabilities(:nonexistent) == []
    end
  end

  describe "dump/0" do
    test "returns plugins and capabilities maps" do
      :ok = Registry.register_plugin("d-plugin", __MODULE__)
      :ok = Registry.register_capability("d-plugin", :event_sink, %{name: "test"})

      result = Registry.dump()
      assert is_map(result.plugins)
      assert is_map(result.capabilities)
      assert Map.has_key?(result.plugins, "d-plugin")
    end
  end

  describe "reset_state/0" do
    test "clears all state" do
      :ok = Registry.register_plugin("to-reset", __MODULE__)
      assert length(Registry.list_plugins()) == 1

      assert :ok = Registry.reset_state()
      assert Registry.list_plugins() == []
      assert Registry.list_capabilities(:event_sink) == []
    end
  end

  describe "behaviour validation" do
    setup do
      :ok = Registry.register_plugin("val-plugin", __MODULE__)
      :ok
    end

    test "6a: accepts module that implements the correct behaviour" do
      assert :ok =
               Registry.register_capability(
                 "val-plugin",
                 :service_task_handler,
                 %{implementation: "valid", module: @valid_handler}
               )

      assert length(Registry.list_capabilities(:service_task_handler)) == 1
    end

    test "6b: rejects module that does NOT implement the expected behaviour" do
      assert {:error, :invalid_handler, message} =
               Registry.register_capability(
                 "val-plugin",
                 :service_task_handler,
                 %{implementation: "bad", module: @invalid_handler}
               )

      assert message =~ "does not declare @behaviour"
      assert message =~ inspect(@invalid_handler)
      assert Registry.list_capabilities(:service_task_handler) == []
    end

    test "6c: rejects module that does not exist" do
      assert {:error, :module_not_loaded, message} =
               Registry.register_capability(
                 "val-plugin",
                 :service_task_handler,
                 %{implementation: "ghost", module: DoesNot.Exist.AtAll}
               )

      assert message =~ "could not be loaded"
      assert message =~ "DoesNot.Exist.AtAll"
      assert Registry.list_capabilities(:service_task_handler) == []
    end

    test "6d: skips validation when module is a string" do
      assert :ok =
               Registry.register_capability(
                 "val-plugin",
                 :service_task_handler,
                 %{implementation: "string-module", module: "not.an.atom.module"}
               )

      assert length(Registry.list_capabilities(:service_task_handler)) == 1
    end

    test "6e: skips validation when descriptor has no module key" do
      assert :ok =
               Registry.register_capability(
                 "val-plugin",
                 :service_task_handler,
                 %{implementation: "no-module"}
               )

      assert length(Registry.list_capabilities(:service_task_handler)) == 1
    end

    test "6f: skips validation for capability type with no defined behaviour" do
      assert :ok =
               Registry.register_capability(
                 "val-plugin",
                 :unknown_future_type,
                 %{module: @invalid_handler}
               )

      assert length(Registry.list_capabilities(:unknown_future_type)) == 1
    end
  end
end

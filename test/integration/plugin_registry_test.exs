defmodule BfwEngine.Integration.PluginRegistryTest do
  @moduledoc "Full-stack: plugin registration, conflict detection, quarantine."
  use BfwEngine.IntegrationCase, async: false

  alias BfwEngine.Events.EngineEventBus
  alias BfwEngine.Plugins.Registry
  alias BfwEngine.Test.{FakePlugin, IntegrationSink}
  alias BfwEngine.Types.Event.PluginQuarantined

  describe "registration" do
    test "registers and lists a plugin" do
      :ok = Registry.register_plugin("evil:test_plugin", FakePlugin, %{version: "1.0.0"})

      entries = Registry.list_plugins()
      assert Enum.any?(entries, &(&1.name == "evil:test_plugin"))
    end

    test "duplicate plugin name overwrites (no error)" do
      :ok = Registry.register_plugin("evil:dup_check", FakePlugin, %{version: "1.0.0"})
      :ok = Registry.register_plugin("evil:dup_check", FakePlugin, %{version: "2.0.0"})

      entries = Registry.list_plugins()
      entry = Enum.find(entries, &(&1.name == "evil:dup_check"))
      assert entry.manifest.version == "2.0.0"
    end
  end

  describe "capability conflict and quarantine" do
    test "conflicting capability emits PluginQuarantined event" do
      :ok =
        EngineEventBus.register_sink(
          "test:quarantine_observer",
          IntegrationSink,
          test_pid: self()
        )

      :ok = Registry.register_plugin("evil:first", FakePlugin, %{})
      :ok = Registry.register_plugin("evil:second", FakePlugin, %{})

      :ok =
        Registry.register_capability("evil:first", :service_task_handler, %{
          implementation: "my_task"
        })

      {:error, :conflict, "evil:first"} =
        Registry.register_capability("evil:second", :service_task_handler, %{
          implementation: "my_task"
        })

      assert_receive {:integration_sink, %PluginQuarantined{plugin_name: "evil:second"}}, 500
    end

    test "non-conflicting capabilities register fine" do
      :ok = Registry.register_plugin("evil:cap_a", FakePlugin, %{})
      :ok = Registry.register_plugin("evil:cap_b", FakePlugin, %{})

      :ok =
        Registry.register_capability("evil:cap_a", :service_task_handler, %{
          implementation: "task_a"
        })

      :ok =
        Registry.register_capability("evil:cap_b", :service_task_handler, %{
          implementation: "task_b"
        })

      caps = Registry.list_capabilities(:service_task_handler)
      assert length(caps) == 2
    end
  end
end

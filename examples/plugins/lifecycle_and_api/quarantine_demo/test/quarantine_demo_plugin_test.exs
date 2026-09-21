defmodule Examples.Plugins.QuarantineDemo.QuarantineDemoPluginTest do
  use ExUnit.Case, async: false

  alias BfwEngine.EngineFacade
  alias Examples.Plugins.QuarantineDemo.QuarantineDemoPlugin

  test "implements BfwEngine.Plugin" do
    behaviours =
      QuarantineDemoPlugin.__info__(:attributes)
      |> Keyword.get_values(:behaviour)
      |> List.flatten()

    assert BfwEngine.Plugin in behaviours
  end

  test "on_load/1 returns {:error, :intentional_quarantine} without registering" do
    facade = %EngineFacade{
      engine_id: "test-engine-id",
      engine_name: "test-engine-name",
      version: "0.0.0-test",
      register_service_task_handler: fn _implementation, _module ->
        flunk("quarantine demo must not register a service task handler")
      end,
      register_event_sink: fn _name, _module, _opts ->
        flunk("quarantine demo must not register an event sink")
      end
    }

    assert {:error, :intentional_quarantine} = QuarantineDemoPlugin.on_load(facade)
  end
end

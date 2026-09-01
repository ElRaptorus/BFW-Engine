defmodule Examples.Plugins.LifecycleAware.LifecyclePluginTest do
  use ExUnit.Case

  alias EvilEngine.EngineFacade
  alias Examples.Plugins.LifecycleAware.LifecyclePlugin

  describe "lifecycle callbacks" do
    test "on_load/1 returns :ok when registration hooks succeed" do
      facade = %EngineFacade{
        engine_id: "test-engine-id",
        engine_name: "test-engine-name",
        version: "0.0.0-test",
        register_event_sink: fn _sink_name, _sink_module, _sink_options ->
          :ok
        end,
        get_config: fn :lifecycle_demo_setting ->
          :fixture_value
        end,
        processes: %EngineFacade.Processes{
          list: fn -> {:ok, []} end
        }
      }

      assert :ok = LifecyclePlugin.on_load(facade)
    end

    test "on_ready/1 returns :ok when the process catalog is listed" do
      facade = %EngineFacade{
        engine_id: "test-engine-id",
        engine_name: "test-engine-name",
        version: "0.0.0-test",
        processes: %EngineFacade.Processes{
          list: fn ->
            {:ok, [%{id: "order-process", version: "1.0.0"}]}
          end
        }
      }

      assert :ok = LifecyclePlugin.on_ready(facade)
    end
  end
end

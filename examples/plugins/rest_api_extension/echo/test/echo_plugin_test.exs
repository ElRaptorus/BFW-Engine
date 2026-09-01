defmodule Examples.Plugins.RestApiExtension.EchoPluginTest do
  use ExUnit.Case, async: false

  alias EvilEngine.EngineFacade
  alias Examples.Plugins.RestApiExtension.EchoPlug
  alias Examples.Plugins.RestApiExtension.EchoPlugin

  test "implements EvilEngine.Plugin" do
    behaviours =
      EchoPlugin.__info__(:attributes)
      |> Keyword.get_values(:behaviour)
      |> List.flatten()

    assert EvilEngine.Plugin in behaviours
  end

  test "on_load/1 registers the /echo-ext RestApiExtension on a fake facade" do
    test_pid = self()

    facade = %EngineFacade{
      engine_id: "test-engine-id",
      engine_name: "test-engine-name",
      version: "0.0.0-test",
      register_rest_api_extension: fn prefix, module ->
        send(test_pid, {:rest_api_extension, prefix, module})
        :ok
      end
    }

    assert :ok = EchoPlugin.on_load(facade)
    assert_received {:rest_api_extension, "/echo-ext", EchoPlug}
  end

  test "on_ready/1 returns :ok" do
    facade = %EngineFacade{
      engine_id: "test-engine-id",
      engine_name: "test-engine-name",
      version: "0.0.0-test"
    }

    assert :ok = EchoPlugin.on_ready(facade)
  end
end

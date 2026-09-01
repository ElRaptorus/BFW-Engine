defmodule MyCompany.CompanyGraphPluginTest do
  use ExUnit.Case, async: false

  alias EvilEngine.EngineFacade
  alias MyCompany.CompanyGraphPlugin

  test "implements EvilEngine.Plugin" do
    behaviours =
      CompanyGraphPlugin.__info__(:attributes)
      |> Keyword.get_values(:behaviour)
      |> List.flatten()

    assert EvilEngine.Plugin in behaviours
  end

  test "on_load/1 registers the CompanyGraph auth provider on a fake facade" do
    test_pid = self()

    facade = %EngineFacade{
      engine_id: "test-engine-id",
      engine_name: "test-engine-name",
      version: "0.0.0-test",
      register_auth_provider: fn module ->
        send(test_pid, {:auth_provider, module})
        :ok
      end
    }

    assert :ok = CompanyGraphPlugin.on_load(facade)
    assert_received {:auth_provider, MyCompany.CompanyGraphAuthProvider}
  end

  test "on_ready/1 returns :ok" do
    facade = %EngineFacade{
      engine_id: "test-engine-id",
      engine_name: "test-engine-name",
      version: "0.0.0-test"
    }

    assert :ok = CompanyGraphPlugin.on_ready(facade)
  end
end

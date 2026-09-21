defmodule MyCompany.LdapPluginTest do
  use ExUnit.Case, async: false

  alias BfwEngine.EngineFacade
  alias MyCompany.LdapPlugin

  test "implements BfwEngine.Plugin" do
    behaviours =
      LdapPlugin.__info__(:attributes)
      |> Keyword.get_values(:behaviour)
      |> List.flatten()

    assert BfwEngine.Plugin in behaviours
  end

  test "on_load/1 registers the LDAP auth provider on a fake facade" do
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

    assert :ok = LdapPlugin.on_load(facade)
    assert_received {:auth_provider, MyCompany.LdapAuthProvider}
  end

  test "on_ready/1 returns :ok" do
    facade = %EngineFacade{
      engine_id: "test-engine-id",
      engine_name: "test-engine-name",
      version: "0.0.0-test"
    }

    assert :ok = LdapPlugin.on_ready(facade)
  end
end

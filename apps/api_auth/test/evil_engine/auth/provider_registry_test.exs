defmodule EvilEngine.Auth.ProviderRegistryTest do
  use ExUnit.Case, async: false

  alias EvilEngine.Auth.JwtAuthProvider
  alias EvilEngine.Auth.ProviderRegistry

  setup do
    ProviderRegistry.reset_to_default()
    on_exit(fn -> ProviderRegistry.reset_to_default() end)
    :ok
  end

  defmodule FakeProvider do
    @behaviour EvilEngine.Plugin.AuthProvider
    alias EvilEngine.Types.Identity

    @impl true
    def verify_and_resolve("valid-custom-" <> user_id) do
      {:ok, %Identity{id: user_id, roles: ["custom"], groups: [], claims: %{"sub" => user_id}}}
    end

    def verify_and_resolve(_token), do: {:error, :invalid_token}
  end

  describe "default state" do
    test "active_provider/0 returns JwtAuthProvider by default" do
      assert ProviderRegistry.active_provider() == JwtAuthProvider
    end
  end

  describe "register_provider/1" do
    test "replaces the default with a plugin provider" do
      assert :ok = ProviderRegistry.register_provider(FakeProvider)
      assert ProviderRegistry.active_provider() == FakeProvider
    end

    test "second registration returns {:error, :already_registered}" do
      assert :ok = ProviderRegistry.register_provider(FakeProvider)
      assert {:error, :already_registered} = ProviderRegistry.register_provider(SomeOtherModule)
      assert ProviderRegistry.active_provider() == FakeProvider
    end
  end

  describe "verify_and_resolve/1" do
    test "dispatches to the active provider" do
      ProviderRegistry.register_provider(FakeProvider)

      assert {:ok, identity} = ProviderRegistry.verify_and_resolve("valid-custom-abc")
      assert identity.id == "abc"
      assert identity.roles == ["custom"]
    end

    test "returns error from active provider for invalid tokens" do
      ProviderRegistry.register_provider(FakeProvider)

      assert {:error, :invalid_token} = ProviderRegistry.verify_and_resolve("bad-token")
    end

    test "dispatches to default JWT provider when no plugin registered" do
      assert ProviderRegistry.active_provider() == JwtAuthProvider
    end
  end

  describe "reset_to_default/0" do
    test "restores JwtAuthProvider after plugin registration" do
      ProviderRegistry.register_provider(FakeProvider)
      assert ProviderRegistry.active_provider() == FakeProvider

      ProviderRegistry.reset_to_default()
      assert ProviderRegistry.active_provider() == JwtAuthProvider
    end

    test "allows re-registration after reset" do
      ProviderRegistry.register_provider(FakeProvider)
      ProviderRegistry.reset_to_default()
      assert :ok = ProviderRegistry.register_provider(FakeProvider)
      assert ProviderRegistry.active_provider() == FakeProvider
    end
  end
end

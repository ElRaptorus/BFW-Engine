defmodule BfwEngine.Auth.ProviderRegistryTest do
  use ExUnit.Case, async: false

  alias BfwEngine.Auth.JwtAuthProvider
  alias BfwEngine.Auth.ProviderRegistry
  alias BfwEngine.Auth.ServiceReset

  setup do
    ServiceReset.provider_registry()
    on_exit(fn -> ServiceReset.provider_registry() end)
    :ok
  end

  defmodule FakeProvider do
    @behaviour BfwEngine.Plugin.AuthProvider
    alias BfwEngine.Types.Identity

    @impl true
    def verify_and_resolve("valid-custom-" <> user_id) do
      {:ok, %Identity{id: user_id, roles: ["custom"], groups: [], claims: %{"sub" => user_id}}}
    end

    def verify_and_resolve("blank-id"),
      do: {:ok, %Identity{id: "  ", roles: [], groups: [], claims: %{}}}

    def verify_and_resolve("nil-id"),
      do: {:ok, %Identity{id: nil, roles: [], groups: [], claims: %{}}}

    def verify_and_resolve("integer-id"),
      do: {:ok, %Identity{id: 42, roles: [], groups: [], claims: %{}}}

    def verify_and_resolve("malformed-fields"),
      do: {:ok, %Identity{id: "malformed", roles: nil, groups: "admins", claims: nil}}

    def verify_and_resolve("claims-as-list"),
      do:
        {:ok,
         %Identity{id: "listed", roles: ["reader"], groups: ["team"], claims: [{"sub", "listed"}]}}

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

    test "rejects a plugin identity whose id is blank or not a string" do
      ProviderRegistry.register_provider(FakeProvider)

      for token <- ["blank-id", "nil-id", "integer-id"] do
        assert {:error, :missing_subject} = ProviderRegistry.verify_and_resolve(token)
      end
    end

    test "normalises nil claims to an empty map and non-list roles and groups to empty lists" do
      ProviderRegistry.register_provider(FakeProvider)

      assert {:ok, identity} = ProviderRegistry.verify_and_resolve("malformed-fields")
      assert identity.id == "malformed"
      assert identity.claims == %{}
      assert identity.roles == []
      assert identity.groups == []
    end

    test "replaces non-map claims but keeps well-formed roles and groups" do
      ProviderRegistry.register_provider(FakeProvider)

      assert {:ok, identity} = ProviderRegistry.verify_and_resolve("claims-as-list")
      assert identity.claims == %{}
      assert identity.roles == ["reader"]
      assert identity.groups == ["team"]
    end

    test "keeps a well-formed provider identity unchanged" do
      ProviderRegistry.register_provider(FakeProvider)

      assert {:ok, identity} = ProviderRegistry.verify_and_resolve("valid-custom-abc")
      assert identity.claims == %{"sub" => "abc"}
      assert identity.roles == ["custom"]
      assert identity.groups == []
    end

    test "dispatches to default JWT provider when no plugin registered" do
      assert ProviderRegistry.active_provider() == JwtAuthProvider
    end
  end

  describe "reset_to_default/0" do
    test "restores JwtAuthProvider after plugin registration" do
      ProviderRegistry.register_provider(FakeProvider)
      assert ProviderRegistry.active_provider() == FakeProvider

      ServiceReset.provider_registry()
      assert ProviderRegistry.active_provider() == JwtAuthProvider
    end

    test "allows re-registration after reset" do
      ProviderRegistry.register_provider(FakeProvider)
      ServiceReset.provider_registry()
      assert :ok = ProviderRegistry.register_provider(FakeProvider)
      assert ProviderRegistry.active_provider() == FakeProvider
    end
  end
end

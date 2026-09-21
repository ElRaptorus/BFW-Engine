defmodule BfwEngine.Integration.AuthProviderPluginTest do
  @moduledoc "Integration tests for pluggable auth provider."
  use BfwEngine.IntegrationCase, async: false

  alias BfwEngine.Auth.ProviderRegistry
  alias BfwEngine.Types.Identity

  setup do
    ProviderRegistry.reset_to_default()
    on_exit(fn -> ProviderRegistry.reset_to_default() end)
    :ok
  end

  defmodule FakeAuthProvider do
    @behaviour BfwEngine.Plugin.AuthProvider
    alias BfwEngine.Types.Identity

    @impl true
    def verify_and_resolve("valid-custom-" <> user_id) do
      {:ok,
       %Identity{
         id: "custom-#{user_id}",
         roles: ["custom-role"],
         groups: ["custom-group"],
         claims: %{
           "sub" => "custom-#{user_id}",
           "provider" => "fake"
         }
       }}
    end

    def verify_and_resolve(_token), do: {:error, :invalid_token}
  end

  defmodule SecondFakeProvider do
    @behaviour BfwEngine.Plugin.AuthProvider
    alias BfwEngine.Types.Identity

    @impl true
    def verify_and_resolve(_token),
      do: {:ok, %Identity{id: "second", roles: [], groups: [], claims: %{}}}
  end

  describe "(i) custom auth provider end-to-end" do
    test "registered custom provider handles HTTP requests" do
      with_config(:api_auth, :auth_disabled, false, fn ->
        ProviderRegistry.register_provider(FakeAuthProvider)

        conn =
          conn(:get, "/stats")
          |> put_req_header("authorization", "Bearer valid-custom-token")
          |> route()

        assert conn.status == 200
      end)
    end
  end

  describe "(ii) built-in JWT continues as default" do
    test "JWT auth works without registering a custom provider" do
      with_config(:api_auth, :auth_disabled, false, fn ->
        conn = conn_with_auth(:get, "/stats", %{"sub" => "default-user"}) |> route()
        assert conn.status == 200
      end)
    end
  end

  describe "(iii) custom provider rejects invalid tokens" do
    test "invalid token returns 401" do
      with_config(:api_auth, :auth_disabled, false, fn ->
        ProviderRegistry.register_provider(FakeAuthProvider)

        conn =
          conn(:get, "/stats")
          |> put_req_header("authorization", "Bearer bad-token")
          |> route()

        assert conn.status == 401
      end)
    end
  end

  describe "(iv) duplicate provider registration rejected" do
    test "second registration returns {:error, :already_registered}" do
      assert :ok = ProviderRegistry.register_provider(FakeAuthProvider)
      assert {:error, :already_registered} = ProviderRegistry.register_provider(SecondFakeProvider)
      assert ProviderRegistry.active_provider() == FakeAuthProvider
    end
  end

  describe "provider registry integration with Plugin Registry" do
    test "auth_provider capability registers via Plugin Registry" do
      alias BfwEngine.Plugins.Registry

      result =
        Registry.register_capability(
          "test-auth-plugin",
          :auth_provider,
          %{module: FakeAuthProvider}
        )

      assert result == :ok

      caps = Registry.list_capabilities(:auth_provider)
      assert length(caps) == 1
      assert hd(caps).descriptor.module == FakeAuthProvider
    end

    test "second auth_provider capability is rejected as conflict" do
      alias BfwEngine.Plugins.Registry

      Registry.register_plugin("plugin-a", __MODULE__, %{})
      Registry.register_plugin("plugin-b", __MODULE__, %{})

      assert :ok =
               Registry.register_capability(
                 "plugin-a",
                 :auth_provider,
                 %{module: FakeAuthProvider}
               )

      assert {:error, :conflict, "plugin-a"} =
               Registry.register_capability(
                 "plugin-b",
                 :auth_provider,
                 %{module: SecondFakeProvider}
               )
    end
  end
end

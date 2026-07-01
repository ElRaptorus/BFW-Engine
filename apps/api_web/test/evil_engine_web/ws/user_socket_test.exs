defmodule EvilEngineWeb.Ws.UserSocketTest do
  use ExUnit.Case, async: false

  alias EvilEngine.Auth.ProviderRegistry
  alias EvilEngine.Types.Identity
  alias EvilEngineWeb.Ws.UserSocket

  @test_secret "test_only_secret_at_least_32_bytes!"

  setup do
    ProviderRegistry.reset_to_default()
    ensure_test_secret()
    on_exit(fn -> ProviderRegistry.reset_to_default() end)
    :ok
  end

  defmodule FakeSocketProvider do
    @behaviour EvilEngine.Plugin.AuthProvider
    alias EvilEngine.Types.Identity

    @impl true
    def verify_and_resolve("custom-socket-" <> id) do
      {:ok, %Identity{id: id, roles: ["ws-custom"], groups: [], claims: %{"sub" => id}}}
    end

    def verify_and_resolve(_token), do: {:error, :invalid_token}
  end

  describe "connect/3 with auth enabled" do
    test "valid JWT assigns an %Identity{} struct (not raw claims)" do
      with_auth_enabled(fn ->
        token = sign_jwt(%{"sub" => "ws-user-1", "roles" => ["viewer"]})
        socket = %Phoenix.Socket{endpoint: EvilEngineWeb.Http.Endpoint}

        assert {:ok, socket} = UserSocket.connect(%{"token" => token}, socket, %{})
        assert %Identity{} = socket.assigns.identity
        assert socket.assigns.identity.id == "ws-user-1"
        assert socket.assigns.identity.roles == ["viewer"]
      end)
    end

    test "invalid token returns :error" do
      with_auth_enabled(fn ->
        socket = %Phoenix.Socket{endpoint: EvilEngineWeb.Http.Endpoint}
        assert :error = UserSocket.connect(%{"token" => "not.a.valid.jwt"}, socket, %{})
      end)
    end

    test "missing token param returns :error" do
      with_auth_enabled(fn ->
        socket = %Phoenix.Socket{endpoint: EvilEngineWeb.Http.Endpoint}
        assert :error = UserSocket.connect(%{}, socket, %{})
      end)
    end
  end

  describe "connect/3 with auth disabled" do
    test "assigns anonymous %Identity{}" do
      with_auth_disabled(fn ->
        socket = %Phoenix.Socket{endpoint: EvilEngineWeb.Http.Endpoint}
        assert {:ok, socket} = UserSocket.connect(%{"token" => "anything"}, socket, %{})
        assert %Identity{id: "anonymous"} = socket.assigns.identity
      end)
    end

    test "works without token param" do
      with_auth_disabled(fn ->
        socket = %Phoenix.Socket{endpoint: EvilEngineWeb.Http.Endpoint}
        assert {:ok, socket} = UserSocket.connect(%{}, socket, %{})
        assert %Identity{id: "anonymous"} = socket.assigns.identity
      end)
    end
  end

  describe "connect/3 with custom auth provider" do
    test "dispatches to the registered provider" do
      with_auth_enabled(fn ->
        ProviderRegistry.register_provider(FakeSocketProvider)

        socket = %Phoenix.Socket{endpoint: EvilEngineWeb.Http.Endpoint}

        assert {:ok, socket} =
                 UserSocket.connect(%{"token" => "custom-socket-42"}, socket, %{})

        assert %Identity{id: "42", roles: ["ws-custom"]} = socket.assigns.identity
      end)
    end

    test "custom provider rejects invalid tokens" do
      with_auth_enabled(fn ->
        ProviderRegistry.register_provider(FakeSocketProvider)

        socket = %Phoenix.Socket{endpoint: EvilEngineWeb.Http.Endpoint}
        assert :error = UserSocket.connect(%{"token" => "bad-token"}, socket, %{})
      end)
    end
  end

  describe "id/1" do
    test "returns user_socket:<id> from identity" do
      socket = %Phoenix.Socket{
        assigns: %{identity: %Identity{id: "user-7", roles: [], groups: [], claims: %{}}}
      }

      assert UserSocket.id(socket) == "user_socket:user-7"
    end

    test "returns nil when no identity assigned" do
      socket = %Phoenix.Socket{assigns: %{}}
      assert UserSocket.id(socket) == nil
    end
  end

  # --- Helpers ---

  defp ensure_test_secret do
    case Application.get_env(:api_auth, :hs256_secret) do
      nil -> Application.put_env(:api_auth, :hs256_secret, @test_secret)
      _ -> :ok
    end
  end

  defp sign_jwt(claims) do
    secret = Application.get_env(:api_auth, :hs256_secret) || @test_secret
    jwk = JOSE.JWK.from_oct(secret)

    defaults = %{
      "exp" => DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_unix(),
      "iat" => DateTime.utc_now() |> DateTime.to_unix()
    }

    merged = Map.merge(defaults, claims)
    {_, compact} = JOSE.JWT.sign(jwk, %{"alg" => "HS256"}, merged) |> JOSE.JWS.compact()
    compact
  end

  defp with_auth_enabled(fun) do
    previous = Application.get_env(:api_auth, :auth_disabled)
    Application.put_env(:api_auth, :auth_disabled, false)

    try do
      fun.()
    after
      Application.put_env(:api_auth, :auth_disabled, previous)
    end
  end

  defp with_auth_disabled(fun) do
    previous = Application.get_env(:api_auth, :auth_disabled)
    Application.put_env(:api_auth, :auth_disabled, true)

    try do
      fun.()
    after
      Application.put_env(:api_auth, :auth_disabled, previous)
    end
  end
end

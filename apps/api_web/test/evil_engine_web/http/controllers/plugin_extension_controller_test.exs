defmodule EvilEngineWeb.Http.PluginExtensionControllerTest.EchoPlug do
  @moduledoc false
  @behaviour Plug
  @behaviour EvilEngine.Plugin.RestApiExtension

  import Plug.Conn

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{path_info: ["ping"]} = conn, _opts) do
    identity_id =
      case conn.assigns[:identity] do
        %{id: id} -> id
        _ -> nil
      end

    body = Jason.encode!(%{pong: true, identityId: identity_id})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  def call(conn, _opts) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(404, Jason.encode!(%{error: "not_found"}))
  end
end

defmodule EvilEngineWeb.Http.PluginExtensionControllerTest do
  @moduledoc false

  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias EvilEngine.Auth.ProviderRegistry
  alias EvilEngine.Plugins.Registry
  alias EvilEngine.Test.HttpAuthHelper
  alias EvilEngineWeb.Http.PluginExtensionControllerTest.EchoPlug

  @router EvilEngineWeb.Http.Router

  setup do
    ProviderRegistry.reset_to_default()

    case Registry.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    Registry.reset_state()
    :ok = Registry.register_plugin("echo-test", __MODULE__)

    :ok =
      Registry.register_capability("echo-test", :rest_api_extension, %{
        prefix: "/echo-ext",
        module: EchoPlug
      })

    previous = Application.get_env(:api_auth, :auth_disabled)
    Application.put_env(:api_auth, :auth_disabled, false)

    on_exit(fn ->
      Application.put_env(:api_auth, :auth_disabled, previous)
      Registry.reset_state()
    end)

    :ok
  end

  defp call(conn) do
    @router.call(conn, @router.init([]))
  end

  describe "GET /echo-ext/ping" do
    test "returns 200 with a valid JWT and does not require engine claims" do
      token = HttpAuthHelper.sign_jwt(%{"sub" => "echo-user"})

      conn =
        conn(:get, "/echo-ext/ping")
        |> put_req_header("authorization", "Bearer #{token}")
        |> call()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["pong"] == true
      assert body["identityId"] == "echo-user"
    end

    test "returns 401 without a JWT" do
      conn = conn(:get, "/echo-ext/ping") |> call()

      assert conn.status == 401
      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "unauthorized"
    end
  end

  describe "engine routes still win" do
    test "GET /stats is not captured by the plugin catch-all" do
      token = HttpAuthHelper.sign_jwt()

      conn =
        conn(:get, "/stats")
        |> put_req_header("authorization", "Bearer #{token}")
        |> call()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert Map.has_key?(body, "engine")
    end
  end

  describe "unknown plugin path" do
    test "returns 404 for an unmatched authenticated path" do
      token = HttpAuthHelper.sign_jwt()

      conn =
        conn(:get, "/no-such-extension/ping")
        |> put_req_header("authorization", "Bearer #{token}")
        |> call()

      assert conn.status == 404
      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "not_found"
    end
  end
end

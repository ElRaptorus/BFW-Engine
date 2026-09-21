defmodule BfwEngine.IntegrationCase do
  @moduledoc """
  Shared setup for full-stack integration tests.

  Boots with all OTP apps running. Resets the EngineEventBus and Plugin
  Registry state between tests without restarting processes (avoids
  supervisor restart-budget exhaustion).

  ## Usage

      defmodule MyIntegrationTest do
        use BfwEngine.IntegrationCase

        test "something end to end" do
          conn = conn_with_auth(:get, "/stats", %{"sub" => "op-1"})
          assert route(conn).status == 200
        end
      end
  """

  use ExUnit.CaseTemplate

  @test_secret "test_only_secret_at_least_32_bytes!"

  using do
    quote do
      import Plug.Test
      import Plug.Conn
      import BfwEngine.IntegrationCase
    end
  end

  setup do
    BfwEngine.Events.EngineEventBus.reset_state()
    BfwEngine.Plugins.Registry.reset_state()
    BfwEngine.Auth.ProviderRegistry.reset_to_default()
    BfwEngine.BPMN.ModelCache.reset_state()
    ensure_test_secret()
    terminate_all_process_instances()
    :ok
  end

  defp terminate_all_process_instances do
    children = DynamicSupervisor.which_children(BfwEngine.Execution.Supervisor)

    Enum.each(children, fn {_, pid, _, _} ->
      DynamicSupervisor.terminate_child(BfwEngine.Execution.Supervisor, pid)
    end)
  rescue
    _ -> :ok
  end

  defp ensure_test_secret do
    case Application.get_env(:api_auth, :hs256_secret) do
      nil -> Application.put_env(:api_auth, :hs256_secret, @test_secret)
      _ -> :ok
    end
  end

  @doc "Sign a test JWT with HS256."
  def sign_jwt(claims \\ %{}) do
    secret = Application.get_env(:api_auth, :hs256_secret) || @test_secret
    jwk = JOSE.JWK.from_oct(secret)

    defaults = %{
      "exp" => DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_unix(),
      "iat" => DateTime.utc_now() |> DateTime.to_unix(),
      "lane:default" => "write"
    }

    merged = Map.merge(defaults, claims)
    {_, compact} = JOSE.JWT.sign(jwk, %{"alg" => "HS256"}, merged) |> JOSE.JWS.compact()
    compact
  end

  @doc "Build a conn with a valid Bearer header."
  def conn_with_auth(method, path, claims \\ %{}) do
    token = sign_jwt(claims)

    Plug.Test.conn(method, path)
    |> Plug.Conn.put_req_header("authorization", "Bearer #{token}")
  end

  @doc "Send a conn through the full HTTP Endpoint (includes Plug.Parsers)."
  def route(conn) do
    BfwEngineWeb.Http.Endpoint.call(conn, BfwEngineWeb.Http.Endpoint.init([]))
  end

  @doc "Temporarily override an app config key for the duration of `fun`."
  def with_config(app, key, value, fun) do
    previous = Application.get_env(app, key)
    Application.put_env(app, key, value)

    try do
      fun.()
    after
      if previous == nil,
        do: Application.delete_env(app, key),
        else: Application.put_env(app, key, previous)
    end
  end
end

defmodule BfwEngine.IntegrationCase do
  @moduledoc """
  Shared setup for full-stack integration tests.

  Boots with all OTP apps running. Restarts the supervised EngineEventBus,
  plugin registry, auth provider registry, and BPMN model cache between
  tests. `Supervisor.terminate_child/2` plus `restart_child/2` does not
  consume the supervisor crash budget.

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

  alias BfwEngine.Test.ServiceReset

  @test_secret "test_only_secret_at_least_32_bytes!"

  using do
    quote do
      import Plug.Test
      import Plug.Conn
      import BfwEngine.IntegrationCase
    end
  end

  setup do
    ServiceReset.engine_event_bus()
    ServiceReset.plugin_registry()
    ServiceReset.provider_registry()
    ServiceReset.bpmn_model_cache()
    ensure_test_secret()
    terminate_all_process_instances()
    checkout_persistence()
    :ok
  end

  # `/stats` and other endpoints query the database; the sandbox pool needs an
  # owner for the test process.
  defp checkout_persistence do
    if BfwEngine.Test.DbAssertions.sandbox_pool?() do
      for repo <- [BfwEngine.Persistence.Repo, BfwEngine.Persistence.ReadRepo] do
        Ecto.Adapters.SQL.Sandbox.checkout(repo, ownership_timeout: 300_000)
        Ecto.Adapters.SQL.Sandbox.mode(repo, {:shared, self()})
      end
    end
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
    case Application.get_env(:bfw_engine, :hs256_secret) do
      nil -> Application.put_env(:bfw_engine, :hs256_secret, @test_secret)
      _ -> :ok
    end
  end

  @doc "Sign a test JWT with HS256."
  def sign_jwt(claims \\ %{}) do
    BfwEngine.Test.AuthHelper.sign_jwt(Map.merge(%{"lane:default" => "write"}, claims))
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

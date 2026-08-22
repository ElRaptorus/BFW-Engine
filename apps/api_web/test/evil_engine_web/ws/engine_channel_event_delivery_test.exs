defmodule EvilEngineWeb.Ws.EngineChannelEventDeliveryTest do
  @moduledoc """
  Verifies real engine event delivery through the `engine:events` WebSocket
  channel with the camelCase envelope format (camelCase JSON structure).
  """
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test
  import Phoenix.ChannelTest

  alias Ecto.Adapters.SQL.Sandbox
  alias EvilEngine.Auth.ProviderRegistry
  alias EvilEngine.BPMN.ModelCache
  alias EvilEngine.Events.EngineEventBus
  alias EvilEngine.Events.MessageSubscriptions
  alias EvilEngine.Events.SignalSubscriptions
  alias EvilEngine.Persistence.ReadRepo
  alias EvilEngine.Persistence.Repo
  alias EvilEngine.Plugins.Registry, as: PluginRegistry
  alias EvilEngine.Types.Identity
  alias EvilEngineWeb.Http.Endpoint
  alias EvilEngineWeb.Ws.EngineChannel
  alias EvilEngineWeb.Ws.Sinks.WebSocket, as: WebSocketSink
  alias EvilEngineWeb.Ws.UserSocket

  @endpoint EvilEngineWeb.Http.Endpoint
  @test_secret "test_only_secret_at_least_32_bytes!"
  @fixtures_dir Path.expand("../../../../../test/fixtures/bpmns", __DIR__)

  setup do
    EngineEventBus.reset_state()
    MessageSubscriptions.reset_state()
    MessageSubscriptions.mark_ready()
    SignalSubscriptions.reset_state()
    SignalSubscriptions.mark_ready()
    PluginRegistry.reset_state()
    ProviderRegistry.reset_to_default()
    ModelCache.reset_state()
    terminate_all_process_instances()
    ensure_test_secret()

    Application.put_env(
      :core_execution,
      :persistence_adapter,
      EvilEngine.Persistence.ExecutionAdapter
    )

    Application.put_env(
      :core_execution,
      :decision_resolver,
      EvilEngine.Persistence.DecisionResolverImpl
    )

    :ok = EngineEventBus.register_sink("websocket", WebSocketSink, [])

    try do
      :ok = Sandbox.checkout(Repo)
      Sandbox.mode(Repo, {:shared, self()})
      :ok = Sandbox.checkout(ReadRepo)
      Sandbox.mode(ReadRepo, {:shared, self()})
    rescue
      _ -> :ok
    end

    on_exit(fn ->
      Application.delete_env(:core_execution, :persistence_adapter)
      Application.delete_env(:core_execution, :decision_resolver)
      ProviderRegistry.reset_to_default()
      EngineEventBus.reset_state()
    end)

    :ok
  end

  describe "engine:events channel event delivery" do
    test "delivers ProcessInstanceStateChanged with camelCase envelope after starting a linear process" do
      identity = %Identity{
        id: "test-user",
        roles: [],
        groups: [],
        claims: %{"lane:default" => true}
      }

      socket =
        socket(UserSocket, "user:#{identity.id}", %{identity: identity})

      assert {:ok, _, channel_socket} =
               subscribe_and_join(socket, EngineChannel, "engine:events", %{})

      assert channel_socket.topic == "engine:events"

      case deploy_linear_process() do
        :ok ->
          :ok

        {:error, deploy_result} ->
          flunk("failed to deploy linear process: #{inspect(deploy_result)}")
      end

      {201, start_body} = http_start("LinearStartEnd", %{})
      process_instance_id = start_body["processInstanceId"]

      wait_for_process_instance(process_instance_id)

      payload = await_process_instance_state_changed_push()

      assert %{
               "type" => "ProcessInstanceStateChanged",
               "data" => data,
               "occurredAt" => occurred_at
             } = payload

      assert is_binary(process_instance_id)
      assert data["processInstanceId"] == process_instance_id
      assert data["processModelId"] == "LinearStartEnd"
      assert is_binary(data["version"])
      assert Map.has_key?(data, "newState")
      assert Map.has_key?(data, "oldState")
      refute Map.has_key?(data, "process_instance_id")
      refute Map.has_key?(data, "new_state")
      assert occurred_at != nil
    end
  end

  # ---------------------------------------------------------------------------
  # HTTP helpers (mirrors ExecutionCase route helpers for per-app WS tests)
  # ---------------------------------------------------------------------------

  defp deploy_linear_process do
    unique_version = "ws-test-#{System.unique_integer([:positive])}.0.0"
    xml = File.read!(Path.join(@fixtures_dir, "linear_start_end.bpmn"))
    unique_xml = String.replace(xml, "1.0.0", unique_version)

    case http_deploy_xml(unique_xml) do
      {201, _} -> :ok
      {status, body} -> {:error, {status, body}}
    end
  end

  defp http_deploy_xml(xml) do
    body = Jason.encode!(%{"sources" => [xml]})

    conn =
      conn(:post, "/processes", body)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer #{sign_jwt(%{"deploy_bpmn" => true})}")
      |> route()

    decode_response(conn)
  end

  defp http_start(process_model_id, body) do
    json_body = Jason.encode!(body)

    conn =
      conn(:post, "/processes/#{process_model_id}/start", json_body)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer #{sign_jwt()}")
      |> route()

    decode_response(conn)
  end

  defp route(conn) do
    Endpoint.call(conn, Endpoint.init([]))
  end

  defp decode_response(conn) do
    case conn.resp_body do
      "" -> {conn.status, nil}
      response_body -> {conn.status, Jason.decode!(response_body)}
    end
  end

  defp sign_jwt(claims \\ %{}) do
    secret = Application.get_env(:api_auth, :hs256_secret) || @test_secret
    jwk = JOSE.JWK.from_oct(secret)

    defaults = %{
      "sub" => "test-user",
      "exp" => DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_unix(),
      "iat" => DateTime.utc_now() |> DateTime.to_unix(),
      "lane:default" => true
    }

    merged = Map.merge(defaults, claims)
    {_, compact} = JOSE.JWT.sign(jwk, %{"alg" => "HS256"}, merged) |> JOSE.JWS.compact()
    compact
  end

  # ---------------------------------------------------------------------------
  # Channel / process helpers
  # ---------------------------------------------------------------------------

  defp await_process_instance_state_changed_push(timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_process_instance_state_changed_push(deadline)
  end

  defp do_await_process_instance_state_changed_push(deadline) do
    remaining_milliseconds = deadline - System.monotonic_time(:millisecond)

    if remaining_milliseconds <= 0 do
      flunk("expected ProcessInstanceStateChanged push on engine:events")
    end

    receive do
      %Phoenix.Socket.Message{
        event: "engine_event",
        payload: %{"type" => "ProcessInstanceStateChanged"} = payload
      } ->
        payload

      %Phoenix.Socket.Message{event: "engine_event", payload: _other_payload} ->
        do_await_process_instance_state_changed_push(deadline)
    after
      remaining_milliseconds ->
        flunk("expected ProcessInstanceStateChanged push on engine:events")
    end
  end

  defp wait_for_process_instance(process_instance_id, timeout \\ 2_000) do
    case EvilEngine.Execution.lookup_process_instance(process_instance_id) do
      {:ok, pid} ->
        ref = Process.monitor(pid)

        receive do
          {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
        after
          timeout ->
            Process.demonitor(ref, [:flush])
            :ok
        end

      {:error, :not_found} ->
        :ok
    end
  end

  defp terminate_all_process_instances do
    children = DynamicSupervisor.which_children(EvilEngine.Execution.Supervisor)

    Enum.each(children, fn {_, pid, _, _} ->
      DynamicSupervisor.terminate_child(EvilEngine.Execution.Supervisor, pid)
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
end

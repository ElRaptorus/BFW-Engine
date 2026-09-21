defmodule BfwEngineWeb.Http.Plugs.PayloadCapPlugTest do
  use ExUnit.Case, async: false

  import Plug.Test

  alias BfwEngineWeb.Http.Plugs.PayloadCapPlug

  @test_limit 2048

  defp call_plug(conn, opts \\ []) do
    PayloadCapPlug.call(conn, PayloadCapPlug.init(opts))
  end

  defp build_conn(body_params) when is_map(body_params) do
    %Plug.Conn{} = base = conn(:post, "/test")
    %{base | body_params: body_params}
  end

  describe "oversized payload" do
    setup do
      previous = Application.get_env(:core_execution, :token_max_bytes)
      Application.put_env(:core_execution, :token_max_bytes, @test_limit)
      on_exit(fn -> Application.put_env(:core_execution, :token_max_bytes, previous) end)
      :ok
    end

    test "returns HTTP 413 with structured error body" do
      oversized = %{"payload" => String.duplicate("x", @test_limit + 500)}
      conn = build_conn(oversized) |> call_plug()

      assert conn.status == 413
      assert conn.halted

      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "payload_too_large"
      assert body["field"] == "payload"
      assert is_integer(body["size"])
      assert body["limit"] == @test_limit
    end
  end

  describe "normal payload" do
    setup do
      previous = Application.get_env(:core_execution, :token_max_bytes)
      Application.put_env(:core_execution, :token_max_bytes, @test_limit)
      on_exit(fn -> Application.put_env(:core_execution, :token_max_bytes, previous) end)
      :ok
    end

    test "passes through without halting and leaves conn status unchanged" do
      normal = %{"payload" => %{"key" => "value"}}
      conn = build_conn(normal) |> call_plug()

      refute conn.halted
      assert is_nil(conn.status)
      assert conn.resp_body == nil
    end
  end

  describe "missing body/field" do
    test "passes through when no payload field" do
      no_payload = %{"other" => "data"}
      conn = build_conn(no_payload) |> call_plug()

      refute conn.halted
    end

    test "passes through for GET request without body" do
      conn = conn(:get, "/test") |> call_plug()

      refute conn.halted
    end
  end

  describe "non-map body_params" do
    test "passes through when body_params is not a map" do
      base = conn(:post, "/test")
      conn = %{base | body_params: nil} |> call_plug()

      refute conn.halted
    end
  end

  describe "custom field option" do
    setup do
      previous = Application.get_env(:core_execution, :token_max_bytes)
      Application.put_env(:core_execution, :token_max_bytes, @test_limit)
      on_exit(fn -> Application.put_env(:core_execution, :token_max_bytes, previous) end)
      :ok
    end

    test "checks the configured field name" do
      oversized = %{"result" => String.duplicate("x", @test_limit + 500)}
      conn = build_conn(oversized) |> call_plug(field: "result")

      assert conn.status == 413

      body = Jason.decode!(conn.resp_body)
      assert body["field"] == "result"
    end
  end
end

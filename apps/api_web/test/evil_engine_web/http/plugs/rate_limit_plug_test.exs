defmodule EvilEngineWeb.Http.Plugs.RateLimitPlugTest do
  use ExUnit.Case, async: false

  import Plug.Test

  alias EvilEngineWeb.Http.Plugs.RateLimitPlug

  setup do
    if :ets.whereis(:evil_engine_rate_limit) != :undefined do
      :ets.delete(:evil_engine_rate_limit)
    end

    original_limit = Application.get_env(:api_web, :pi_start_rate_limit)
    original_window = Application.get_env(:api_web, :pi_start_rate_window_ms)

    on_exit(fn ->
      if original_limit do
        Application.put_env(:api_web, :pi_start_rate_limit, original_limit)
      else
        Application.delete_env(:api_web, :pi_start_rate_limit)
      end

      if original_window do
        Application.put_env(:api_web, :pi_start_rate_window_ms, original_window)
      else
        Application.delete_env(:api_web, :pi_start_rate_window_ms)
      end

      if :ets.whereis(:evil_engine_rate_limit) != :undefined do
        :ets.delete(:evil_engine_rate_limit)
      end
    end)

    :ok
  end

  describe "rate_limit: 0 (disabled)" do
    test "all requests pass through" do
      Application.put_env(:api_web, :pi_start_rate_limit, 0)

      for _ <- 1..10 do
        conn = build_start_conn()
        result = RateLimitPlug.call(conn, RateLimitPlug.init([]))
        refute result.halted
      end
    end
  end

  describe "rate_limit: 3" do
    setup do
      Application.put_env(:api_web, :pi_start_rate_limit, 3)
      Application.put_env(:api_web, :pi_start_rate_window_ms, 60_000)
      :ok
    end

    test "first 3 requests pass, 4th is rejected with 429" do
      for _ <- 1..3 do
        conn = build_start_conn()
        result = RateLimitPlug.call(conn, RateLimitPlug.init([]))
        refute result.halted
      end

      conn = build_start_conn()
      result = RateLimitPlug.call(conn, RateLimitPlug.init([]))
      assert result.halted
      assert result.status == 429
      assert has_header?(result, "retry-after")
    end

    test "429 response body contains structured JSON error" do
      for _ <- 1..3 do
        conn = build_start_conn()
        RateLimitPlug.call(conn, RateLimitPlug.init([]))
      end

      conn = build_start_conn()
      result = RateLimitPlug.call(conn, RateLimitPlug.init([]))
      body = Jason.decode!(result.resp_body)

      assert body["error"] == "rate_limited"
      assert is_binary(body["message"])
      assert is_integer(body["retryAfterSeconds"])
      assert body["retryAfterSeconds"] >= 1
    end

    test "retry-after header matches body retry_after_seconds" do
      for _ <- 1..3 do
        conn = build_start_conn()
        RateLimitPlug.call(conn, RateLimitPlug.init([]))
      end

      conn = build_start_conn()
      result = RateLimitPlug.call(conn, RateLimitPlug.init([]))
      body = Jason.decode!(result.resp_body)

      header_value = get_header(result, "retry-after")
      assert header_value == Integer.to_string(body["retryAfterSeconds"])
    end

    test "non-start requests bypass rate limiting" do
      conn = conn(:get, "/processes")

      for _ <- 1..10 do
        result = RateLimitPlug.call(conn, RateLimitPlug.init([]))
        refute result.halted
      end
    end
  end

  describe "window reset" do
    test "bucket refills after window elapses" do
      Application.put_env(:api_web, :pi_start_rate_limit, 1)
      Application.put_env(:api_web, :pi_start_rate_window_ms, 50)

      conn = build_start_conn()
      result = RateLimitPlug.call(conn, RateLimitPlug.init([]))
      refute result.halted

      conn = build_start_conn()
      result = RateLimitPlug.call(conn, RateLimitPlug.init([]))
      assert result.halted

      Process.sleep(60)

      conn = build_start_conn()
      result = RateLimitPlug.call(conn, RateLimitPlug.init([]))
      refute result.halted
    end
  end

  defp build_start_conn do
    conn(:post, "/processes/my-process/start")
  end

  defp has_header?(conn, key) do
    Enum.any?(conn.resp_headers, fn {header_key, _value} -> header_key == key end)
  end

  defp get_header(conn, key) do
    case List.keyfind(conn.resp_headers, key, 0) do
      {_key, value} -> value
      nil -> nil
    end
  end
end

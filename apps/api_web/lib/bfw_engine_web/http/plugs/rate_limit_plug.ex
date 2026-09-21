defmodule BfwEngineWeb.Http.Plugs.RateLimitPlug do
  @moduledoc """
  ETS-based fixed-window rate limiter for `POST /processes/:model_id/start`.

  Applies a global (not per-client) rate limit on process instance start
  requests. The algorithm tracks request count within a sliding window
  that resets after `BFE_PI_START_RATE_WINDOW_MS` milliseconds from the
  first request in that window. When the count reaches the limit, returns
  429 with a `Retry-After` header.

  Disabled by default (`BFE_PI_START_RATE_LIMIT=0`). The plug self-filters:
  only `POST` requests matching `["processes", _model_id, "start"]` are subject
  to rate limiting; all other requests pass through unchanged.
  """

  @behaviour Plug

  require Logger

  import BfwEngineWeb.Http.ErrorResponse

  @ets_table :bfw_engine_rate_limit

  @impl true
  @doc """
  Plug init callback; passes `opts` through unchanged.
  """
  @spec init(Plug.opts()) :: Plug.opts()
  def init(opts), do: opts

  @impl true
  @doc """
  Runs the rate limit check for start requests when enabled in application env.
  """
  @spec call(Plug.Conn.t(), Plug.opts()) :: Plug.Conn.t()
  def call(conn, _opts) do
    if start_request?(conn) do
      maybe_rate_limit(conn)
    else
      conn
    end
  end

  defp maybe_rate_limit(conn) do
    rate_limit = Application.get_env(:api_web, :pi_start_rate_limit, 0)

    if rate_limit > 0 do
      window_ms = Application.get_env(:api_web, :pi_start_rate_window_ms, 1000)
      check_rate(conn, rate_limit, window_ms)
    else
      conn
    end
  end

  defp start_request?(%{method: "POST", path_info: ["processes", _model_id, "start"]}), do: true
  defp start_request?(_conn), do: false

  defp check_rate(conn, rate_limit, window_ms) do
    :ok = ensure_table()
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@ets_table, :global) do
      [{:global, count, window_start}] when now - window_start < window_ms ->
        allow_or_reject_in_window(conn, count, rate_limit, window_start, window_ms, now)

      _ ->
        :ets.insert(@ets_table, {:global, 1, now})
        conn
    end
  end

  defp allow_or_reject_in_window(conn, count, rate_limit, window_start, window_ms, now) do
    if count < rate_limit do
      _ = :ets.update_counter(@ets_table, :global, {2, 1})
      conn
    else
      reject(conn, window_start, window_ms, now)
    end
  end

  defp reject(conn, window_start, window_ms, now) do
    remaining_ms = window_start + window_ms - now
    retry_after_seconds = max(div(remaining_ms, 1000), 1)

    Logger.warning(
      "Rate limit exceeded: #{conn.method} #{conn.request_path} — retry after #{retry_after_seconds}s"
    )

    conn
    |> Plug.Conn.put_resp_header("retry-after", Integer.to_string(retry_after_seconds))
    |> render_error_halt(429, "rate_limited", "Start rate limit exceeded",
      retry_after_seconds: retry_after_seconds
    )
  end

  defp ensure_table do
    case :ets.whereis(@ets_table) do
      :undefined ->
        _table = :ets.new(@ets_table, [:named_table, :public, :set])
        :ok

      _reference ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  end
end

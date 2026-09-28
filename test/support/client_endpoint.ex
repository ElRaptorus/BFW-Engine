defmodule BfwEngine.Test.ClientEndpoint do
  @moduledoc """
  Starts a real, loopback Bandit listener fronting the production
  `BfwEngineWeb.Http.Endpoint` for `BfwEngine.Client` integration tests.

  `config/test.exs` sets `server: false` on the Endpoint config, so Phoenix
  never opens its own listener during `mix test` — but the Endpoint process
  itself remains supervised (`BfwEngineWeb.Application` starts it
  unconditionally). This module starts a second, throwaway Bandit process
  with `plug: BfwEngineWeb.Http.Endpoint`, `ip: :loopback`, `port: 0` under
  `ExUnit.Callbacks.start_supervised!/1` and resolves the OS-assigned port
  via `ThousandIsland.listener_info/1`, so the client makes real TCP
  requests (HTTP and WebSocket-upgrade) against the actual engine.
  """

  @doc """
  Start a loopback Bandit listener fronting the real Endpoint.

  Returns `{http_base_url, websocket_url}`. Must be called from within a
  test process (uses `ExUnit.Callbacks.start_supervised!/1`, so the
  listener is torn down automatically at the end of the test).
  """
  def start! do
    {:ok, _apps} = Application.ensure_all_started(:slipstream)

    pid =
      ExUnit.Callbacks.start_supervised!(
        {Bandit, plug: BfwEngineWeb.Http.Endpoint, ip: :loopback, port: 0, startup_log: false}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(pid)

    {"http://127.0.0.1:#{port}", "ws://127.0.0.1:#{port}/socket/websocket"}
  end
end

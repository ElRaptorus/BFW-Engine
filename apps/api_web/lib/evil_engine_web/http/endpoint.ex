defmodule EvilEngineWeb.Http.Endpoint do
  @moduledoc """
  Unified Phoenix endpoint for REST, GraphQL, and WebSocket surfaces.

  Mounts `UserSocket` at `/socket` for Phoenix Channels (engine event
  subscriptions) alongside the HTTP router. Having a single endpoint
  means clients only need one base URL — the WebSocket transport is
  auto-discovered at `ws://<host>:<port>/socket/websocket`.
  """

  use Phoenix.Endpoint, otp_app: :api_web

  socket "/socket", EvilEngineWeb.Ws.UserSocket,
    websocket: true,
    longpoll: false

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:evil_engine, :http]
  plug Plug.Logger, log: :info

  @body_size_limit Application.compile_env(:core_execution, :token_max_bytes, 65_536) * 4

  plug Plug.Parsers,
    parsers: [:urlencoded, {:json, length: @body_size_limit}],
    json_decoder: Jason

  plug Plug.MethodOverride
  plug Plug.Head
  plug EvilEngineWeb.Http.Router
end

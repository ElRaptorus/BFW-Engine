defmodule EvilEngineWeb.Http.InfoController do
  @moduledoc "GET /info -- engine identity and configuration summary."

  use Phoenix.Controller, formats: [:json]

  alias EvilEngine.Telemetry.StatsCollector
  alias EvilEngine.Types.Wire

  def index(conn, _params) do
    json(conn, Wire.camelize_keys(StatsCollector.info()))
  end
end

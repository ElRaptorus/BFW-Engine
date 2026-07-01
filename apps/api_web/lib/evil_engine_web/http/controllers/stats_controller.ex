defmodule EvilEngineWeb.Http.StatsController do
  @moduledoc "GET /stats -- runtime telemetry snapshot."

  use Phoenix.Controller, formats: [:json]

  alias EvilEngine.Telemetry.StatsCollector
  alias EvilEngine.Types.Wire

  def index(conn, _params) do
    json(conn, Wire.camelize_keys(StatsCollector.snapshot()))
  end
end

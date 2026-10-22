defmodule BfwEngineWeb.Http.InfoController do
  @moduledoc "GET /info -- engine identity and configuration summary."

  use Phoenix.Controller, formats: [:json]

  alias BfwEngine.Telemetry.StatsCollector
  alias BfwEngine.Types.Wire

  def index(conn, _params) do
    json(conn, Wire.camelize_keys(StatsCollector.info()))
  end
end

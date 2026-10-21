defmodule BfwEngineWeb.Http.StatsController do
  @moduledoc "GET /stats -- runtime telemetry snapshot."

  use Phoenix.Controller, formats: [:json]

  import BfwEngineWeb.Http.ErrorResponse

  alias BfwEngine.Telemetry.StatsCollector
  alias BfwEngine.Types.Wire

  def index(conn, _params) do
    case StatsCollector.snapshot() do
      {:ok, snapshot} ->
        json(conn, Wire.camelize_keys(snapshot))

      {:error, :database_unavailable} ->
        conn
        |> put_resp_header("retry-after", "5")
        |> render_error(
          503,
          "service_unavailable",
          "Statistics are unavailable because a database query failed."
        )
    end
  end
end

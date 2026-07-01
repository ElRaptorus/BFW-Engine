defmodule EvilEngineWeb.Http.MetricsController do
  @moduledoc "GET /metrics -- Prometheus exposition format."

  use Phoenix.Controller, formats: [:json]

  import EvilEngineWeb.Http.ErrorResponse

  alias TelemetryMetricsPrometheus.Core, as: PrometheusCore

  @doc "Serves Prometheus exposition format when metrics are enabled, 404 otherwise."
  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params) do
    if Application.get_env(:peripheral_telemetry, :metrics_enabled, true) do
      metrics = PrometheusCore.scrape()

      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(200, metrics)
    else
      render_error(conn, 404, "metrics_disabled", "Metrics endpoint is not enabled")
    end
  end
end

defmodule BfwEngineWeb.Http.Plugs.MetricsGatePlug do
  @moduledoc """
  Gates the Prometheus scrape route behind `:peripheral_telemetry, :metrics_enabled`
  (`BFE_METRICS_ENABLED`).

  When metrics are disabled the request is answered with the same plain
  `404 Not Found` as the devtools gate, before the controller runs, so a disabled
  endpoint is indistinguishable from a route that does not exist.
  """

  @behaviour Plug

  alias BfwEngineWeb.Http.Plugs.DevtoolsGatePlug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    if Application.get_env(:peripheral_telemetry, :metrics_enabled, true) do
      conn
    else
      DevtoolsGatePlug.reject(conn)
    end
  end
end

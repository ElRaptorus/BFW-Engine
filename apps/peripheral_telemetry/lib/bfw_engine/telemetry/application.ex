defmodule BfwEngine.Telemetry.Application do
  @moduledoc false

  use Application

  alias BfwEngine.Telemetry.DbQueryHandler
  alias BfwEngine.Telemetry.Measurements
  alias BfwEngine.Telemetry.Metrics
  alias TelemetryMetricsPrometheus.Core, as: PrometheusCore

  @impl true
  def start(_type, _args) do
    DbQueryHandler.attach()

    children =
      if Application.get_env(:peripheral_telemetry, :metrics_enabled, true) do
        [
          {PrometheusCore, metrics: Metrics.metrics()},
          {:telemetry_poller,
           measurements: [
             {Measurements, :active_process_instances, []},
             {Measurements, :db_pool_stats, []}
           ],
           period: 10_000}
        ]
      else
        []
      end

    opts = [strategy: :one_for_one, name: BfwEngine.Telemetry.Supervisor]
    Supervisor.start_link(children, opts)
  end
end

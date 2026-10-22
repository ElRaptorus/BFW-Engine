defmodule BfwEngine.Telemetry.Supervisor do
  @moduledoc false

  use Supervisor

  alias BfwEngine.Telemetry.DbQueryHandler
  alias BfwEngine.Telemetry.Measurements
  alias BfwEngine.Telemetry.Metrics
  alias TelemetryMetricsPrometheus.Core, as: PrometheusCore

  @spec start_link(term()) :: Supervisor.on_start()
  def start_link(_options) do
    DbQueryHandler.attach()
    Supervisor.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    children =
      if Application.get_env(:bfw_engine, :metrics_enabled, true) do
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

    Supervisor.init(children, strategy: :one_for_one)
  end
end

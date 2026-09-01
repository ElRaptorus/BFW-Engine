defmodule Examples.BusinessRules.DecisionAnalytics.ReportScheduler do
  @moduledoc """
  Periodically formats collector stats as JSON and logs them for operators.

  Default interval is 60_000 ms (`REPORT_INTERVAL_MS`). Tests pass
  `:interval_ms` and `:collector_name`.
  """

  use GenServer

  require Logger

  alias Examples.BusinessRules.DecisionAnalytics.AnalyticsCollector
  alias Examples.BusinessRules.DecisionAnalytics.ReportFormatter

  @default_interval_ms 60_000

  @doc "Starts the report scheduler. Options: `:interval_ms`, `:collector_name`, `:name`."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []) do
    GenServer.start_link(__MODULE__, options, Keyword.take(options, [:name]))
  end

  @doc "Builds the current report immediately without waiting for the next tick."
  @spec emit_report(GenServer.server()) :: map()
  def emit_report(server) do
    GenServer.call(server, :emit_report)
  end

  @impl true
  def init(options) do
    interval_ms = Keyword.get(options, :interval_ms, @default_interval_ms)
    collector_name = Keyword.get(options, :collector_name, AnalyticsCollector)

    state = %{interval_ms: interval_ms, collector_name: collector_name}

    if interval_ms > 0 do
      Process.send_after(self(), :tick, interval_ms)
    end

    {:ok, state}
  end

  @impl true
  def handle_call(:emit_report, _from, state) do
    report = log_report(state)
    {:reply, report, state}
  end

  @impl true
  def handle_info(:tick, state) do
    _report = log_report(state)
    Process.send_after(self(), :tick, state.interval_ms)
    {:noreply, state}
  end

  def handle_info(_unknown_message, state), do: {:noreply, state}

  defp log_report(state) do
    report = ReportFormatter.format(AnalyticsCollector.get_stats(name: state.collector_name))

    Logger.info("decision_analytics: #{Jason.encode!(report)}")
    report
  end
end

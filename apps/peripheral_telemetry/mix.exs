defmodule PeripheralTelemetry.MixProject do
  @moduledoc """
  In-process `:telemetry` counters (§11). Backs `/stats` and the Prometheus
  exposition endpoint (`GET /metrics`).
  """

  use Mix.Project

  def project do
    [
      app: :peripheral_telemetry,
      version: "0.0.1",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      test_coverage: [tool: ExCoveralls, threshold: 75],
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env())
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {EvilEngine.Telemetry.Application, []}
    ]
  end

  defp deps do
    [
      {:core_types, in_umbrella: true},
      {:core_events, in_umbrella: true},
      {:core_timers, in_umbrella: true},
      {:peripheral_persistence, in_umbrella: true},
      {:peripheral_plugins, in_umbrella: true},
      {:engine_sdk, in_umbrella: true},
      {:telemetry, "~> 1.4"},
      {:telemetry_metrics, "~> 1.1"},
      {:telemetry_metrics_prometheus_core, "~> 1.1"},
      {:telemetry_poller, "~> 1.1"}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
end

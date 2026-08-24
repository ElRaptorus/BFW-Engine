defmodule CoreTimers.MixProject do
  @moduledoc """
  Single-node ISO-8601 timer scheduler.

  Phase 0 only scaffolds the app and its supervision tree. Phase 3
  step 3 hardens it with ETS + persistence + crash-safe recovery.
  """

  use Mix.Project

  def project do
    [
      app: :core_timers,
      version: "0.0.1",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      test_coverage: [tool: ExCoveralls, threshold: 80],
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env())
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {EvilEngine.Timers.Application, []}
    ]
  end

  defp deps do
    [
      {:core_types, in_umbrella: true},
      {:telemetry, "~> 1.4"}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
end

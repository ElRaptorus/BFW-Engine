defmodule CoreExecution.MixProject do
  @moduledoc """
  The BPMN runtime — Process-Instance and Flow-Node-Instance state
  machines, the PI Facade, Resume, Payload Cap, and the
  handler dispatcher.

  Phase 0 scaffolds the app and a top-level supervisor only. Actual
  runtime semantics start landing in Phase 1.
  """

  use Mix.Project

  def project do
    [
      app: :core_execution,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      test_coverage: [tool: ExCoveralls, threshold: 81],
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env())
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {BfwEngine.Execution.Application, []}
    ]
  end

  defp deps do
    [
      {:core_types, in_umbrella: true},
      {:core_expressions, in_umbrella: true},
      {:core_timers, in_umbrella: true},
      {:core_events, in_umbrella: true},
      {:core_bpmn, in_umbrella: true},
      {:core_dmn, in_umbrella: true},
      {:ex_json_schema, "~> 0.11"},
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.4"}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
end

defmodule ApiFacade.MixProject do
  @moduledoc """
  The `BfwEngine.Api` service layer — a single entry-point module that
  all wire adapters (REST, GraphQL, WebSocket) and plugins
  converge on.

  Pure functions, no Phoenix dependency.
  """

  use Mix.Project

  def project do
    [
      app: :api_facade,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      test_coverage: [tool: ExCoveralls, threshold: 76],
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env())
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:core_events, in_umbrella: true},
      {:core_execution, in_umbrella: true},
      {:core_bpmn, in_umbrella: true},
      {:peripheral_persistence, in_umbrella: true}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
end

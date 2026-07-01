defmodule CoreDmn.MixProject do
  @moduledoc """
  DMN 1.5 parser + validator + evaluator + in-memory
  `EvilEngine.DMN.ModelCache` GenServer.

  Owns the parsed DMN Model AST under `EvilEngine.DMN.Model.*`.
  Authoritative persistent form is `decision_versions.dmn_xml`;
  the AST is only ever in memory.
  """

  use Mix.Project

  def project do
    [
      app: :core_dmn,
      version: "0.0.1",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      test_coverage: [tool: ExCoveralls, threshold: 80],
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env())
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {EvilEngine.DMN.Application, []}
    ]
  end

  defp deps do
    [
      {:core_types, in_umbrella: true},
      {:core_expressions, in_umbrella: true},
      {:telemetry, "~> 1.2"},
      {:saxy, "~> 1.6"},
      {:jason, "~> 1.4"}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
end

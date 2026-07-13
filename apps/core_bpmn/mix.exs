defmodule CoreBpmn.MixProject do
  @moduledoc """
  BPMN XML parser + validator + data-contract compiler + in-memory
  `EvilEngine.BPMN.ModelCache` GenServer.

  Owns the parsed Process Model AST under `EvilEngine.BPMN.Model.*`. Authoritative persistent form is `process_versions.bpmn_xml`
  (§4.1); the AST is only ever in memory.
  """

  use Mix.Project

  def project do
    [
      app: :core_bpmn,
      version: "0.0.1",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      test_coverage: [tool: ExCoveralls, threshold: 55],
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env())
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {EvilEngine.BPMN.Application, []}
    ]
  end

  defp deps do
    [
      {:core_types, in_umbrella: true},
      {:core_expressions, in_umbrella: true},
      {:saxy, "~> 1.6"},
      {:ex_json_schema, "~> 0.11"},
      {:jason, "~> 1.4"}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
end

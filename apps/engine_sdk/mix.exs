defmodule EngineSdk.MixProject do
  @moduledoc """
  Public SDK for Elixir plugin authors (§9.3).

  Contains:

    * `@behaviour` modules for every plugin-facing callback
      (`FlowNodeHandler`, `EventSink`, `IdentityVerifier`, …).
    * Re-exports `EvilEngine.BPMN.{Model.*, ModelCache, Parser}` so
      in-engine and out-of-tree Elixir tooling parses BPMN XML with
      the same semantics the engine uses.
    * A curated subset of `core_types`.
    * Mox fixtures + test helpers.

  Re-exports only — never re-defines.
  """

  use Mix.Project

  def project do
    [
      app: :engine_sdk,
      version: "0.0.1",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      test_coverage: [tool: ExCoveralls, threshold: 0],
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env())
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:core_types, in_umbrella: true},
      {:core_bpmn, in_umbrella: true}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
end

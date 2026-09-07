defmodule CoreExpressions.MixProject do
  @moduledoc """
  FEEL evaluator and Identity-claim resolver.

  Per `docs/architecture/expressions.md`: the engine uses a Friendly Enough
  Expression Language (FEEL) for

    * `<bpmn:conditionExpression>` on sequence flows,
    * `<evil:correlationKey>` / `<evil:correlationRetrievalExpression>`
      on message events,
    * Multi-Instance cardinality / collection / completion expressions,
    * Identity-claim resolution inside User Lanes.

  FEEL evaluation is backed by a Rust NIF wrapping the dsntk crates
  (dsntk-feel-parser, dsntk-feel-evaluator) via Rustler. Expressions
  are precompiled at deploy time; evaluation on the runtime hot path
  is native-speed with no parsing overhead.
  """

  use Mix.Project

  def project do
    [
      app: :core_expressions,
      version: "0.0.1",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      test_coverage: [tool: ExCoveralls, threshold: 85],
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
      {:rustler, "~> 0.37.3", runtime: false}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
end

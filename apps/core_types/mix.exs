defmodule CoreTypes.MixProject do
  @moduledoc """
  Shared, behaviour-free structs used across every other app.

  Per `ImplementationPlan.md` §2 / * No logic, no side effects.
    * Every other app may depend on it.
    * This app itself depends on nothing beyond the Elixir stdlib — not
      even `ash`, `ecto`, or `phoenix`. Keeps it usable from plugins,
      tests, and Mix tasks with zero boot cost.
  """

  use Mix.Project

  def project do
    [
      app: :core_types,
      version: "0.0.1",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      test_coverage: [tool: ExCoveralls, threshold: 0],
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env())
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps, do: []

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
end

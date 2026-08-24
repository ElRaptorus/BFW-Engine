defmodule PeripheralPersistence.MixProject do
  @moduledoc """
  Owns all persistent state: Ash resources, `AshPostgres.Repo`,
  dual-pool routing, and the `mix evil.partitions.ensure` boot hook.

  The built-in `database` EventSink was removed. `RetentionRunner`
  is Phase 7 work and does **not** ship today.
  """

  use Mix.Project

  def project do
    [
      app: :peripheral_persistence,
      version: "0.0.1",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      test_coverage: [tool: ExCoveralls, threshold: 74],
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env()),
      aliases: aliases()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :runtime_tools],
      mod: {EvilEngine.Persistence.Application, []}
    ]
  end

  defp deps do
    [
      {:core_execution, in_umbrella: true},
      {:core_types, in_umbrella: true},
      {:engine_sdk, in_umbrella: true},
      {:ash, "~> 3.24"},
      {:picosat_elixir, "~> 0.2"},
      {:ash_graphql, "~> 1.9"},
      {:ash_postgres, "~> 2.9"},
      {:igniter, "~> 0.6"},
      {:ecto_sql, "~> 3.12"},
      {:postgrex, "~> 0.19"},
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.4"}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp aliases do
    [
      setup: ["deps.get"],
      "ecto.setup": ["ash.setup"],
      "ecto.reset": ["ash.reset", "ash.setup"]
    ]
  end
end

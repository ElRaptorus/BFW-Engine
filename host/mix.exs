defmodule BfwEngine.Host.MixProject do
  @moduledoc """
  Release host for the Bifrost Forge World Engine.

  The only Mix project that defines `releases/0`. It depends on the Engine
  (`:bfw_engine`, the repository root). Generated in-BEAM plugins are path
  dependencies of this project, so `mix release` can include them without
  listing them on the Engine itself.

  Run `mix release` from the repository root. The root alias builds this
  project. Overlays stay in `../rel` (`rel_templates_path`).
  """

  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :bfw_engine_host,
      version: @version,
      elixir: "~> 1.20",
      build_path: "../_build",
      config_path: "../config/config.exs",
      deps_path: "../deps",
      lockfile: "../mix.lock",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: releases()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:logger_json, "~> 7.0", only: :prod},
      {:bfw_engine, path: ".."}
    ]
  end

  defp releases do
    [
      bfw_engine: [
        version: @version,
        applications: [
          logger_json: :permanent,
          bfw_engine: :permanent
        ],
        include_executables_for: [:unix],
        rel_templates_path: "../rel",
        steps: [:assemble, :tar]
      ]
    ]
  end
end

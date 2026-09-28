defmodule BfwEngine.Host.MixProject do
  @moduledoc """
  Release host for the Bifrost Forge World Engine.

  This project is not an umbrella. It depends on the umbrella apps and is
  the only Mix project that defines `releases/0`. Generated in-BEAM plugins
  are path dependencies of this project, so `mix release` can include them
  without listing them on the umbrella root.

  Run `mix release` from the repository root. The root alias builds this
  project. Overlays stay in `../rel` (`rel_templates_path`).
  """

  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :bfw_engine,
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
      {:core_types, path: "../apps/core_types"},
      {:core_expressions, path: "../apps/core_expressions"},
      {:core_timers, path: "../apps/core_timers"},
      {:core_events, path: "../apps/core_events"},
      {:core_bpmn, path: "../apps/core_bpmn"},
      {:core_dmn, path: "../apps/core_dmn"},
      {:core_execution, path: "../apps/core_execution"},
      {:peripheral_persistence, path: "../apps/peripheral_persistence"},
      {:peripheral_telemetry, path: "../apps/peripheral_telemetry"},
      {:peripheral_plugins, path: "../apps/peripheral_plugins"},
      {:engine_sdk, path: "../apps/engine_sdk"},
      {:api_auth, path: "../apps/api_auth"},
      {:api_facade, path: "../apps/api_facade"},
      {:api_web, path: "../apps/api_web"}
    ]
  end

  defp releases do
    [
      bfw_engine: [
        version: @version,
        applications: [
          logger_json: :permanent,
          core_types: :permanent,
          core_expressions: :permanent,
          core_timers: :permanent,
          core_events: :permanent,
          core_bpmn: :permanent,
          core_dmn: :permanent,
          core_execution: :permanent,
          peripheral_persistence: :permanent,
          peripheral_telemetry: :permanent,
          peripheral_plugins: :permanent,
          engine_sdk: :permanent,
          api_auth: :permanent,
          api_facade: :permanent,
          api_web: :permanent
        ],
        include_executables_for: [:unix],
        rel_templates_path: "../rel",
        steps: [:assemble, :tar]
      ]
    ]
  end
end

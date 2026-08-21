defmodule ApiWeb.MixProject do
  @moduledoc """
  Unified API surface: REST controllers, GraphQL (AshGraphql + Absinthe),
  Phoenix Channels (WebSocket event push), and admin endpoints.

  Consolidates the former api_http, api_graphql, api_websocket, and
  api_admin apps.
  """

  use Mix.Project

  def project do
    [
      app: :api_web,
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
    [
      extra_applications: [:logger, :runtime_tools],
      mod: {EvilEngineWeb.Application, []}
    ]
  end

  defp deps do
    [
      {:core_types, in_umbrella: true},
      {:core_bpmn, in_umbrella: true},
      {:core_events, in_umbrella: true},
      {:core_execution, in_umbrella: true},
      {:peripheral_persistence, in_umbrella: true},
      {:peripheral_telemetry, in_umbrella: true},
      {:engine_sdk, in_umbrella: true},
      {:api_auth, in_umbrella: true},
      {:api_facade, in_umbrella: true},
      {:phoenix, "~> 1.8"},
      {:bandit, "~> 1.10"},
      {:phoenix_html, "~> 4.3"},
      {:phoenix_pubsub, "~> 2.2"},
      {:open_api_spex, "~> 3.21"},
      {:yaml_elixir, "~> 2.11"},
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.4"},
      {:ash, "~> 3.24"},
      {:ash_graphql, "~> 1.9"},
      {:absinthe, "~> 1.7"},
      {:absinthe_plug, "~> 1.5"},
      {:absinthe_phoenix, "~> 2.0"},
      {:dataloader, "~> 2.0"}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
end

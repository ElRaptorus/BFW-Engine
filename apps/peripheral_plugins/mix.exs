defmodule PeripheralPlugins.MixProject do
  @moduledoc """
  Plugin registry + gRPC sidecar bridge + conflict detector (§9).
  Plugins always live under this app or as external sidecars — never
  inside Core.
  """

  use Mix.Project

  def project do
    [
      app: :peripheral_plugins,
      version: "0.0.1",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      test_coverage: [tool: ExCoveralls, threshold: 90],
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env())
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {EvilEngine.Plugins.Application, []}
    ]
  end

  defp deps do
    [
      {:core_types, in_umbrella: true},
      {:core_events, in_umbrella: true},
      {:core_execution, in_umbrella: true},
      {:core_expressions, in_umbrella: true},
      {:engine_sdk, in_umbrella: true},
      {:api_facade, in_umbrella: true},
      {:req, "~> 0.5"}
      # gRPC deps (:grpc, :grpcbox, …) land in Phase 2+ with the real
      # sidecar bridge.
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
end

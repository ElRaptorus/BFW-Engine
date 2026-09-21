defmodule ApiAuth.MixProject do
  @moduledoc """
  Built-in JWT validator — HS256 + RS256/ES256 + JWKS.
  Pluggable via `@behaviour BfwEngine.Plugin.AuthProvider`.
  """

  use Mix.Project

  def project do
    [
      app: :api_auth,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      test_coverage: [tool: ExCoveralls, threshold: 56],
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env())
    ]
  end

  def application do
    [
      extra_applications: [:logger, :public_key],
      mod: {BfwEngine.Auth.Application, []}
    ]
  end

  defp deps do
    [
      {:core_types, in_umbrella: true},
      {:engine_sdk, in_umbrella: true},
      {:jose, "~> 1.11"},
      {:jason, "~> 1.4"},
      {:plug, "~> 1.16"}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
end

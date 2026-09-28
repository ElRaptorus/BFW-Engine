# The umbrella loads this file with Code.compile_file/1 because it is a path
# dependency, which defines the module in memory. The editor compiles the same
# file again for diagnostics. Restored immediately so other redefinitions still warn.
previous_ignore_module_conflict = Code.get_compiler_option(:ignore_module_conflict)
Code.put_compiler_option(:ignore_module_conflict, true)

try do
  defmodule BfwEngineClient.MixProject do
    @moduledoc """
    Standalone Elixir client for the Bifrost Forge World Engine.

    Wraps the Engine's REST, GraphQL, and WebSocket surfaces (`BfwEngine.Client`
    and friends) for host applications that embed the Engine as an external
    service. Not part of the Engine umbrella — this is an independently
    buildable Hex-style package consumed via a path or Git dependency.
    """

    use Mix.Project

    @version "0.1.0"

    def project do
      [
        app: :bfw_engine_client,
        version: @version,
        elixir: "~> 1.20",
        start_permanent: Mix.env() == :prod,
        deps: deps(),
        aliases: aliases(),
        description:
          "Elixir client for the Bifrost Forge World Engine REST, GraphQL, and WebSocket APIs.",
        source_url: "https://github.com/ElRaptorus/BFW-Engine",
        package: [
          licenses: ["MIT"],
          links: %{"GitHub" => "https://github.com/ElRaptorus/BFW-Engine"},
          files: ["lib", "mix.exs", "README.md"]
        ],
        test_coverage: [summary: [threshold: 90]],
        dialyzer: [
          plt_local_path: "priv/plts",
          plt_core_path: "priv/plts",
          plt_add_apps: [:mix]
        ],
        docs: [
          main: "readme",
          extras: ["README.md"]
        ]
      ]
    end

    def application do
      [
        extra_applications: [:logger]
      ]
    end

    def cli do
      [preferred_envs: [quality: :test]]
    end

    defp deps do
      [
        {:req, "~> 0.7"},
        {:jason, "~> 1.4"},
        {:slipstream, "~> 1.2"},
        {:igniter, "~> 0.8", optional: true},
        {:plug, "~> 1.16", only: :test},
        {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
        {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
        {:ex_doc, "~> 0.40", only: [:dev, :test], runtime: false},
        {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false}
      ]
    end

    defp aliases do
      [
        quality: [
          "compile --warnings-as-errors",
          "format --check-formatted",
          "credo --strict",
          "dialyzer",
          "docs --warnings-as-errors",
          "test --cover"
        ]
      ]
    end
  end
after
  Code.put_compiler_option(:ignore_module_conflict, previous_ignore_module_conflict)
end
